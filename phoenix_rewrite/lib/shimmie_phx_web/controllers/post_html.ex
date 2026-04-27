defmodule ShimmiePhoenixWeb.PostHTML do
  use ShimmiePhoenixWeb, :html

  alias ShimmiePhoenixWeb.LegacyTime
  alias ShimmiePhoenix.Site.TextFormat

  embed_templates "post_html/*"

  def format_post_date(value), do: LegacyTime.format_post_date(value)
  def datetime_attr(value), do: LegacyTime.datetime_attr(value)

  def human_filesize(value) when is_integer(value) and value >= 1024 * 1024 * 1024 do
    "#{Float.round(value / (1024 * 1024 * 1024), 1)}GB"
  end

  def human_filesize(value) when is_integer(value) and value >= 1024 * 1024 do
    "#{Float.round(value / (1024 * 1024), 1)}MB"
  end

  def human_filesize(value) when is_integer(value) and value >= 1024 do
    "#{Float.round(value / 1024, 1)}KB"
  end

  def human_filesize(value) when is_integer(value), do: "#{value}B"
  def human_filesize(_), do: "0B"

  def format_comment_html(text), do: TextFormat.format_comment_html(text)
end
