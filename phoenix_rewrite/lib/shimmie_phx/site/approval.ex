defmodule ShimmiePhoenix.Site.Approval do
  @moduledoc "Legacy-compatible approval helpers for moderating image visibility.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  def can_approve?(%{id: id, class: class}) when is_integer(id) and id > 0 do
    approval_enabled?() and Permissions.allowed?(:approve, class)
  end

  def can_approve?(_) do
    false
  end

  def approval_supported? do
    approval_enabled?() and approved_column?()
  end

  def image_approved?(image_id) when is_integer(image_id) and image_id > 0 do
    if approved_column?() do
      repo_image_approved(image_id)
    else
      true
    end
  end

  def image_approved?(_) do
    true
  end

  def can_view_image?(image_id, actor) when is_integer(image_id) and image_id > 0 do
    cond do
      not image_exists?(image_id) ->
        false

      not approval_supported?() ->
        true

      can_approve?(actor) ->
        true

      image_approved?(image_id) ->
        true

      true ->
        actor_id(actor) > 0 and actor_id(actor) == image_owner_id(image_id)
    end
  end

  def can_view_image?(_, _) do
    false
  end

  def approve(image_id, actor) do
    set_approval(image_id, actor, true)
  end

  def disapprove(image_id, actor) do
    set_approval(image_id, actor, false)
  end

  def set_approval(image_id, actor, approved?) when is_boolean(approved?) do
    cond do
      not (is_integer(image_id) and image_id > 0) ->
        {:error, :invalid_image_id}

      not can_approve?(actor) ->
        {:error, :permission_denied}

      not approved_column?() ->
        {:error, :approval_not_supported}

      not image_exists?(image_id) ->
        {:error, :post_not_found}

      true ->
        run_update(image_id, actor.id, approved?)
    end
  end

  defp run_update(image_id, actor_id, approved?) do
    repo_update(image_id, actor_id, approved?)
  end

  defp repo_update(image_id, actor_id, approved?) do
    with {sql, params} <- repo_update_sql(image_id, actor_id, approved?),
         {:ok, _} <- Repo.query(sql, params) do
      :ok
    else
      _ -> {:error, :update_failed}
    end
  end

  defp repo_update_sql(image_id, actor_id, true) do
    if approved_by_column?() do
      {"UPDATE images SET approved = $1, approved_by_id = $2 WHERE id = $3 AND COALESCE(approved, FALSE) != TRUE",
       [true, actor_id, image_id]}
    else
      {"UPDATE images SET approved = $1 WHERE id = $2 AND COALESCE(approved, FALSE) != TRUE",
       [true, image_id]}
    end
  end

  defp repo_update_sql(image_id, _actor_id, false) do
    if approved_by_column?() do
      {"UPDATE images SET approved = $1, approved_by_id = NULL WHERE id = $2 AND COALESCE(approved, TRUE) = TRUE",
       [false, image_id]}
    else
      {"UPDATE images SET approved = $1 WHERE id = $2 AND COALESCE(approved, TRUE) = TRUE",
       [false, image_id]}
    end
  end

  defp repo_image_approved(image_id) do
    case Repo.query("SELECT COALESCE(approved, TRUE) FROM images WHERE id = $1 LIMIT 1", [
           image_id
         ]) do
      {:ok, %{rows: [[value]]}} -> truthy?(value)
      _ -> true
    end
  end

  defp image_exists?(image_id) do
    case Repo.query("SELECT 1 FROM images WHERE id = $1 LIMIT 1", [image_id]) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp image_owner_id(image_id) do
    case Repo.query("SELECT COALESCE(owner_id, 0) FROM images WHERE id = $1 LIMIT 1", [image_id]) do
      {:ok, %{rows: [[owner_id]]}} -> parse_int(owner_id)
      _ -> 0
    end
  end

  defp approval_enabled? do
    Store.get_config("approve_images", "1")
    |> truthy?()
  end

  defp approved_column? do
    repo_has_column?("images", "approved")
  end

  defp approved_by_column? do
    repo_has_column?("images", "approved_by_id")
  end

  defp repo_has_column?(table, column) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2 LIMIT 1",
           [table, column]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp truthy?(value) when value in [true, 1] do
    true
  end

  defp truthy?(value) when value in [false, 0] do
    false
  end

  defp truthy?(value) do
    normalized =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized in ["1", "true", "t", "yes", "y", "on"]
  end

  defp actor_id(%{id: id}) when is_integer(id) and id > 0 do
    id
  end

  defp actor_id(_) do
    0
  end

  defp parse_int(value) when is_integer(value) do
    value
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
