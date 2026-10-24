defmodule ShimmiePhoenix.Site.PostSet do
  @moduledoc """
  Legacy-compatible /post/set handler for editing post metadata in post/view.
  """

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.PostAdmin
  alias ShimmiePhoenix.Site.TagEdit
  alias ShimmiePhoenix.SourceURL

  @allowed_ratings MapSet.new(["?", "s", "q", "e"])

  def apply(image_id, params, actor, remote_ip) do
    ShimmiePhoenix.Mutation.atomic(fn -> do_apply(image_id, params, actor, remote_ip) end)
  end

  defp do_apply(image_id, params, actor, remote_ip) do
    with {:ok, id} <- parse_image_id(image_id),
         post when not is_nil(post) <- ShimmiePhoenix.Site.PostPolicy.fetch_visible(id, actor),
         true <- can_edit_anything?(params, actor),
         :ok <- maybe_update_tags(id, params, actor, remote_ip),
         :ok <- maybe_update_meta(id, post, params, actor) do
      :ok
    else
      nil -> {:error, :post_not_found}
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_image_id}
    end
  end

  def can_edit_post_info?(actor), do: PostAdmin.admin?(actor)

  defp can_edit_anything?(params, actor) when is_map(params) do
    (has_tag_change?(params) and TagEdit.can_edit_tags?(actor)) or
      (has_meta_change?(params) and can_edit_post_info?(actor))
  end

  defp can_edit_anything?(_, _), do: false

  defp has_tag_change?(params), do: Map.has_key?(params, "tags")

  defp has_meta_change?(params) do
    Map.has_key?(params, "source") or Map.has_key?(params, "parent") or
      Map.has_key?(params, "rating") or Map.has_key?(params, "locked")
  end

  defp maybe_update_tags(image_id, params, actor, remote_ip) do
    cond do
      not Map.has_key?(params, "tags") ->
        :ok

      not TagEdit.can_edit_tags?(actor) ->
        {:error, :permission_denied}

      true ->
        TagEdit.update_tags(image_id, Map.get(params, "tags"), actor, remote_ip)
    end
  end

  defp maybe_update_meta(_image_id, _post, params, actor)
       when not is_map(params) or not is_map(actor) do
    :ok
  end

  defp maybe_update_meta(image_id, post, params, actor) do
    if can_edit_post_info?(actor) and has_meta_change?(params) do
      with {:ok, source} <- SourceURL.normalize(Map.get(params, "source", Map.get(post, :source))) do
        parent_id = normalize_parent(Map.get(params, "parent"), image_id)
        rating = normalize_rating(Map.get(params, "rating", Map.get(post, :rating)))
        locked = truthy?(Map.get(params, "locked"))
        update_meta(image_id, source, parent_id, rating, locked)
      end
    else
      :ok
    end
  end

  defp update_meta(image_id, source, parent_id, rating, locked) do
    case sqlite_db_path() do
      nil ->
        case Repo.query(
               "UPDATE images SET source = $1, parent_id = $2, rating = $3, locked = $4 WHERE id = $5",
               [source, parent_id, rating, locked, image_id]
             ) do
          {:ok, _} -> :ok
          _ -> {:error, :update_failed}
        end

      path ->
        sql =
          "UPDATE images SET " <>
            "source = #{sqlite_value(source)}, " <>
            "parent_id = #{sqlite_int_or_null(parent_id)}, " <>
            "rating = #{sqlite_value(rating)}, " <>
            "locked = #{if(locked, do: "1", else: "0")} " <>
            "WHERE id = #{image_id}"

        sqlite_exec(path, sql)
    end
  end

  defp normalize_parent(value, image_id) do
    parsed =
      case Integer.parse(to_string(value || "")) do
        {id, ""} when id > 0 -> id
        _ -> nil
      end

    if parsed == image_id, do: nil, else: parsed
  end

  defp normalize_rating(value) do
    rating = value |> to_string() |> String.trim() |> String.downcase()
    if MapSet.member?(@allowed_ratings, rating), do: rating, else: "?"
  end

  defp truthy?(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on", "y"]))
  end

  defp parse_image_id(image_id) when is_integer(image_id) and image_id > 0, do: {:ok, image_id}

  defp parse_image_id(image_id) when is_binary(image_id) do
    case Integer.parse(image_id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_image_id}
    end
  end

  defp parse_image_id(_), do: {:error, :invalid_image_id}

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_exec(path, query) do
    ShimmiePhoenix.Mutation.sqlite_exec(path, query)
  end

  defp sqlite_value(nil), do: "NULL"
  defp sqlite_value(value), do: "'" <> escape_sqlite(to_string(value)) <> "'"
  defp sqlite_int_or_null(nil), do: "NULL"
  defp sqlite_int_or_null(value), do: to_string(value)

  defp escape_sqlite(value), do: String.replace(value, "'", "''")
end
