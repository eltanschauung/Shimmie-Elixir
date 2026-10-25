defmodule ShimmiePhoenix.Site.UserProfile do
  @moduledoc "Legacy-compatible helpers for user profile extras (`About Me`, IP history).\n"

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site

  def biography(user_id) when is_integer(user_id) and user_id > 0 do
    biography_repo(user_id)
  end

  def biography(_) do
    ""
  end

  def set_biography(user_id, value) when is_integer(user_id) and user_id > 0 do
    clean = to_string(value || "")

    set_biography_repo(user_id, clean)
  end

  def set_biography(_, _) do
    {:error, :invalid_user}
  end

  def ip_history(%{id: user_id, name: username}) when is_integer(user_id) and user_id > 0 do
    %{
      uploads: ip_pairs_repo("images", "owner_ip", "owner_id", "posted", user_id),
      comments: ip_pairs_repo("comments", "owner_ip", "owner_id", "posted", user_id),
      events: log_ip_pairs_repo(username)
    }
  end

  def ip_history(_) do
    %{uploads: [], comments: [], events: []}
  end

  defp biography_repo(user_id) do
    with :ok <- ensure_repo_user_config_table(),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT COALESCE(value, '') FROM user_config WHERE user_id = $1 AND name = 'biography' LIMIT 1",
             [user_id]
           ) do
      case rows do
        [[value] | _] -> to_string(value || "")
        _ -> ""
      end
    else
      _ -> ""
    end
  end

  defp set_biography_repo(user_id, value) do
    with :ok <- ensure_repo_user_config_table(),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO user_config(user_id, name, value) VALUES ($1, 'biography', $2) " <>
               "ON CONFLICT(user_id, name) DO UPDATE SET value = EXCLUDED.value",
             [user_id, value]
           ) do
      :ok
    else
      _ -> {:error, :db_failed}
    end
  end

  defp ip_pairs_repo(table, ip_col, owner_col, date_col, user_id) do
    if repo_table_exists?(table) and repo_has_column?(table, ip_col) and
         repo_has_column?(table, owner_col) and repo_has_column?(table, date_col) do
      sql =
        "SELECT COALESCE(#{ip_col}, ''), COUNT(id) AS count " <>
          "FROM #{table} WHERE #{owner_col} = $1 AND COALESCE(#{ip_col}, '') <> '' " <>
          "GROUP BY #{ip_col} ORDER BY MAX(#{date_col}) DESC"

      case Repo.query(sql, [user_id]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [ip, count] -> %{ip: to_string(ip || ""), count: parse_int(count)} end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp log_ip_pairs_repo(username) when is_binary(username) do
    if repo_table_exists?("score_log") and repo_has_column?("score_log", "address") and
         repo_has_column?("score_log", "username") and repo_has_column?("score_log", "date_sent") do
      sql =
        "SELECT COALESCE(address, ''), COUNT(id) AS count " <>
          "FROM score_log WHERE username = $1 AND COALESCE(address, '') <> '' " <>
          "GROUP BY address ORDER BY MAX(date_sent) DESC"

      case Repo.query(sql, [username]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [ip, count] -> %{ip: to_string(ip || ""), count: parse_int(count)} end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp log_ip_pairs_repo(_) do
    []
  end

  defp ensure_repo_user_config_table do
    case Repo.query(
           "CREATE TABLE IF NOT EXISTS user_config (" <>
             "user_id BIGINT NOT NULL, name TEXT NOT NULL, value TEXT, " <>
             "UNIQUE(user_id, name))"
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :create_failed}
    end
  end

  defp repo_table_exists?(table_name) do
    case Repo.query(
           "SELECT 1 FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() " <>
             "AND table_name = $1 LIMIT 1",
           [table_name]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp repo_has_column?(table_name, column_name) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_schema = CURRENT_SCHEMA() " <>
             "AND table_name = $1 AND column_name = $2 LIMIT 1",
           [table_name, column_name]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
