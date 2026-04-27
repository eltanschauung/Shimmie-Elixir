defmodule ShimmiePhoenixWeb.LegacyPagesHTML do
  use ShimmiePhoenixWeb, :html

  alias ShimmiePhoenixWeb.LegacyTime
  alias ShimmiePhoenix.Site.TextFormat

  embed_templates "legacy_pages_html/*"

  def format_post_date(value), do: LegacyTime.format_post_date(value)
  def datetime_attr(value), do: LegacyTime.datetime_attr(value)

  def format_comment_html(text), do: TextFormat.format_comment_html(text)
end
