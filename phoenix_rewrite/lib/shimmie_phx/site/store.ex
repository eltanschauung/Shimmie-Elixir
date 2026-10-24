defmodule ShimmiePhoenix.Site.Store do
  @moduledoc """
  Read helpers for legacy config and lightweight counters.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Repo

  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>
  @cache_table :shimmie_store_cache
  @config_cache_ttl_ms 600_000
  @repo_config_cache_key {:config_map, :repo}

  def get_config(name, default \\ nil) when is_binary(name) do
    case sqlite_db_path() do
      nil -> repo_get_config_cached(name, default)
      path -> sqlite_get_config_cached(path, name, default)
    end
  end

  def count_posts do
    case sqlite_db_path() do
      nil -> repo_count_posts()
      path -> sqlite_count_posts(path)
    end
  end

  def put_config(name, value) when is_binary(name) and is_binary(value) do
    case sqlite_db_path() do
      nil -> repo_put_config(name, value)
      path -> sqlite_put_config(path, name, value)
    end
  end

  defp repo_put_config(name, value) do
    case Repo.query(
           "INSERT INTO config(name, value) VALUES ($1, $2) " <>
             "ON CONFLICT(name) DO UPDATE SET value = EXCLUDED.value",
           [name, value]
         ) do
      {:ok, _} ->
        Cache.delete(@cache_table, @repo_config_cache_key)
        :ok

      _ ->
        {:error, :db_failed}
    end
  end

  defp repo_get_config_cached(name, default) do
    cache = repo_config_cache()
    Map.get(cache, name, default)
  end

  defp repo_config_cache do
    key = @repo_config_cache_key
    now = System.monotonic_time(:millisecond)

    case Cache.lookup(@cache_table, key) do
      [{^key, cache, expires_at}] when expires_at > now ->
        cache

      _ ->
        cache = load_repo_config_cache()
        Cache.insert(@cache_table, {key, cache, now + @config_cache_ttl_ms})
        cache
    end
  end

  defp load_repo_config_cache do
    case Repo.query("SELECT name, value FROM config") do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, %{}, fn
          [name, value], acc ->
            Map.put(acc, to_string(name || ""), value)

          _, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp sqlite_get_config_cached(path, name, default) do
    cache = sqlite_config_cache(path)
    Map.get(cache, name, default)
  end

  defp sqlite_put_config(path, name, value) do
    sql =
      "INSERT INTO config(name, value) VALUES ('#{escape_sqlite_string(name)}', '#{escape_sqlite_string(value)}') " <>
        "ON CONFLICT(name) DO UPDATE SET value = excluded.value"

    case sqlite_exec(path, sql) do
      :ok ->
        Cache.delete(@cache_table, {:config_map, path})
        :ok

      error ->
        error
    end
  end

  defp sqlite_config_cache(path) do
    key = {:config_map, path}
    now = System.monotonic_time(:millisecond)

    case Cache.lookup(@cache_table, key) do
      [{^key, cache, expires_at}] when expires_at > now ->
        cache

      _ ->
        cache = load_sqlite_config_cache(path)
        Cache.insert(@cache_table, {key, cache, now + @config_cache_ttl_ms})
        cache
    end
  end

  defp load_sqlite_config_cache(path) do
    query = "SELECT name, hex(value) FROM config"

    args = [
      "-noheader",
      "-separator",
      @sqlite_separator,
      "-newline",
      @sqlite_row_separator,
      path,
      query
    ]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(@sqlite_row_separator, trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, @sqlite_separator, parts: 2) do
            [name, hex] ->
              case Base.decode16(hex, case: :mixed) do
                {:ok, value} -> Map.put(acc, name, value)
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp repo_count_posts do
    case Repo.query("SELECT COUNT(*) FROM images") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp sqlite_count_posts(path) do
    case sqlite_single_value(path, "SELECT COUNT(*) FROM images") do
      {:ok, value} ->
        case Integer.parse(value) do
          {count, ""} -> count
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_single_value(path, query) do
    args = ["-noheader", "-separator", @sqlite_separator, path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        value =
          output
          |> String.split("\n", trim: true)
          |> List.first()

        if is_binary(value) and value != "" do
          {:ok, value}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_exec(path, query) do
    case System.cmd("sqlite3", [path, query], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :sqlite_failed}
    end
  end

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")
end
