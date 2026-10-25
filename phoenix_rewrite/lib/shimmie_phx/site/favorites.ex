defmodule ShimmiePhoenix.Site.Favorites do
  @moduledoc "Compatibility helpers for legacy favorites behavior.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.PostPolicy
  alias ShimmiePhoenix.Repo

  def user_exists?(user_id) when is_integer(user_id) and user_id > 0 do
    case Repo.query("SELECT 1 FROM users WHERE id = $1 LIMIT 1", [user_id]) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: _}} -> false
      _ -> false
    end
  end

  def user_exists?(_) do
    false
  end

  def set(image_id, %{id: user_id} = actor, do_set)
      when is_integer(image_id) and image_id > 0 and is_integer(user_id) and user_id > 0 and
             is_boolean(do_set) do
    cond do
      not PostPolicy.active_account?(actor) ->
        {:error, :permission_denied}

      not user_exists?(user_id) ->
        {:error, :user_not_found}

      true ->
        set_repo(image_id, actor, do_set)
    end
  end

  def set(_, _, _) do
    {:error, :invalid_params}
  end

  def list_favorited_by(image_id) when is_integer(image_id) and image_id > 0 do
    case Repo.query(
           "SELECT u.name FROM users u JOIN user_favorites uf ON u.id = uf.user_id WHERE uf.image_id = $1 ORDER BY u.name",
           [image_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [name] -> name end)
      _ -> []
    end
  end

  def list_favorited_by(_) do
    []
  end

  defp set_repo(image_id, actor, do_set) do
    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM images WHERE id = $1 FOR UPDATE", [image_id])

      case PostPolicy.writable_post(image_id, actor) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      user_id = actor.id

      if do_set do
        Repo.query!(
          "INSERT INTO user_favorites(image_id, user_id, created_at) VALUES ($1, $2, NOW()) ON CONFLICT (image_id, user_id) DO NOTHING",
          [image_id, user_id]
        )
      else
        Repo.query!("DELETE FROM user_favorites WHERE image_id = $1 AND user_id = $2", [
          image_id,
          user_id
        ])
      end

      Repo.query!(
        "UPDATE images SET favorites = (SELECT COUNT(*) FROM user_favorites WHERE image_id = $1) WHERE id = $1",
        [image_id]
      )

      count_for_image_repo(image_id)
    end)
  rescue
    _ -> {:error, :db_error}
  end

  defp count_for_image_repo(image_id) do
    case Repo.query("SELECT favorites FROM images WHERE id = $1 LIMIT 1", [image_id]) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end
end
