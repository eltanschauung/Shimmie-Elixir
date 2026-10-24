defmodule ShimmiePhoenix.Site.PrivateMessages do
  @moduledoc """
  Legacy-compatible private message helpers used by `/user` and `/pm/*`.
  """

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Site.Users

  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>
  @cache_table :shimmie_private_messages_cache

  def can_read?(user), do: logged_in?(user)
  def can_send?(user), do: logged_in?(user)
  def can_view_other?(user), do: admin?(user)

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

  def list_for_display(_, _), do: []

  def unread_count(actor) when is_map(actor) do
    if can_read?(actor) do
      case backend() do
        {:repo} -> unread_count_repo(actor.id)
        {:sqlite, path} -> unread_count_sqlite(path, actor.id)
      end
    else
      0
    end
  end

  def unread_count(_), do: 0

  def list_for_user(user_id) when is_integer(user_id) and user_id > 0 do
    case backend() do
      {:repo} -> list_repo(user_id)
      {:sqlite, path} -> list_sqlite(path, user_id)
    end
  end

  def list_for_user(_), do: []

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

  def get_visible(_, _), do: {:error, :not_found}

  def mark_read(pm_id) when is_integer(pm_id) and pm_id > 0 do
    case backend() do
      {:repo} -> mark_read_repo(pm_id)
      {:sqlite, path} -> mark_read_sqlite(path, pm_id)
    end
  end

  def mark_read(_), do: {:error, :not_found}

  def delete(pm_id, actor) when is_integer(pm_id) and pm_id > 0 do
    with {:ok, pm} <- get_visible(pm_id, actor) do
      case backend() do
        {:repo} -> delete_repo(pm.id)
        {:sqlite, path} -> delete_sqlite(path, pm.id)
      end
    end
  end

  def delete(_, _), do: {:error, :not_found}

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
        case backend() do
          {:repo} ->
            send_repo(from_user.id, to_id, subject, message, from_ip)

          {:sqlite, path} ->
            send_sqlite(path, from_user.id, to_id, subject, message, from_ip)
        end
    end
  end

  def send(_, _, _, _, _), do: {:error, :invalid_request}

  defp get(pm_id) do
    case backend() do
      {:repo} -> get_repo(pm_id)
      {:sqlite, path} -> get_sqlite(path, pm_id)
    end
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

  defp list_sqlite(path, user_id) do
    with :ok <- ensure_sqlite_table(path) do
      sql =
        "SELECT pm.id, pm.from_id, COALESCE(u.name, 'Anonymous'), COALESCE(pm.from_ip, ''), pm.to_id, pm.sent_date, " <>
          "COALESCE(pm.subject, ''), COALESCE(pm.message, ''), COALESCE(pm.is_read, 0) " <>
          "FROM private_message pm LEFT JOIN users u ON u.id = pm.from_id " <>
          "WHERE pm.to_id = #{user_id} ORDER BY pm.sent_date DESC"

      sqlite_rows(path, sql)
      |> Enum.map(&row_to_pm/1)
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

  defp unread_count_sqlite(path, user_id) do
    with :ok <- ensure_sqlite_table(path),
         [[count] | _] <-
           sqlite_rows(
             path,
             "SELECT COUNT(*) FROM private_message WHERE to_id = #{user_id} AND COALESCE(is_read, 0) = 0"
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

  defp get_sqlite(path, pm_id) do
    with :ok <- ensure_sqlite_table(path),
         [row | _] <-
           sqlite_rows(
             path,
             "SELECT pm.id, pm.from_id, COALESCE(u.name, 'Anonymous'), COALESCE(pm.from_ip, ''), pm.to_id, pm.sent_date, " <>
               "COALESCE(pm.subject, ''), COALESCE(pm.message, ''), COALESCE(pm.is_read, 0) " <>
               "FROM private_message pm LEFT JOIN users u ON u.id = pm.from_id WHERE pm.id = #{pm_id} LIMIT 1"
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

  defp mark_read_sqlite(path, pm_id) do
    with :ok <- ensure_sqlite_table(path),
         :ok <- sqlite_exec(path, "UPDATE private_message SET is_read = 1 WHERE id = #{pm_id}") do
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

  defp delete_sqlite(path, pm_id) do
    with :ok <- ensure_sqlite_table(path),
         :ok <- sqlite_exec(path, "DELETE FROM private_message WHERE id = #{pm_id}") do
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

  defp send_sqlite(path, from_id, to_id, subject, message, from_ip) do
    with :ok <- ensure_sqlite_table(path),
         {:ok, next_id} <- sqlite_next_id(path),
         :ok <-
           sqlite_exec(
             path,
             "INSERT INTO private_message(id, from_id, from_ip, to_id, sent_date, subject, message, is_read) VALUES (" <>
               "#{next_id}, #{from_id}, #{sqlite_literal(normalize_ip(from_ip))}, #{to_id}, " <>
               "#{sqlite_literal(timestamp_now())}, #{sqlite_literal(normalize_subject(subject))}, " <>
               "#{sqlite_literal(message)}, 0)"
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

  defp ensure_sqlite_table(path) do
    key = {:sqlite, path, :ready}

    if cache_get(key) do
      :ok
    else
      with :ok <-
             sqlite_exec(
               path,
               "CREATE TABLE IF NOT EXISTS private_message (" <>
                 "id INTEGER PRIMARY KEY, " <>
                 "from_id INTEGER NOT NULL, " <>
                 "from_ip TEXT NOT NULL DEFAULT '', " <>
                 "to_id INTEGER NOT NULL, " <>
                 "sent_date TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " <>
                 "subject TEXT NOT NULL, " <>
                 "message TEXT NOT NULL, " <>
                 "is_read INTEGER NOT NULL DEFAULT 0)"
             ),
           :ok <-
             sqlite_exec(
               path,
               "CREATE INDEX IF NOT EXISTS private_message__to_id ON private_message(to_id)"
             ) do
        cache_put(key)
        :ok
      else
        _ -> {:error, :create_failed}
      end
    end
  end

  defp sqlite_next_id(path) do
    case sqlite_rows(path, "SELECT COALESCE(MAX(id), 0) + 1 FROM private_message") do
      [[value] | _] -> {:ok, parse_int(value)}
      _ -> {:error, :db_failed}
    end
  end

  defp backend do
    case sqlite_db_path() do
      nil -> {:repo}
      path -> {:sqlite, path}
    end
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_rows(path, sql) do
    args = [
      "-noheader",
      "-separator",
      @sqlite_separator,
      "-newline",
      @sqlite_row_separator,
      path,
      sql
    ]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(@sqlite_row_separator, trim: true)
        |> Enum.map(fn line -> String.split(line, @sqlite_separator) end)

      _ ->
        []
    end
  end

  defp sqlite_exec(path, sql) do
    case System.cmd("sqlite3", [path, sql], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :sqlite_failed}
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

  defp row_to_pm(_), do: %{}

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

  defp normalize_ip(value), do: value |> to_string() |> String.trim() |> String.slice(0, 128)

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_bool(value) when value in [true, "true", "TRUE", "t", "1", 1], do: true
  defp parse_bool(_), do: false

  defp logged_in?(%{id: id}) when is_integer(id) and id > 0 do
    id != Users.anonymous_id()
  end

  defp logged_in?(_), do: false

  defp admin?(%{class: class}), do: to_string(class) == "admin"
  defp admin?(_), do: false

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

  defp sqlite_literal(value), do: "'#{escape_sqlite_string(to_string(value))}'"
  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")

  defp timestamp_now do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end
end
