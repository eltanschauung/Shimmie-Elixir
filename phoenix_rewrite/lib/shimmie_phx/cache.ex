defmodule ShimmiePhoenix.Cache do
  @moduledoc """
  Supervised owner for the application's disposable ETS caches.

  Reads and writes remain direct ETS operations. While the owner is restarting,
  a missing table is a cache miss, not a failed request. Callers retain their
  existing loading, expiration and invalidation policies.
  """
  use GenServer

  @tables [
    :shimmie_legacy_cache,
    :shimmie_store_cache,
    :shimmie_ip_ban_cache,
    :shimmie_private_messages_cache
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    for table <- @tables do
      :ets.new(table, [:named_table, :public, read_concurrency: true])
    end

    {:ok, nil}
  end

  def lookup(table, key) when table in @tables do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  def insert(table, record)
      when table in @tables and is_tuple(record) and tuple_size(record) > 0 do
    :ets.insert(table, record)
  rescue
    ArgumentError -> false
  end

  def delete(table, key) when table in @tables do
    :ets.delete(table, key)
  rescue
    ArgumentError -> false
  end

  @doc "Clears disposable cached values, without changing persisted settings."
  def clear do
    for table <- @tables do
      clear_table(table)
    end

    :ok
  end

  defp clear_table(table) do
    :ets.delete_all_objects(table)
  rescue
    ArgumentError -> false
  end
end
