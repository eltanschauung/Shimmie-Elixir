defmodule ShimmiePhoenixWeb.FavoritesController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site.Favorites
  alias ShimmiePhoenix.Site.Users
  alias ShimmiePhoenix.Site.PostPolicy

  def add(conn, %{"image_id" => image_id} = params), do: set(conn, image_id, params, true)
  def remove(conn, %{"image_id" => image_id} = params), do: set(conn, image_id, params, false)

  defp set(conn, image_id, params, do_set) do
    with {post_id, ""} <- Integer.parse(image_id),
         actor <- Users.current_user(conn),
         true <- PostPolicy.active_account?(actor),
         true <- params["user_id"] in [nil, to_string(actor.id)],
         {:ok, _count} <- Favorites.set(post_id, actor, do_set) do
      redirect(conn, to: "/post/view/#{post_id}")
    else
      false ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :permission_denied} ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :post_not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, :user_not_found} ->
        send_resp(conn, 403, "User Not Found")

      {:error, _} ->
        send_resp(conn, 500, "Favorite Operation Failed")

      _ ->
        send_resp(conn, 400, "Bad Request")
    end
  end
end
