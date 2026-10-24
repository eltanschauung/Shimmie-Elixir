defmodule ShimmiePhoenix.Site.Favorites do
  @moduledoc """
  Compatibility helpers for legacy favorites behavior.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  @sqlite_separator <<31>>

  def default_user_id do
    case Integer.parse(Store.get_config("anon_id", "1") |> to_string()) do
      {id, ""} when id > 0 -> id
      _ -> 1
    end
  end

  def user_exists?(user_id) when is_integer(user_id) and user_id > 0 do
    case sqlite_db_path() do
      nil ->
        case Repo.query("SELECT 1 FROM users WHERE id = $1 LIMIT 1", [user_id]) do
          {:ok, %{rows: [[1]]}} -> true
          {:ok, %{rows: _}} -> false
          _ -> false
        end

      path ->
        query = "SELECT 1 FROM users WHERE id = #{user_id} LIMIT 1"
        sqlite_row_exists?(path, query)
    end
  end

  def user_exists?(_), do: false

  def set(image_id, user_id, do_set)
      when is_integer(image_id) and image_id > 0 and is_integer(user_id) and user_id > 0 and
             is_boolean(do_set) do
    cond do
      is_nil(Posts.get_post(image_id)) ->
        {:error, :post_not_found}

      not user_exists?(user_id) ->
        {:error, :user_not_found}

      true ->
        case sqlite_db_path() do
          nil -> set_repo(image_id, user_id, do_set)
          path -> set_sqlite(path, image_id, user_id, do_set)
        end
    end
  end

  def set(_, _, _), do: {:error, :invalid_params}

  def list_favorited_by(image_id) when is_integer(image_id) and image_id > 0 do
    case sqlite_db_path() do
      nil ->
        case Repo.query(
               "SELECT u.name FROM users u JOIN user_favorites uf ON u.id = uf.user_id WHERE uf.image_id = $1 ORDER BY u.name",
               [image_id]
             ) do
          {:ok, %{rows: rows}} -> Enum.map(rows, fn [name] -> name end)
          _ -> []
        end

      path ->
        query = """
        SELECT u.name
        FROM users u
        JOIN user_favorites uf ON u.id = uf.user_id
        WHERE uf.image_id = #{image_id}
        ORDER BY u.name
        """

        case sqlite_lines(path, query) do
          {:ok, rows} -> rows
          _ -> []
        end
    end
  end

  def list_favorited_by(_), do: []

  defp set_repo(image_id, user_id, do_set) do
    if do_set do
      Repo.query!(
        "INSERT INTO user_favorites(image_id, user_id, created_at) VALUES ($1, $2, NOW()) ON CONFLICT (image_id, user_id) DO NOTHING",
        [image_id, user_id]
      )
    else
      Repo.query!("DELETE FROM user_favorites WHERE image_id = $1 AND user_id = $2", [
        image_id,
        user_id
      ])
    end

    Repo.query!(
      "UPDATE images SET favorites = (SELECT COUNT(*) FROM user_favorites WHERE image_id = $1) WHERE id = $1",
      [image_id]
    )

    {:ok, count_for_image_repo(image_id)}
  rescue
    _ -> {:error, :db_error}
  end

  defp count_for_image_repo(image_id) do
    case Repo.query("SELECT favorites FROM images WHERE id = $1 LIMIT 1", [image_id]) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp set_sqlite(path, image_id, user_id, do_set) do
    command_sql =
      if do_set do
        "INSERT OR IGNORE INTO user_favorites(image_id, user_id, created_at) VALUES (#{image_id}, #{user_id}, CURRENT_TIMESTAMP)"
      else
        "DELETE FROM user_favorites WHERE image_id = #{image_id} AND user_id = #{user_id}"
      end

    with :ok <- sqlite_exec(path, command_sql),
         :ok <-
           sqlite_exec(
             path,
             "UPDATE images SET favorites = (SELECT COUNT(*) FROM user_favorites WHERE image_id = #{image_id}) WHERE id = #{image_id}"
           ),
         {:ok, count} <-
           sqlite_int(path, "SELECT favorites FROM images WHERE id = #{image_id} LIMIT 1") do
      {:ok, count}
    else
      _ -> {:error, :db_error}
    end
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_row_exists?(path, query) do
    case sqlite_single_line(path, query) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp sqlite_int(path, query) do
    with {:ok, value} <- sqlite_single_line(path, query),
         {count, ""} <- Integer.parse(value) do
      {:ok, count}
    else
      _ -> {:error, :invalid_int}
    end
  end

  defp sqlite_exec(path, query) do
    args = [path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :sqlite_failed}
    end
  end

  defp sqlite_single_line(path, query) do
    with {:ok, rows} <- sqlite_lines(path, query),
         [line | _] <- rows do
      {:ok, line}
    else
      _ -> {:error, :not_found}
    end
  end

  defp sqlite_lines(path, query) do
    args = ["-noheader", "-separator", @sqlite_separator, path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        rows =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, rows}

      _ ->
        {:error, :sqlite_failed}
    end
  end
end
