defmodule ShimmiePhoenix.Site.PrivateMessages do
  @moduledoc "Legacy-compatible private message helpers used by `/user` and `/pm/*`.\n"

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Site.Users

  @cache_table :shimmie_private_messages_cache

  def can_read?(user) do
    logged_in?(user)
  end

  def can_send?(user) do
    logged_in?(user)
  end

  def can_view_other?(user) do
    admin?(user)
  end

  def list_for_display(display_user, actor) when is_map(display_user) do
    cond do
      not can_read?(actor) ->
        []

      actor.id == display_user.id ->
        list_for_user(display_user.id)

      can_view_other?(actor) ->
        list_for_user(display_user.id)

      true ->
        []
    end
  end

  def list_for_display(_, _) do
    []
  end

  def unread_count(actor) when is_map(actor) do
    if can_read?(actor) do
      unread_count_repo(actor.id)
    else
      0
    end
  end

  def unread_count(_) do
    0
  end

  def list_for_user(user_id) when is_integer(user_id) and user_id > 0 do
    list_repo(user_id)
  end

  def list_for_user(_) do
    []
  end

  def get_visible(pm_id, actor) when is_integer(pm_id) and pm_id > 0 do
    with true <- can_read?(actor),
         {:ok, pm} <- get(pm_id),
         true <- pm.to_id == actor.id or can_view_other?(actor) do
      {:ok, pm}
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
    end
  end

  def get_visible(_, _) do
    {:error, :not_found}
  end

  def mark_read(pm_id) when is_integer(pm_id) and pm_id > 0 do
    mark_read_repo(pm_id)
  end

  def mark_read(_) do
    {:error, :not_found}
  end

  def delete(pm_id, actor) when is_integer(pm_id) and pm_id > 0 do
    with {:ok, pm} <- get_visible(pm_id, actor) do
      delete_repo(pm.id)
    end
  end

  def delete(_, _) do
    {:error, :not_found}
  end

  def send(from_user, to_id, subject, message, from_ip)
      when is_integer(to_id) and is_binary(subject) and is_binary(message) do
    cond do
      not can_send?(from_user) ->
        {:error, :permission_denied}

      is_nil(Users.get_user_by_id(to_id)) or to_id == Users.anonymous_id() ->
        {:error, :invalid_recipient}

      String.trim(message) == "" ->
        {:error, :empty_message}

      true ->
        send_repo(from_user.id, to_id, subject, message, from_ip)
    end
  end

  def send(_, _, _, _, _) do
    {:error, :invalid_request}
  end

  defp get(pm_id) do
    get_repo(pm_id)
  end

  defp list_repo(user_id) do
    with :ok <- ensure_repo_table(),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT pm.id, pm.from_id, COALESCE(u.name, 'Anonymous'), pm.from_ip, pm.to_id, pm.sent_date, " <>
               "COALESCE(pm.subject, ''), COALESCE(pm.message, ''), COALESCE(pm.is_read, FALSE) " <>
               "FROM private_message pm LEFT JOIN users u ON u.id = pm.from_id " <>
               "WHERE pm.to_id = $1 ORDER BY pm.sent_date DESC",
             [user_id]
           ) do
      Enum.map(rows, &row_to_pm/1)
    else
      _ -> []
    end
  end

  defp unread_count_repo(user_id) do
    with :ok <- ensure_repo_table(),
         {:ok, %{rows: [[count]]}} <-
           Repo.query(
             "SELECT COUNT(*) FROM private_message WHERE to_id = $1 AND COALESCE(is_read, FALSE) = FALSE",
             [user_id]
           ) do
      parse_int(count)
    else
      _ -> 0
    end
  end

  defp get_repo(pm_id) do
    with :ok <- ensure_repo_table(),
         {:ok, %{rows: [row | _]}} <-
           Repo.query(
             "SELECT pm.id, pm.from_id, COALESCE(u.name, 'Anonymous'), pm.from_ip, pm.to_id, pm.sent_date, " <>
               "COALESCE(pm.subject, ''), COALESCE(pm.message, ''), COALESCE(pm.is_read, FALSE) " <>
               "FROM private_message pm LEFT JOIN users u ON u.id = pm.from_id WHERE pm.id = $1 LIMIT 1",
             [pm_id]
           ) do
      {:ok, row_to_pm(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp mark_read_repo(pm_id) do
    with :ok <- ensure_repo_table(),
         {:ok, _} <-
           Repo.query("UPDATE private_message SET is_read = TRUE WHERE id = $1", [pm_id]) do
      :ok
    else
      _ -> {:error, :db_failed}
    end
  end

  defp delete_repo(pm_id) do
    with :ok <- ensure_repo_table(),
         {:ok, _} <- Repo.query("DELETE FROM private_message WHERE id = $1", [pm_id]) do
      :ok
    else
      _ -> {:error, :db_failed}
    end
  end

  defp send_repo(from_id, to_id, subject, message, from_ip) do
    with :ok <- ensure_repo_table(),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO private_message(from_id, from_ip, to_id, sent_date, subject, message, is_read) " <>
               "VALUES ($1, $2, $3, NOW(), $4, $5, FALSE)",
             [from_id, normalize_ip(from_ip), to_id, normalize_subject(subject), message]
           ) do
      :ok
    else
      _ -> {:error, :db_failed}
    end
  end

  defp ensure_repo_table do
    key = {:repo, :ready}

    if cache_get(key) do
      :ok
    else
      with {:ok, _} <-
             Repo.query(
               "CREATE TABLE IF NOT EXISTS private_message (" <>
                 "id BIGSERIAL PRIMARY KEY, " <>
                 "from_id BIGINT NOT NULL, " <>
                 "from_ip TEXT NOT NULL DEFAULT '', " <>
                 "to_id BIGINT NOT NULL, " <>
                 "sent_date TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(), " <>
                 "subject VARCHAR(64) NOT NULL DEFAULT '', " <>
                 "message TEXT NOT NULL, " <>
                 "is_read BOOLEAN NOT NULL DEFAULT FALSE)"
             ),
           {:ok, _} <-
             Repo.query(
               "CREATE INDEX IF NOT EXISTS private_message_to_id_idx ON private_message(to_id)"
             ) do
        cache_put(key)
        :ok
      else
        _ -> {:error, :create_failed}
      end
    end
  end

  defp row_to_pm([id, from_id, from_name, from_ip, to_id, sent_date, subject, message, is_read]) do
    %{
      id: parse_int(id),
      from_id: parse_int(from_id),
      from_name: to_string(from_name || "Anonymous"),
      from_ip: to_string(from_ip || ""),
      to_id: parse_int(to_id),
      sent_date: to_string(sent_date || ""),
      subject: normalize_subject(subject),
      message: to_string(message || ""),
      is_read: parse_bool(is_read)
    }
  end

  defp row_to_pm(_) do
    %{}
  end

  defp normalize_subject(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.slice(0, 64)
    |> case do
      "" -> "(No subject)"
      subject -> subject
    end
  end

  defp normalize_ip(value) do
    value |> to_string() |> String.trim() |> String.slice(0, 128)
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_bool(value) when value in [true, "true", "TRUE", "t", "1", 1] do
    true
  end

  defp parse_bool(_) do
    false
  end

  defp logged_in?(%{id: id}) when is_integer(id) and id > 0 do
    id != Users.anonymous_id()
  end

  defp logged_in?(_) do
    false
  end

  defp admin?(%{class: class}) do
    to_string(class) == "admin"
  end

  defp admin?(_) do
    false
  end

  defp cache_get(key) do
    case Cache.lookup(@cache_table, key) do
      [{^key, true}] -> true
      _ -> false
    end
  end

  defp cache_put(key) do
    Cache.insert(@cache_table, {key, true})
    :ok
  end
end
