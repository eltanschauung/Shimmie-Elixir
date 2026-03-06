defmodule ShimmiePhoenix.Site.TagEdit do
  @moduledoc """
  Tag edit helpers for post/view tag updates.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagRules
  alias ShimmiePhoenix.Repo

  require Logger

  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>

  def can_edit_tags?(actor) do
    actor_id(actor) > 0 and Permissions.allowed?(:tag_edit, actor_class(actor))
  end

  def update_tags(image_id, tags_string, actor, remote_ip) do
    with {:ok, image_id} <- parse_image_id(image_id),
         true <- can_edit_tags?(actor),
         {:ok, tags} <- normalize_tags(tags_string),
         post when not is_nil(post) <- Posts.get_post(image_id),
         :ok <- apply_update(post.id, tags, actor, remote_ip) do
      :ok
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :update_failed}
    end
  end

  defp apply_update(image_id, tags, actor, remote_ip) do
    case sqlite_db_path() do
      nil -> update_repo(image_id, tags, actor, remote_ip)
      path -> update_sqlite(path, image_id, tags, actor, remote_ip)
    end
  end

  defp actor_class(%{class: class}) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp actor_class(_), do: ""

  defp update_repo(image_id, tags, actor, remote_ip) do
    Repo.transaction(fn ->
      current = current_tags_repo(image_id) |> MapSet.new()
      desired = MapSet.new(tags)
      to_add = MapSet.difference(desired, current) |> MapSet.to_list()
      to_remove = MapSet.difference(current, desired) |> MapSet.to_list()

      Enum.each(to_remove, fn tag ->
        with {:ok, tag_id} <- tag_id_repo(tag),
             {:ok, true} <- delete_image_tag_repo(image_id, tag_id) do
          _ = Repo.query("UPDATE tags SET count = GREATEST(COALESCE(count, 0) - 1, 0) WHERE id = $1", [
            tag_id
          ])
        else
          _ -> :ok
        end
      end)

      Enum.each(to_add, fn tag ->
        tag_id = upsert_tag_repo(tag)
        case Repo.query(
               "INSERT INTO image_tags(image_id, tag_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING 1",
               [image_id, tag_id]
             ) do
          {:ok, %{rows: [[1]]}} ->
            _ = Repo.query("UPDATE tags SET count = COALESCE(count, 0) + 1 WHERE id = $1", [tag_id])

          _ ->
            :ok
        end
      end)

      maybe_insert_tag_history_repo(image_id, actor_id(actor), normalize_ip(remote_ip), tags)
    end)

    :ok
  rescue
    _ -> {:error, :update_failed}
  end

  defp update_sqlite(path, image_id, tags, actor, remote_ip) do
    current = current_tags_sqlite(path, image_id) |> MapSet.new()
    desired = MapSet.new(tags)
    to_add = MapSet.difference(desired, current) |> MapSet.to_list()
    to_remove = MapSet.difference(current, desired) |> MapSet.to_list()

    Enum.each(to_remove, fn tag ->
      case sqlite_single(path, "SELECT id FROM tags WHERE tag = #{sqlite_literal(tag)}") do
        nil ->
          :ok

        tag_id ->
          _ =
            sqlite_exec(
              path,
              "DELETE FROM image_tags WHERE image_id = #{image_id} AND tag_id = #{tag_id}"
            )

          _ =
            sqlite_exec(
              path,
              "UPDATE tags SET count = MAX(COALESCE(count, 0) - 1, 0) WHERE id = #{tag_id}"
            )
      end
    end)

    Enum.each(to_add, fn tag ->
      tag_id =
        case sqlite_single(path, "SELECT id FROM tags WHERE tag = #{sqlite_literal(tag)}") do
          nil ->
            next_id =
              case sqlite_single(path, "SELECT COALESCE(MAX(id), 0) + 1 FROM tags") do
                nil -> 1
                value -> parse_int(value)
              end

            _ =
              sqlite_exec(
                path,
                "INSERT INTO tags(id, tag, count) VALUES (#{next_id}, #{sqlite_literal(tag)}, 1)"
              )

            next_id

          value ->
            _ =
              sqlite_exec(
                path,
                "UPDATE tags SET count = COALESCE(count, 0) + 1 WHERE id = #{value}"
              )

            parse_int(value)
        end

      _ =
        sqlite_exec(
          path,
          "INSERT OR IGNORE INTO image_tags(image_id, tag_id) VALUES (#{image_id}, #{tag_id})"
        )
    end)

    maybe_insert_tag_history_sqlite(path, image_id, actor_id(actor), normalize_ip(remote_ip), tags)
    :ok
  end

  defp current_tags_repo(image_id) do
    case Repo.query(
           "SELECT t.tag FROM image_tags it JOIN tags t ON it.tag_id = t.id WHERE it.image_id = $1 ORDER BY t.tag",
           [image_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [tag] -> to_string(tag || "") end)
      _ -> []
    end
  end

  defp current_tags_sqlite(path, image_id) do
    query =
      "SELECT t.tag FROM image_tags it JOIN tags t ON it.tag_id = t.id WHERE it.image_id = #{image_id} ORDER BY t.tag"

    case sqlite_rows(path, query) do
      {:ok, rows} -> Enum.map(rows, fn [tag] -> to_string(tag || "") end)
      _ -> []
    end
  end

  defp tag_id_repo(tag) do
    case Repo.query("SELECT id FROM tags WHERE tag = $1 LIMIT 1", [tag]) do
      {:ok, %{rows: [[id]]}} -> {:ok, parse_int(id)}
      _ -> {:error, :not_found}
    end
  end

  defp delete_image_tag_repo(image_id, tag_id) do
    case Repo.query(
           "DELETE FROM image_tags WHERE image_id = $1 AND tag_id = $2 RETURNING 1",
           [image_id, tag_id]
         ) do
      {:ok, %{rows: [[1]]}} -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  defp upsert_tag_repo(tag) do
    sql =
      "WITH existing AS (" <>
        "  SELECT id FROM tags WHERE tag = $1" <>
        "), next_id AS (" <>
        "  SELECT COALESCE(MAX(id), 0) + 1 AS id FROM tags" <>
        ") " <>
        "INSERT INTO tags(id, tag, count) " <>
        "SELECT COALESCE((SELECT id FROM existing), (SELECT id FROM next_id)), $1, 0 " <>
        "ON CONFLICT (tag) DO UPDATE SET tag = EXCLUDED.tag " <>
        "RETURNING id"

    case Repo.query!(sql, [tag]).rows do
      [[id] | _] -> parse_int(id)
      _ -> 0
    end
  end

  defp maybe_insert_tag_history_repo(image_id, user_id, user_ip, tags) do
    tags_joined = Enum.join(tags, " ")
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    if table_exists_repo?("tag_histories") do
      Repo.query(
        "INSERT INTO tag_histories(id, image_id, tags, user_id, user_ip, date_set) VALUES ($1, $2, $3, $4, $5, $6)",
        [next_id_repo("tag_histories"), image_id, tags_joined, user_id, user_ip, now]
      )

      :ok
    else
      :ok
    end
  end

  defp maybe_insert_tag_history_sqlite(path, image_id, user_id, user_ip, tags) do
    tags_joined = Enum.join(tags, " ")
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> to_string()

    if sqlite_table_exists?(path, "tag_histories") do
      next_id =
        case sqlite_single(path, "SELECT COALESCE(MAX(id), 0) + 1 FROM tag_histories") do
          nil -> 1
          value -> parse_int(value)
        end

      _ =
        sqlite_exec(
          path,
          "INSERT INTO tag_histories(id, image_id, tags, user_id, user_ip, date_set) VALUES (" <>
            "#{next_id}, #{image_id}, #{sqlite_literal(tags_joined)}, #{user_id}, " <>
            "#{sqlite_literal(user_ip)}, #{sqlite_literal(now)})"
        )

      :ok
    else
      :ok
    end
  end

  defp table_exists_repo?(table) do
    case Repo.query(
           "SELECT 1 FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 LIMIT 1",
           [table]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp next_id_repo(table) do
    case Repo.query("SELECT COALESCE(MAX(id), 0) + 1 FROM #{table}", []) do
      {:ok, %{rows: [[id]]}} -> parse_int(id)
      _ -> 1
    end
  end

  defp parse_image_id(value) do
    case Integer.parse(to_string(value || "")) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_image_id}
    end
  end

  defp normalize_tags(value) do
    {:ok, TagRules.normalize_and_expand(value)}
  end

  defp actor_id(%{id: id}) do
    parsed = parse_int(id)

    if parsed > 0 do
      parsed
    else
      Store.get_config("anon_id", "1") |> to_string() |> parse_int()
    end
  end

  defp actor_id(_), do: Store.get_config("anon_id", "1") |> to_string() |> parse_int()

  defp normalize_ip(value) do
    case value |> to_string() |> String.trim() do
      "" -> "0.0.0.0"
      ip -> ip
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_rows(path, query) do
    args = ["-noheader", "-separator", @sqlite_separator, "-newline", @sqlite_row_separator, path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        rows =
          output
          |> String.split(@sqlite_row_separator, trim: true)
          |> Enum.map(fn line -> String.split(line, @sqlite_separator) end)

        {:ok, rows}

      {output, _} ->
        Logger.warning("tag_edit.sqlite rows failed: #{String.trim(output)}")
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_single(path, query) do
    case System.cmd("sqlite3", ["-noheader", path, query], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()

      _ ->
        nil
    end
  end

  defp sqlite_exec(path, query) do
    case System.cmd("sqlite3", [path, query], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :sqlite_failed}
    end
  end

  defp sqlite_table_exists?(path, table) do
    escaped_table = escape_sqlite_string(table)

    case sqlite_rows(path, "PRAGMA table_info('#{escaped_table}')") do
      {:ok, rows} ->
        Enum.any?(rows, fn row ->
          case String.split(row, @sqlite_separator) do
            [_cid, name | _] -> String.downcase(name) == "id"
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  defp sqlite_literal(value) do
    "'" <> escape_sqlite_string(value) <> "'"
  end

  defp escape_sqlite_string(value) do
    value
    |> to_string()
    |> String.replace("'", "''")
  end
end
