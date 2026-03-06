defmodule ShimmiePhoenix.Site.Approval do
  @moduledoc """
  Legacy-compatible approval helpers for moderating image visibility.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  require Logger

  @sqlite_separator <<31>>
  def can_approve?(%{id: id, class: class}) when is_integer(id) and id > 0 do
    approval_enabled?() and Permissions.allowed?(:approve, class)
  end

  def can_approve?(_), do: false

  def approval_supported? do
    approval_enabled?() and approved_column?()
  end

  def image_approved?(image_id) when is_integer(image_id) and image_id > 0 do
    if approved_column?() do
      case sqlite_db_path() do
        nil -> repo_image_approved(image_id)
        path -> sqlite_image_approved(path, image_id)
      end
    else
      true
    end
  end

  def image_approved?(_), do: true

  def can_view_image?(image_id, actor) when is_integer(image_id) and image_id > 0 do
    cond do
      not image_exists?(image_id) ->
        false

      not approval_supported?() ->
        true

      can_approve?(actor) ->
        true

      image_approved?(image_id) ->
        true

      true ->
        actor_id(actor) > 0 and actor_id(actor) == image_owner_id(image_id)
    end
  end

  def can_view_image?(_, _), do: false

  def approve(image_id, actor), do: set_approval(image_id, actor, true)
  def disapprove(image_id, actor), do: set_approval(image_id, actor, false)

  def set_approval(image_id, actor, approved?) when is_boolean(approved?) do
    cond do
      not (is_integer(image_id) and image_id > 0) ->
        {:error, :invalid_image_id}

      not can_approve?(actor) ->
        {:error, :permission_denied}

      not approved_column?() ->
        {:error, :approval_not_supported}

      not image_exists?(image_id) ->
        {:error, :post_not_found}

      true ->
        run_update(image_id, actor.id, approved?)
    end
  end

  defp run_update(image_id, actor_id, approved?) do
    case sqlite_db_path() do
      nil -> repo_update(image_id, actor_id, approved?)
      path -> sqlite_update(path, image_id, actor_id, approved?)
    end
  end

  defp repo_update(image_id, actor_id, approved?) do
    with {sql, params} <- repo_update_sql(image_id, actor_id, approved?),
         {:ok, _} <- Repo.query(sql, params) do
      :ok
    else
      _ -> {:error, :update_failed}
    end
  end

  defp repo_update_sql(image_id, actor_id, true) do
    if approved_by_column?() do
      {
        "UPDATE images SET approved = $1, approved_by_id = $2 WHERE id = $3 AND COALESCE(approved, FALSE) != TRUE",
        [true, actor_id, image_id]
      }
    else
      {
        "UPDATE images SET approved = $1 WHERE id = $2 AND COALESCE(approved, FALSE) != TRUE",
        [true, image_id]
      }
    end
  end

  defp repo_update_sql(image_id, _actor_id, false) do
    if approved_by_column?() do
      {
        "UPDATE images SET approved = $1, approved_by_id = NULL WHERE id = $2 AND COALESCE(approved, TRUE) = TRUE",
        [false, image_id]
      }
    else
      {
        "UPDATE images SET approved = $1 WHERE id = $2 AND COALESCE(approved, TRUE) = TRUE",
        [false, image_id]
      }
    end
  end

  defp sqlite_update(path, image_id, actor_id, approved?) do
    state_guard =
      if approved?,
        do: "COALESCE(approved, 0) != 1",
        else: "COALESCE(approved, 1) = 1"

    approved_value = if approved?, do: "1", else: "0"

    approved_by_clause =
      if approved_by_column?() do
        if approved? do
          ", approved_by_id = #{actor_id}"
        else
          ", approved_by_id = NULL"
        end
      else
        ""
      end

    sql =
      "UPDATE images SET approved = #{approved_value}#{approved_by_clause} " <>
        "WHERE id = #{image_id} AND #{state_guard}"

    case sqlite_exec(path, sql) do
      :ok -> :ok
      {:error, _} -> {:error, :update_failed}
    end
  end

  defp repo_image_approved(image_id) do
    case Repo.query("SELECT COALESCE(approved, TRUE) FROM images WHERE id = $1 LIMIT 1", [
           image_id
         ]) do
      {:ok, %{rows: [[value]]}} -> truthy?(value)
      _ -> true
    end
  end

  defp sqlite_image_approved(path, image_id) do
    query = "SELECT COALESCE(approved, 1) FROM images WHERE id = #{image_id} LIMIT 1"

    case sqlite_rows(path, query) do
      {:ok, [line | _]} ->
        [value | _] = String.split(line, @sqlite_separator, parts: 2)
        truthy?(value)

      _ ->
        true
    end
  end

  defp image_exists?(image_id) do
    case sqlite_db_path() do
      nil ->
        case Repo.query("SELECT 1 FROM images WHERE id = $1 LIMIT 1", [image_id]) do
          {:ok, %{rows: [[1]]}} -> true
          {:ok, %{rows: rows}} -> rows != []
          _ -> false
        end

      path ->
        case sqlite_rows(path, "SELECT 1 FROM images WHERE id = #{image_id} LIMIT 1") do
          {:ok, [_ | _]} -> true
          _ -> false
        end
    end
  end

  defp image_owner_id(image_id) do
    case sqlite_db_path() do
      nil ->
        case Repo.query("SELECT COALESCE(owner_id, 0) FROM images WHERE id = $1 LIMIT 1", [
               image_id
             ]) do
          {:ok, %{rows: [[owner_id]]}} -> parse_int(owner_id)
          _ -> 0
        end

      path ->
        case sqlite_rows(
               path,
               "SELECT COALESCE(owner_id, 0) FROM images WHERE id = #{image_id} LIMIT 1"
             ) do
          {:ok, [line | _]} ->
            [owner_id | _] = String.split(line, @sqlite_separator, parts: 2)
            parse_int(owner_id)

          _ ->
            0
        end
    end
  end

  defp approval_enabled? do
    Store.get_config("approve_images", "1")
    |> truthy?()
  end

  defp approved_column? do
    case sqlite_db_path() do
      nil -> repo_has_column?("images", "approved")
      path -> sqlite_has_column?(path, "images", "approved")
    end
  end

  defp approved_by_column? do
    case sqlite_db_path() do
      nil -> repo_has_column?("images", "approved_by_id")
      path -> sqlite_has_column?(path, "images", "approved_by_id")
    end
  end

  defp repo_has_column?(table, column) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2 LIMIT 1",
           [table, column]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp sqlite_has_column?(path, table, column) do
    escaped_table = escape_sqlite_string(table)

    case sqlite_rows(path, "PRAGMA table_info('#{escaped_table}')") do
      {:ok, rows} ->
        Enum.any?(rows, fn row ->
          case String.split(row, @sqlite_separator) do
            [_cid, name | _] -> String.downcase(name) == String.downcase(column)
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_rows(path, query) do
    args = ["-noheader", "-separator", @sqlite_separator, path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        rows = output |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))
        {:ok, rows}

      {error, _} ->
        Logger.warning("approval.sqlite query failed: #{String.trim(error)}")
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_exec(path, query) do
    case System.cmd("sqlite3", [path, query], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, _} ->
        Logger.warning("approval.sqlite exec failed: #{String.trim(error)}")
        {:error, :sqlite_failed}
    end
  end

  defp truthy?(value) when value in [true, 1], do: true
  defp truthy?(value) when value in [false, 0], do: false

  defp truthy?(value) do
    normalized =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized in ["1", "true", "t", "yes", "y", "on"]
  end

  defp actor_id(%{id: id}) when is_integer(id) and id > 0, do: id
  defp actor_id(_), do: 0

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")
end
