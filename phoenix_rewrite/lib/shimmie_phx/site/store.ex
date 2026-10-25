defmodule ShimmiePhoenix.Site.Store do
  @moduledoc "Read helpers for legacy config and lightweight counters.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Repo

  @cache_table :shimmie_store_cache
  @config_cache_ttl_ms 600_000
  @repo_config_cache_key {:config_map, :repo}

  def get_config(name, default \\ nil) when is_binary(name) do
    repo_get_config_cached(name, default)
  end

  def count_posts do
    repo_count_posts()
  end

  def put_config(name, value) when is_binary(name) and is_binary(value) do
    repo_put_config(name, value)
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

  defp repo_count_posts do
    case Repo.query("SELECT COUNT(*) FROM images") do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end
end
