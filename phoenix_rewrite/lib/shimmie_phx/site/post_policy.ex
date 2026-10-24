defmodule ShimmiePhoenix.Site.PostPolicy do
  @moduledoc "Shared per-post read and authenticated-write boundary."
  alias ShimmiePhoenix.Site.{Approval, Posts}

  def fetch_visible(image_id, actor) do
    if Approval.can_view_image?(image_id, actor), do: Posts.get_post(image_id)
  end

  def active_account?(%{id: id, class: class}) when is_integer(id) and id > 0 do
    normalized = class |> to_string() |> String.trim() |> String.downcase()
    normalized not in ["", "anonymous", "ghost", "banned"]
  end

  def active_account?(_), do: false

  def writable_post(image_id, actor) do
    cond do
      not active_account?(actor) -> {:error, :permission_denied}
      post = fetch_visible(image_id, actor) -> {:ok, post}
      true -> {:error, :post_not_found}
    end
  end
end
