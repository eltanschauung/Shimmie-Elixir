defmodule ShimmiePhoenix.Site.Upload do
  @moduledoc """
  Minimal upload write path for file-based uploads from `/upload`.
  """

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagRules
  alias ShimmiePhoenix.SourceURL
  alias ShimmiePhoenix.{SafeFetch, WorkGate}

  @allowed_upload_exts MapSet.new(~w(
                         jpg
                         jpeg
                         jfif
                         jfi
                         png
                         gif
                         webp
                         avif
                         zip
                         swf
                         asf
                         asx
                         wma
                         wmv
                         avi
                         flv
                         mkv
                         mp4
                         m4v
                         ogv
                         mov
                         webm
                       ))
  @upload_denied_classes MapSet.new(["ghost", "banned"])

  def can_upload?(%{id: id, class: class}) when is_integer(id) and id > 0 do
    normalized = normalize_class(class)

    cond do
      MapSet.member?(@upload_denied_classes, normalized) ->
        false

      true ->
        Permissions.allowed?(:upload, normalized)
    end
  end

  def can_upload?(_), do: false

  def upload_denied_message(actor) do
    if anonymous_actor?(actor),
      do: "Anonymous uploads are disabled by permissions",
      else: "Your account class does not have upload permission"
  end

  def create_file_upload(
        %Plug.Upload{} = upload,
        actor,
        remote_ip,
        common_tags,
        specific_tags,
        common_source,
        row_source
      ) do
    if can_upload?(actor) do
      WorkGate.run(fn ->
        do_create_file_upload(
          upload,
          actor,
          remote_ip,
          common_tags,
          specific_tags,
          common_source,
          row_source
        )
      end)
    else
      {:error, :permission_denied}
    end
  end

  defp do_create_file_upload(
         upload,
         actor,
         remote_ip,
         common_tags,
         specific_tags,
         common_source,
         row_source
       ) do
    max_size =
      parse_size(
        Store.get_config("upload_size", Integer.to_string(10 * 1024 * 1024)),
        10 * 1024 * 1024
      )

    with {:ok, source} <- SourceURL.normalize(first_non_blank([row_source, common_source])),
         {:ok, stat} <- File.stat(upload.path) do
      cond do
        stat.size <= 0 ->
          {:error, :empty_upload}

        stat.size > max_size ->
          {:error, :too_large}

        true ->
          case file_hash(upload.path) do
            {:ok, hash} ->
              if post_id_by_hash(hash) do
                {:error, :duplicate}
              else
                ext = choose_ext(upload)

                if allowed_upload_ext?(ext) do
                  filename = sanitize_filename(upload.filename, ext)
                  mime = choose_mime(ext)
                  source = source || ""
                  tags = normalized_tags(common_tags, specific_tags)
                  now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
                  owner_id = actor_id(actor)
                  owner_ip = normalize_ip(remote_ip)
                  approved = upload_starts_approved?(actor)
                  approved_by_id = if approved, do: owner_id, else: nil

                  stage_upload(upload, ext, hash, fn stage ->
                    Repo.transaction(fn ->
                      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [hash])
                      if post_id_by_hash(hash), do: Repo.rollback(:duplicate)
                      image_id = next_id("images")
                      media_path = warehouse_path("images", hash)
                      thumb_path = warehouse_path("thumbs", hash)
                      {width, height} = stage.dimensions

                      insert_image!(
                        image_id,
                        owner_id,
                        owner_ip,
                        filename,
                        stat.size,
                        hash,
                        ext,
                        source,
                        width,
                        height,
                        now,
                        approved,
                        approved_by_id,
                        mime
                      )

                      Enum.each(tags, fn tag ->
                        tag_id = upsert_tag!(tag)

                        _ =
                          Repo.query!(
                            "INSERT INTO image_tags(image_id, tag_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                            [image_id, tag_id]
                          )
                      end)

                      maybe_insert_tag_history(image_id, owner_id, owner_ip, tags, now)
                      maybe_insert_source_history(image_id, owner_id, owner_ip, source, now)

                      publish!(stage.source, media_path, stage.key)

                      if File.exists?(stage.thumb),
                        do: publish!(stage.thumb, thumb_path, stage.key)

                      image_id
                    end)
                  end)
                  |> case do
                    {:ok, image_id} -> {:ok, image_id}
                    {:error, :duplicate} -> {:error, :duplicate}
                    {:error, :invalid_upload} -> {:error, :invalid_upload}
                    {:error, _} -> {:error, :db_failed}
                  end
                else
                  {:error, :unsupported_type}
                end
              end

            _ ->
              {:error, :invalid_upload}
          end
      end
    end
  end

  def create_url_upload(
        url,
        actor,
        remote_ip,
        common_tags,
        specific_tags,
        common_source,
        row_source
      ) do
    if can_upload?(actor) do
      WorkGate.run(fn ->
        do_create_url_upload(
          url,
          actor,
          remote_ip,
          common_tags,
          specific_tags,
          common_source,
          row_source
        )
      end)
    else
      {:error, :permission_denied}
    end
  end

  defp do_create_url_upload(
         url,
         actor,
         remote_ip,
         common_tags,
         specific_tags,
         common_source,
         row_source
       ) do
    max_size =
      parse_size(
        Store.get_config("upload_size", Integer.to_string(10 * 1024 * 1024)),
        10 * 1024 * 1024
      )

    with :ok <- transload_enabled?(),
         {:ok, normalized_url} <- normalize_remote_url(url),
         {:ok, tmp_path, filename, content_type} <- fetch_remote_upload(normalized_url, max_size) do
      try do
        upload = %Plug.Upload{
          path: tmp_path,
          filename: filename,
          content_type: content_type
        }

        do_create_file_upload(
          upload,
          actor,
          remote_ip,
          common_tags,
          specific_tags,
          common_source,
          first_non_blank([row_source, normalized_url])
        )
      after
        _ = File.rm(tmp_path)
        _ = File.rmdir(Path.dirname(tmp_path))
      end
    end
  end

  defp upload_starts_approved?(actor) do
    cond do
      not Approval.approval_supported?() -> true
      Approval.can_approve?(actor) -> true
      true -> false
    end
  end

  defp transload_enabled? do
    case transload_engine() do
      "none" -> {:error, :transload_disabled}
      "" -> {:error, :transload_disabled}
      _ -> :ok
    end
  end

  defp transload_engine do
    Store.get_config("transload_engine", "none")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp anonymous_actor?(%{id: id, class: class}) when is_integer(id) do
    id == parse_int(Store.get_config("anon_id", "1"), 1) or normalize_class(class) == "anonymous"
  end

  defp anonymous_actor?(_), do: false

  defp normalize_class(class), do: class |> to_string() |> String.trim() |> String.downcase()

  defp normalize_remote_url(url) do
    case SourceURL.href(url) do
      nil -> {:error, :invalid_url}
      value -> {:ok, value}
    end
  end

  defp fetch_remote_upload(url, max_size) do
    directory = temp_directory!()
    path = Path.join(directory, "download")

    case SafeFetch.fetch(url, path, min(max_size, 64 * 1024 * 1024)) do
      :ok ->
        name =
          url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename() |> URI.decode()

        {:ok, path, name, "application/octet-stream"}

      error ->
        File.rm_rf(directory)
        error
    end
  end

  defp temp_directory! do
    root = Path.join([Site.legacy_root(), "data", ".upload-staging"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    directory = Path.join(root, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  defp file_hash(path) do
    hash =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, Base.encode16(hash, case: :lower)}
  rescue
    _ -> {:error, :invalid_upload}
  end

  defp stage_upload(upload, ext, hash, fun) do
    directory = temp_directory!()
    key = make_ref()
    source = Path.join(directory, "source")
    thumb = Path.join(directory, "thumb")
    Process.put(key, [])

    try do
      File.cp!(upload.path, source)

      with {:ok, dimensions} <- ShimmiePhoenix.MediaValidation.prepare(source, ext, thumb) do
        # A durable manifest makes the unavoidable filesystem/SQL crash window
        # inspectable. Never delete historical orphan files automatically.
        File.write!(
          Path.join(directory, "publication.json"),
          Jason.encode!(%{
            hash: hash,
            destinations: [warehouse_path("images", hash), warehouse_path("thumbs", hash)]
          }),
          [:sync]
        )

        result = fun.(%{source: source, thumb: thumb, dimensions: dimensions, key: key})

        case result do
          {:ok, _} -> Process.put(key, [])
          _ -> cleanup_created(key)
        end

        result
      end
    rescue
      _ ->
        cleanup_created(key)
        {:error, :db_failed}
    after
      if Process.get(key, []) == [], do: File.rm_rf(directory)
      Process.delete(key)
    end
  end

  defp publish!(source, destination, key) do
    File.mkdir_p!(Path.dirname(destination))
    # Same-filesystem, exclusive hard link: no overwrite/adoption of another
    # attempt's files, including unreferenced legacy files.
    File.ln!(source, destination)
    Process.put(key, [destination | Process.get(key, [])])
  end

  defp cleanup_created(key) do
    remaining =
      Enum.reject(Process.get(key, []), fn path -> File.rm(path) in [:ok, {:error, :enoent}] end)

    Process.put(key, remaining)
  end

  defp actor_id(%{id: id}) when is_integer(id) and id > 0, do: id
  defp actor_id(_), do: parse_int(Store.get_config("anon_id", "1"), 1)

  defp post_id_by_hash(hash) do
    case Repo.query("SELECT id FROM images WHERE hash = $1 LIMIT 1", [hash]) do
      {:ok, %{rows: [[id]]}} -> parse_int(id, 0)
      _ -> nil
    end
  end

  defp choose_ext(upload) do
    from_name =
      upload.filename
      |> to_string()
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    cond do
      from_name != "" ->
        from_name

      is_binary(upload.content_type) ->
        upload.content_type |> MIME.extensions() |> List.first() |> to_string()

      true ->
        "bin"
    end
  end

  defp choose_mime(ext), do: MIME.from_path("file.#{ext}") || "application/octet-stream"

  defp sanitize_filename(name, ext) do
    clean =
      name
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
      |> String.trim()

    cond do
      clean == "" -> "upload.#{ext}"
      String.downcase(Path.extname(clean)) == ".#{ext}" -> clean
      String.contains?(clean, ".") -> Path.rootname(clean) <> ".#{ext}"
      true -> clean <> "." <> ext
    end
  end

  defp allowed_upload_ext?(ext), do: MapSet.member?(@allowed_upload_exts, String.downcase(ext))

  defp warehouse_path(kind, hash) do
    splits = Site.warehouse_splits()

    subdirs =
      if splits <= 0 do
        []
      else
        Enum.map(0..(splits - 1), fn i -> String.slice(hash, i * 2, 2) end)
      end

    Path.join([Site.legacy_root(), "data", kind] ++ subdirs ++ [hash])
  end

  defp insert_image!(
         image_id,
         owner_id,
         owner_ip,
         filename,
         filesize,
         hash,
         ext,
         source,
         width,
         height,
         now,
         approved,
         approved_by_id,
         mime
       ) do
    Repo.query!(
      "INSERT INTO images(id, owner_id, owner_ip, filename, filesize, hash, ext, source, width, height, favorites, posted, locked, approved, approved_by_id, rating, parent_id, mime, length, video_codec, notes) " <>
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,0,$11,FALSE,$12,$13,'?',NULL,$14,NULL,NULL,0)",
      [
        image_id,
        owner_id,
        owner_ip,
        filename,
        filesize,
        hash,
        ext,
        source,
        width,
        height,
        now,
        approved,
        approved_by_id,
        mime
      ]
    )
  end

  defp upsert_tag!(tag) do
    sql =
      "INSERT INTO tags(id, tag, count) VALUES ($2, $1, 1) " <>
        "ON CONFLICT (tag) DO UPDATE SET count = COALESCE(tags.count, 0) + 1 " <>
        "RETURNING id"

    case Repo.query!(sql, [tag, next_id("tags")]).rows do
      [[id] | _] -> parse_int(id, 0)
      _ -> raise "Tag upsert failed"
    end
  end

  defp maybe_insert_tag_history(image_id, user_id, user_ip, tags, now) do
    tags_joined = Enum.join(tags, " ")

    if table_exists?("tag_histories") and tags_joined != "" do
      Repo.query!(
        "INSERT INTO tag_histories(id, image_id, tags, user_id, user_ip, date_set) VALUES ($1, $2, $3, $4, $5, $6)",
        [next_id("tag_histories"), image_id, tags_joined, user_id, user_ip, now]
      )
    end
  end

  defp maybe_insert_source_history(image_id, user_id, user_ip, source, now) do
    if table_exists?("source_histories") and source != "" do
      Repo.query!(
        "INSERT INTO source_histories(id, image_id, source, user_id, user_ip, date_set) VALUES ($1, $2, $3, $4, $5, $6)",
        [next_id("source_histories"), image_id, source, user_id, user_ip, now]
      )
    end
  end

  defp table_exists?(table) do
    case Repo.query(
           "SELECT 1 FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 LIMIT 1",
           [table]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp next_id(table) do
    ShimmiePhoenix.IDAllocator.next!(table)
  end

  defp normalized_tags(common_tags, specific_tags) do
    TagRules.normalize_and_expand(common_tags, specific_tags)
  end

  defp first_non_blank(values) do
    values
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp normalize_ip(value) do
    case value |> to_string() |> String.trim() do
      "" -> "0.0.0.0"
      ip -> ip
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_size(value, default) do
    raw = value |> to_string() |> String.trim()

    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b?)?$/i, raw) do
      [_, number, unit] ->
        multiplier =
          case String.downcase(unit || "") do
            "" -> 1
            "b" -> 1
            "k" -> 1024
            "kb" -> 1024
            "m" -> 1024 * 1024
            "mb" -> 1024 * 1024
            "g" -> 1024 * 1024 * 1024
            "gb" -> 1024 * 1024 * 1024
            "t" -> 1024 * 1024 * 1024 * 1024
            "tb" -> 1024 * 1024 * 1024 * 1024
            _ -> 1
          end

        case Float.parse(number) do
          {n, ""} ->
            parsed = trunc(n * multiplier)
            if(parsed > 0, do: min(parsed, 64 * 1024 * 1024), else: default)

          _ ->
            default
        end

      _ ->
        default
    end
  end
end
