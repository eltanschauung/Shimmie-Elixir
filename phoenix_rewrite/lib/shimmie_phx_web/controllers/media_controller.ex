defmodule ShimmiePhoenixWeb.MediaController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Users

  def image(conn, params), do: serve_post(conn, params, :image)
  def legacy_image(conn, params), do: image(conn, params)
  def thumb(conn, params), do: serve_post(conn, params, :thumb)
  def legacy_thumb(conn, params), do: thumb(conn, params)

  defp serve_post(conn, params, kind) do
    conn = fetch_session(conn)
    actor = conn.assigns[:legacy_user] || Users.current_user(conn)

    # The display filename must never select a different file from the post
    # whose visibility was authorized.
    with post when is_map(post) <- requested_post(params),
         true <- Approval.can_view_image?(post.id, actor),
         {path, mime} <- media_file(post, kind),
         true <- regular_non_symlink_file?(path) do
      conn
      |> media_headers(post, kind)
      |> put_resp_content_type(mime)
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp requested_post(%{"image_id" => image_id}) do
    case Integer.parse(image_id) do
      {id, ""} -> Posts.get_post(id)
      _ -> nil
    end
  end

  defp requested_post(%{"hash" => hash}), do: Posts.get_post_by_hash(hash)
  defp requested_post(_), do: nil

  defp media_file(post, :image), do: {Posts.media_path(post), Posts.image_mime(post)}
  defp media_file(post, :thumb), do: {Posts.thumb_path(post), Posts.thumb_mime()}

  defp media_headers(conn, post, kind) do
    conn =
      if Approval.image_approved?(post.id) do
        if kind == :thumb,
          do: put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable"),
          else: conn
      else
        put_resp_header(conn, "cache-control", "private, no-store")
      end

    if kind == :image do
      filename = safe_header_filename(Posts.download_filename(post))
      put_resp_header(conn, "content-disposition", ~s(inline; filename="#{filename}"))
    else
      conn
    end
  end

  defp regular_non_symlink_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp safe_header_filename(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n"]/u, "_")
  end
end
