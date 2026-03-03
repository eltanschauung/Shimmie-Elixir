defmodule ShimmiePhoenixWeb.MediaController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Users

  def image(conn, %{"image_id" => image_id}) do
    conn = Plug.Conn.fetch_session(conn)
    actor = conn.assigns[:legacy_user] || Users.current_user(conn)

    with {id, ""} <- Integer.parse(image_id),
         true <- Approval.can_view_image?(id, actor),
         post when not is_nil(post) <- Posts.get_post(id),
         path <- Posts.media_path(post),
         true <- regular_non_symlink_file?(path) do
      filename = safe_header_filename(Posts.download_filename(post))

      conn
      |> put_resp_content_type(Posts.image_mime(post))
      |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def thumb(conn, %{"image_id" => image_id, "filename" => filename}) do
    conn = Plug.Conn.fetch_session(conn)
    actor = conn.assigns[:legacy_user] || Users.current_user(conn)

    with {id, ""} <- Integer.parse(image_id),
         true <- Approval.can_view_image?(id, actor),
         path when is_binary(path) <- thumb_path(id, filename),
         true <- regular_non_symlink_file?(path) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type(Posts.thumb_mime())
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp thumb_path(id, filename) do
    hash_guess =
      filename
      |> to_string()
      |> String.split(".", parts: 2)
      |> List.first()
      |> to_string()
      |> String.downcase()

    case Posts.thumb_path_from_hash(hash_guess) do
      path when is_binary(path) ->
        if File.exists?(path) do
          path
        else
          thumb_path_from_db(id)
        end

      _ ->
        thumb_path_from_db(id)
    end
  end

  defp thumb_path_from_db(id) do
    case Posts.get_post(id) do
      nil -> nil
      post -> Posts.thumb_path(post)
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
