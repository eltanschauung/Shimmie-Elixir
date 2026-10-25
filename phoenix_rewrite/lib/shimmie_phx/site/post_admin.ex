defmodule ShimmiePhoenix.Site.PostAdmin do
  @moduledoc "Legacy-compatible post admin helpers used by post/view controls.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.PostPolicy
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  def admin?(%{class: class} = actor) do
    PostPolicy.active_account?(actor) and
      String.downcase(String.trim(to_string(class))) == "admin"
  end

  def admin?(_) do
    false
  end

  def logged_in?(actor) do
    PostPolicy.active_account?(actor)
  end

  def feature(image_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         :ok <- Store.put_config("featured_id", Integer.to_string(post.id)) do
      :ok
    else
      nil -> {:error, :post_not_found}
      {:error, _} = error -> error
      _ -> {:error, :update_failed}
    end
  end

  def regenerate_thumb(image_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         true <- Posts.image_ext?(post),
         image_path <- Posts.media_path(post),
         true <- File.exists?(image_path),
         :ok <- regenerate_thumb_file(post, image_path) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :unsupported_media}
      {:error, _} = error -> error
      _ -> {:error, :thumb_failed}
    end
  end

  def delete_image(image_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         :ok <-
           ShimmiePhoenix.Mutation.atomic(fn ->
             with :ok <- delete_post_rows(post.id), :ok <- maybe_clear_featured(post.id) do
               :ok
             end
           end) do
      _ = safe_rm(Posts.media_path(post))
      _ = safe_rm(Posts.thumb_path(post))
      :ok
    else
      nil -> {:error, :post_not_found}
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  def add_note_request(image_id, actor) do
    with {:ok, post} <- PostPolicy.writable_post(image_id, actor),
         true <- table_exists?("note_request"),
         :ok <- insert_note_request(post.id, actor.id) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :create_failed}
    end
  end

  def add_note(image_id, actor, attrs) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_add_note(image_id, actor, attrs) end)
  end

  defp do_add_note(image_id, actor, attrs) do
    with {:ok, post} <- PostPolicy.writable_post(image_id, actor),
         true <- table_exists?("notes"),
         schema <- note_schema(),
         {:ok, note} <- normalize_note(attrs),
         :ok <- insert_note(post.id, actor.id, note, schema),
         :ok <- refresh_notes_counter(post.id, schema) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :create_failed}
    end
  end

  def edit_note(image_id, note_id, actor, attrs) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_edit_note(image_id, note_id, actor, attrs) end)
  end

  defp do_edit_note(image_id, note_id, actor, attrs) do
    with {:ok, post} <- PostPolicy.writable_post(image_id, actor),
         true <- table_exists?("notes"),
         schema <- note_schema(),
         {:ok, note} <- normalize_note(attrs),
         :ok <- update_note(post.id, note_id, actor, note, schema),
         :ok <- refresh_notes_counter(post.id, schema) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :update_failed}
    end
  end

  def delete_note(image_id, note_id, actor) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_delete_note(image_id, note_id, actor) end)
  end

  defp do_delete_note(image_id, note_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         true <- table_exists?("notes"),
         :ok <- delete_note_row(post.id, note_id),
         :ok <- refresh_notes_counter(post.id, note_schema()) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  def notes_for_image(image_id) do
    if table_exists?("notes") do
      schema = note_schema()
      list_notes(image_id, schema)
    else
      []
    end
  end

  def nuke_notes(image_id, actor) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_nuke_notes(image_id, actor) end)
  end

  defp do_nuke_notes(image_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         true <- table_exists?("notes"),
         :ok <- delete_rows("notes", post.id),
         :ok <- maybe_reset_notes_counter(post.id) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  def nuke_requests(image_id, actor) do
    with :ok <- require_admin(actor),
         post when not is_nil(post) <- Posts.get_post(image_id),
         true <- table_exists?("note_request"),
         :ok <- delete_rows("note_request", post.id) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :not_supported}
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  defp normalize_note(attrs) when is_map(attrs) do
    x = parse_int_field(attrs["note_x1"])
    y = parse_int_field(attrs["note_y1"])
    height = parse_int_field(attrs["note_height"])
    width = parse_int_field(attrs["note_width"])
    text = attrs["note_text"] |> to_string() |> String.trim()

    cond do
      width <= 0 or height <= 0 -> {:error, :invalid_note}
      text == "" -> {:error, :invalid_note}
      true -> {:ok, %{x: x, y: y, width: width, height: height, text: text}}
    end
  end

  defp normalize_note(_) do
    {:error, :invalid_note}
  end

  defp insert_note(image_id, user_id, note, schema) do
    fields = [
      {"image_id", image_id},
      {schema.owner, user_id},
      {schema.x, note.x},
      {schema.y, note.y},
      {"height", note.height},
      {"width", note.width},
      {schema.body, note.text}
    ]

    fields =
      if schema.enable do
        fields ++ [{"enable", 1}]
      else
        fields
      end

    fields =
      if schema.user_ip do
        fields ++ [{"user_ip", ""}]
      else
        fields
      end

    columns = Enum.map(fields, &elem(&1, 0))
    values = Enum.map(fields, &elem(&1, 1))

    placeholders =
      1..length(values)
      |> Enum.map_join(", ", fn i -> "$#{i}" end)

    sql =
      "INSERT INTO notes(" <> Enum.join(columns, ", ") <> ") VALUES (" <> placeholders <> ")"

    repo_exec(sql, values)
  end

  defp update_note(image_id, note_id, actor, note, schema) do
    set_sql =
      "#{schema.x} = $1, #{schema.y} = $2, height = $3, width = $4, #{schema.body} = $5"

    {owner_sql, owner_args} =
      if admin?(actor) do
        {"", []}
      else
        {" AND #{schema.owner} = $8", [actor.id]}
      end

    args =
      [note.x, note.y, note.height, note.width, note.text, note_id, image_id] ++ owner_args

    case Repo.query(
           "UPDATE notes SET #{set_sql} WHERE id = $6 AND image_id = $7#{owner_sql}",
           args
         ) do
      {:ok, %{num_rows: n}} when n > 0 -> :ok
      {:ok, _} -> {:error, :note_not_found}
      _ -> {:error, :db_failed}
    end
  end

  defp delete_note_row(image_id, note_id) do
    case Repo.query("DELETE FROM notes WHERE id = $1 AND image_id = $2", [note_id, image_id]) do
      {:ok, %{num_rows: n}} when n > 0 -> :ok
      {:ok, _} -> {:error, :note_not_found}
      _ -> {:error, :db_failed}
    end
  end

  defp list_notes(image_id, schema) do
    where =
      if schema.enable do
        "image_id = :image_id AND enable = 1"
      else
        "image_id = :image_id"
      end

    sql =
      "SELECT id, #{schema.x}, #{schema.y}, width, height, #{schema.body} " <>
        "FROM notes WHERE " <> String.replace(where, ":image_id", "$1") <> " ORDER BY id ASC"

    case Repo.query(sql, [image_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, &row_to_note/1)

      _ ->
        []
    end
  end

  defp row_to_note([id, x, y, width, height, note]) do
    %{
      "note_id" => parse_int_field(id),
      "x1" => parse_int_field(x),
      "y1" => parse_int_field(y),
      "width" => parse_int_field(width),
      "height" => parse_int_field(height),
      "note" => to_string(note || "")
    }
  end

  defp row_to_note(_) do
    %{"note_id" => 0, "x1" => 0, "y1" => 0, "width" => 0, "height" => 0, "note" => ""}
  end

  defp refresh_notes_counter(image_id, schema) do
    if column_exists?("images", "notes") do
      count_where =
        if schema.enable do
          "image_id = $1 AND enable = 1"
        else
          "image_id = $1"
        end

      repo_exec(
        "UPDATE images SET notes = (SELECT COUNT(*) FROM notes WHERE #{count_where}) WHERE id = $1",
        [image_id]
      )
    else
      :ok
    end
  end

  defp note_schema do
    %{
      x:
        if(column_exists?("notes", "x")) do
          "x"
        else
          "x1"
        end,
      y:
        if(column_exists?("notes", "y")) do
          "y"
        else
          "y1"
        end,
      body:
        if(column_exists?("notes", "body")) do
          "body"
        else
          "note"
        end,
      owner:
        if(column_exists?("notes", "owner_id")) do
          "owner_id"
        else
          "user_id"
        end,
      enable: column_exists?("notes", "enable"),
      user_ip: column_exists?("notes", "user_ip")
    }
  end

  defp regenerate_thumb_file(post, image_path) do
    ShimmiePhoenix.WorkGate.run(fn ->
      thumb_path = Posts.thumb_path(post)
      File.mkdir_p!(Path.dirname(thumb_path))

      temporary =
        thumb_path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      try do
        with {:ok, _dimensions} <-
               ShimmiePhoenix.MediaValidation.prepare(image_path, post.ext, temporary),
             :ok <- File.rename(temporary, thumb_path) do
          :ok
        else
          _ -> {:error, :thumb_failed}
        end
      after
        File.rm(temporary)
      end
    end)
  end

  defp delete_post_rows(image_id) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_delete_post_rows(image_id) end)
  end

  defp do_delete_post_rows(image_id) do
    delete_post_rows_repo(image_id)
  end

  defp delete_post_rows_repo(image_id) do
    with :ok <-
           maybe_exec_repo(
             "UPDATE tags SET count = GREATEST(COALESCE(count, 0) - 1, 0) WHERE id IN (SELECT tag_id FROM image_tags WHERE image_id = $1)",
             [image_id],
             "image_tags"
           ),
         :ok <-
           maybe_exec_repo("DELETE FROM image_tags WHERE image_id = $1", [image_id], "image_tags"),
         :ok <-
           maybe_exec_repo("DELETE FROM comments WHERE image_id = $1", [image_id], "comments"),
         :ok <-
           maybe_exec_repo(
             "DELETE FROM user_favorites WHERE image_id = $1",
             [image_id],
             "user_favorites"
           ),
         :ok <-
           maybe_exec_repo(
             "DELETE FROM source_histories WHERE image_id = $1",
             [image_id],
             "source_histories"
           ),
         :ok <-
           maybe_exec_repo(
             "DELETE FROM tag_histories WHERE image_id = $1",
             [image_id],
             "tag_histories"
           ),
         :ok <-
           maybe_exec_repo(
             "DELETE FROM note_histories WHERE image_id = $1",
             [image_id],
             "note_histories"
           ),
         :ok <- maybe_exec_repo("DELETE FROM notes WHERE image_id = $1", [image_id], "notes"),
         :ok <-
           maybe_exec_repo(
             "DELETE FROM note_request WHERE image_id = $1",
             [image_id],
             "note_request"
           ),
         :ok <- repo_exec("DELETE FROM images WHERE id = $1", [image_id]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  defp insert_note_request(image_id, user_id) do
    repo_exec("INSERT INTO note_request(image_id, user_id, date) VALUES ($1, $2, NOW())", [
      image_id,
      user_id
    ])
  end

  defp delete_rows(table, image_id) do
    repo_exec("DELETE FROM #{table} WHERE image_id = $1", [image_id])
  end

  defp maybe_reset_notes_counter(image_id) do
    if column_exists?("images", "notes") do
      repo_exec("UPDATE images SET notes = 0 WHERE id = $1", [image_id])
    else
      :ok
    end
  end

  defp maybe_clear_featured(image_id) do
    featured_id =
      case Integer.parse(to_string(Store.get_config("featured_id", "0") || "0")) do
        {id, ""} -> id
        _ -> 0
      end

    if featured_id == image_id do
      Store.put_config("featured_id", "0")
    else
      :ok
    end
  end

  defp maybe_exec_repo(sql, args, table) do
    if table_exists?(table) do
      repo_exec(sql, args)
    else
      :ok
    end
  end

  defp repo_exec(sql, args) do
    case Repo.query(sql, args) do
      {:ok, _} -> :ok
      _ -> {:error, :db_failed}
    end
  end

  defp table_exists?(table) do
    repo_has_table?(table)
  end

  defp column_exists?(table, column) do
    repo_has_column?(table, column)
  end

  defp repo_has_table?(table) do
    case Repo.query(
           "SELECT 1 FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 LIMIT 1",
           [table]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp repo_has_column?(table, column) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 AND column_name = $2 LIMIT 1",
           [table, column]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp require_admin(actor) do
    if(admin?(actor)) do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp safe_rm(path) when is_binary(path) do
    if File.exists?(path) do
      File.rm(path)
    else
      :ok
    end
  end

  defp safe_rm(_) do
    :ok
  end

  defp parse_int_field(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
