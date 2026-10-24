defmodule ShimmiePhoenixWeb.CommentHTML do
  use ShimmiePhoenixWeb, :html

  embed_templates "comment_html/*"

  attr :image_id, :integer, required: true
  attr :comment_id, :integer, required: true
  attr :username, :string, required: true

  def reply_link(assigns) do
    ~H"""
    <a
      href={"/post/view/#{@image_id}#comment_on_#{@image_id}"}
      data-comment-reply
      data-image-id={@image_id}
      data-comment-id={@comment_id}
      data-username={@username}
    >
      Reply
    </a>
    """
  end
end
