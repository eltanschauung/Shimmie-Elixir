defmodule ShimmiePhoenixWeb.CommentController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site.Comments
  alias ShimmiePhoenix.Site.TelegramAlerts
  alias ShimmiePhoenix.Site.Users

  def add(conn, params) do
    actor = conn.assigns[:legacy_user] || Users.current_user(conn)
    remote_ip = Users.remote_ip_string(conn)

    case Comments.add(params, actor, remote_ip) do
      {:ok, image_id} ->
        _ = TelegramAlerts.notify_comment_added(image_id, actor, to_string(params["comment"] || ""))
        redirect(conn, to: "/post/view/#{image_id}#comment_on_#{image_id}")

      {:error, :invalid_image_id} ->
        send_resp(conn, 400, "Bad Request")

      {:error, :post_not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, reason}
      when reason in [
             :empty_comment,
             :comment_too_long,
             :comment_too_repetitive,
             :form_out_of_date,
             :duplicate_comment,
             :rate_limited
           ] ->
        image_id = parse_image_id(params["image_id"])

        redirect(
          conn,
          to:
            "/post/view/#{image_id}?error=#{URI.encode_www_form(error_message(reason))}#comment_on_#{image_id}"
        )

      {:error, reason} ->
        send_resp(conn, 403, error_message(reason))
    end
  end

  def delete(conn, %{"comment_id" => comment_id, "image_id" => image_id}) do
    actor = conn.assigns[:legacy_user] || Users.current_user(conn)
    fallback_path = "/post/view/#{parse_image_id(image_id)}"

    case Comments.delete(comment_id, actor) do
      {:ok, deleted_image_id} ->
        target = safe_referer_or(conn, "/post/view/#{deleted_image_id}")
        redirect(conn, to: target)

      {:error, :permission_denied} ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :comment_not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, :invalid_image_id} ->
        send_resp(conn, 400, "Bad Request")

      {:error, _} ->
        redirect(conn, to: fallback_path)
    end
  end

  defp error_message(:empty_comment), do: "Comments need text..."
  defp error_message(:comment_too_long), do: "Comment too long~"
  defp error_message(:comment_too_repetitive), do: "Comment too repetitive~"

  defp error_message(:form_out_of_date),
    do: "Comment submission form is out of date; refresh and try again~"

  defp error_message(:duplicate_comment),
    do: "Someone already made that comment on that image -- try being more original?"

  defp error_message(:rate_limited),
    do: "You've posted several comments recently; wait a minute and try again..."

  defp error_message(_), do: "Comment Blocked"

  defp parse_image_id(raw) do
    case Integer.parse(to_string(raw || "")) do
      {id, ""} when id > 0 -> id
      _ -> 1
    end
  end

  defp safe_referer_or(conn, fallback) do
    referer = get_req_header(conn, "referer") |> List.first()

    case URI.parse(referer || "") do
      %URI{scheme: nil, host: nil, path: path, query: query}
      when is_binary(path) and path != "" ->
        if String.starts_with?(path, "/") do
          if is_binary(query) and query != "", do: path <> "?" <> query, else: path
        else
          fallback
        end

      %URI{host: host, path: path, query: query}
      when is_binary(host) and host == conn.host and is_binary(path) and path != "" ->
        if is_binary(query) and query != "", do: path <> "?" <> query, else: path

      _ ->
        fallback
    end
  end
end
