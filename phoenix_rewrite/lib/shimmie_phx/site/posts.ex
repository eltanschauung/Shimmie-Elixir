defmodule ShimmiePhoenix.Site.Posts do
  @moduledoc "Read-only access helpers for legacy post data and media paths.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  @max_legacy_id 4_294_967_296
  @image_exts ~w(jpg jpeg png gif webp avif)

  def get_post(id) when is_integer(id) and id > 0 and id < @max_legacy_id do
    get_post_repo(id)
  end

  def get_post(_) do
    nil
  end

  def get_post_by_hash(hash) when is_binary(hash) do
    normalized =
      hash
      |> String.trim()
      |> String.downcase()

    if valid_hash?(normalized) do
      get_post_repo_by_hash(normalized)
    else
      nil
    end
  end

  def get_post_by_hash(_) do
    nil
  end

  def image_route(post) do
    "/image/#{post.id}/#{URI.encode(download_filename(post))}"
  end

  def download_filename(post) when is_map(post) do
    id =
      case parse_int(Map.get(post, :id)) do
        n when n > 0 -> Integer.to_string(n)
        _ -> "post"
      end

    ext =
      post
      |> Map.get(:ext, "")
      |> to_string()
      |> String.trim_leading(".")
      |> String.downcase()
      |> case do
        "" -> "bin"
        value -> value
      end

    tag_blob =
      case Map.get(post, :tags, []) do
        tags when is_list(tags) ->
          tags
          |> Enum.map(&sanitize_filename_fragment/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")
          |> String.slice(0, 150)
          |> String.trim()

        _ ->
          ""
      end

    stem =
      case tag_blob do
        "" -> id
        _ -> "#{id} - #{tag_blob}"
      end

    "#{stem}.#{ext}"
  end

  def download_filename(_) do
    "post.bin"
  end

  def thumb_route(%{id: id, hash: hash}) when is_integer(id) and is_binary(hash) do
    if valid_hash?(hash) do
      h = String.downcase(hash)
      "/thumb/#{id}/#{h}" <> thumb_version_query(h)
    else
      "/thumb/#{id}/thumb"
    end
  end

  def thumb_route(post) do
    "/thumb/#{post.id}/thumb"
  end

  def media_path(post) do
    warehouse_path("images", post.hash)
  end

  def thumb_path(post) do
    warehouse_path("thumbs", post.hash)
  end

  def thumb_path_from_hash(hash) when is_binary(hash) and byte_size(hash) == 32 do
    if valid_hash?(hash) do
      warehouse_path("thumbs", String.downcase(hash))
    else
      nil
    end
  end

  def thumb_path_from_hash(_) do
    nil
  end

  defp thumb_version_query(hash) do
    case thumb_path_from_hash(hash) do
      path when is_binary(path) ->
        case File.stat(path) do
          {:ok, %{mtime: mtime}} ->
            "?v=" <> Integer.to_string(:calendar.datetime_to_gregorian_seconds(mtime))

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  def thumb_mime do
    case Store.get_config("thumb_mime", "image/jpeg") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        "image/jpeg"
    end
  end

  def image_mime(post) do
    mime = blank_to_nil(Map.get(post, :mime))

    if is_binary(mime) and mime != "" do
      mime
    else
      MIME.from_path("file.#{post.ext}") || "application/octet-stream"
    end
  end

  def image_ext?(post) do
    String.downcase(post.ext) in @image_exts
  end

  def post_extra(image_id) when is_integer(image_id) and image_id > 0 do
    defaults = %{
      locked: false,
      rating: "?",
      parent_id: nil,
      mime: nil,
      length: nil,
      video_codec: nil
    }

    post_extra_repo(image_id, defaults)
  end

  def post_extra(_) do
    %{locked: false, rating: "?", parent_id: nil, mime: nil, length: nil, video_codec: nil}
  end

  def owner_name(image_id) when is_integer(image_id) and image_id > 0 do
    case Repo.query(
           "SELECT COALESCE(u.name, 'Anonymous') FROM images i " <>
             "LEFT JOIN users u ON u.id = i.owner_id WHERE i.id = $1 LIMIT 1",
           [image_id]
         ) do
      {:ok, %{rows: [[name]]}} -> name
      _ -> "Anonymous"
    end
  end

  def owner_name(_) do
    "Anonymous"
  end

  def tag_rows(image_id) when is_integer(image_id) and image_id > 0 do
    rows =
      case Repo.query(
             "SELECT t.tag, t.count FROM image_tags it " <>
               "JOIN tags t ON it.tag_id = t.id " <>
               "WHERE it.image_id = $1 ORDER BY t.tag",
             [image_id]
           ) do
        {:ok, %{rows: db_rows}} ->
          Enum.map(db_rows, fn [tag, count] ->
            [to_string(tag || ""), to_string(count || "0")]
          end)

        _ ->
          []
      end

    Enum.map(rows, fn [tag, count] ->
      %{
        tag: tag,
        count: parse_int(count),
        wiki_url: "https://en.wikipedia.org/wiki/#{URI.encode(tag)}"
      }
    end)
  end

  def tag_rows(_) do
    []
  end

  def comments(image_id) when is_integer(image_id) and image_id > 0 do
    rows =
      case Repo.query(
             "SELECT c.id, COALESCE(u.name, 'Anonymous'), c.posted, c.comment, COALESCE(c.owner_ip, '') " <>
               "FROM comments c LEFT JOIN users u ON u.id = c.owner_id " <>
               "WHERE c.image_id = $1 ORDER BY c.id ASC",
             [image_id]
           ) do
        {:ok, %{rows: db_rows}} ->
          Enum.map(db_rows, fn [id, owner_name, posted, comment, owner_ip] ->
            [
              to_string(id || "0"),
              to_string(owner_name || "Anonymous"),
              to_string(posted || ""),
              to_string(comment || ""),
              to_string(owner_ip || "")
            ]
          end)

        _ ->
          []
      end

    Enum.flat_map(rows, fn row ->
      case row do
        [id, owner_name, posted, comment, owner_ip] ->
          [
            %{
              id: parse_int(id),
              owner_name: owner_name,
              posted: posted,
              comment: comment,
              owner_ip: owner_ip
            }
          ]

        _ ->
          []
      end
    end)
  end

  def comments(_) do
    []
  end

  def rating_label("s") do
    "Safe"
  end

  def rating_label("q") do
    "Questionable"
  end

  def rating_label("e") do
    "Explicit"
  end

  def rating_label(_) do
    "Unrated"
  end

  defp get_post_repo(id) do
    case Repo.query(
           "SELECT id, hash, ext, filename, width, height, filesize, source, posted, COALESCE(owner_ip, '') " <>
             "FROM images WHERE id = $1",
           [id]
         ) do
      {:ok, %{rows: [row]}} ->
        row
        |> row_to_post()
        |> with_tags_repo()

      _ ->
        nil
    end
  end

  defp with_tags_repo(post) do
    case Repo.query(
           "SELECT t.tag FROM image_tags it JOIN tags t ON it.tag_id = t.id WHERE it.image_id = $1 ORDER BY t.tag",
           [post.id]
         ) do
      {:ok, %{rows: rows}} ->
        Map.put(post, :tags, Enum.map(rows, fn [tag] -> tag end))

      _ ->
        Map.put(post, :tags, [])
    end
  end

  defp get_post_repo_by_hash(hash) do
    case Repo.query(
           "SELECT id, hash, ext, filename, width, height, filesize, source, posted, COALESCE(owner_ip, '') " <>
             "FROM images WHERE hash = $1 LIMIT 1",
           [hash]
         ) do
      {:ok, %{rows: [row]}} ->
        row
        |> row_to_post()
        |> with_tags_repo()

      _ ->
        nil
    end
  end

  defp post_extra_repo(image_id, defaults) do
    case Repo.query(
           "SELECT COALESCE(locked, FALSE), COALESCE(rating, '?'), parent_id, COALESCE(mime, ''), length, COALESCE(video_codec, '') " <>
             "FROM images WHERE id = $1 LIMIT 1",
           [image_id]
         ) do
      {:ok, %{rows: [[locked, rating, parent_id, mime, length, video_codec]]}} ->
        %{
          locked: truthy?(locked),
          rating: blank_to_nil(to_string(rating || "")) || "?",
          parent_id: normalize_parent(parent_id),
          mime: blank_to_nil(to_string(mime || "")),
          length: normalize_length(length),
          video_codec: blank_to_nil(to_string(video_codec || ""))
        }

      _ ->
        defaults
    end
  end

  defp row_to_post([id, hash, ext, filename, width, height, filesize, source, posted, owner_ip]) do
    %{
      id: id,
      hash: hash,
      ext: ext,
      filename: filename,
      width: width,
      height: height,
      filesize: filesize,
      source: blank_to_nil(source),
      posted: to_string(posted),
      owner_ip: blank_to_nil(to_string(owner_ip || ""))
    }
  end

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(value) do
    value
  end

  defp normalize_parent(nil) do
    nil
  end

  defp normalize_parent(value) do
    case parse_int(value) do
      n when n > 0 -> n
      _ -> nil
    end
  end

  defp normalize_length(nil) do
    nil
  end

  defp normalize_length(value) do
    case parse_int(value) do
      n when n > 0 -> n
      _ -> nil
    end
  end

  defp truthy?(value) when value in [true, 1, "1", "t", "T", "true", "TRUE"] do
    true
  end

  defp truthy?(_) do
    false
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp valid_hash?(hash) do
    String.match?(hash, ~r/\A[0-9a-fA-F]{32}\z/)
  end

  defp sanitize_filename_fragment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9 _.-]+/u, "_")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp warehouse_path(base, hash) do
    splits = Site.warehouse_splits()

    subdirs =
      if splits <= 0 do
        []
      else
        Enum.map(0..(splits - 1), fn i -> String.slice(hash, i * 2, 2) end)
      end

    Path.join([Site.legacy_root(), "data", base] ++ subdirs ++ [hash])
  end
end
