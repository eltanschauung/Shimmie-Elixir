defmodule ShimmiePhoenix.CacheTest do
  use ShimmiePhoenix.DataCase, async: false

  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.SiteSchemaHelper

  @tables [
    :shimmie_legacy_cache,
    :shimmie_store_cache,
    :shimmie_ip_ban_cache,
    :shimmie_private_messages_cache
  ]

  test "all shared caches belong to their supervised owner, not a request" do
    owner = Process.whereis(Cache)
    assert is_pid(owner)

    for table <- @tables do
      assert :ets.info(table, :owner) == owner

      assert Task.async(fn -> Cache.insert(table, {:request_value, "survives"}) end)
             |> Task.await()

      assert Cache.lookup(table, :request_value) == [{:request_value, "survives"}]
    end
  end

  test "concurrent callers use existing tables without creation races" do
    results =
      Task.async_stream(
        1..64,
        fn value ->
          assert Cache.insert(:shimmie_legacy_cache, {value, value})
          assert Cache.lookup(:shimmie_legacy_cache, value) == [{value, value}]
          :ok
        end, max_concurrency: 16)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, :ok}, &1))
  end

  test "missing tables during owner restart are disposable cache misses" do
    assert :ok = Supervisor.terminate_child(ShimmiePhoenix.Supervisor, Cache)

    try do
      for table <- @tables do
        assert Cache.lookup(table, :missing) == []
        refute Cache.insert(table, {:missing, 1})
        refute Cache.delete(table, :missing)
      end

      assert :ok = Cache.clear()
    after
      {:ok, _pid} = Supervisor.restart_child(ShimmiePhoenix.Supervisor, Cache)
    end

    for table <- @tables, do: assert(Cache.lookup(table, :missing) == [])
  end

  test "short-lived config readers share one database load and writes invalidate it" do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    assert :ok = Store.put_config("cache_test", "before")
    handler = {__MODULE__, make_ref()}
    event = ShimmiePhoenix.Repo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler, event, &__MODULE__.record_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert Task.async(fn -> Store.get_config("cache_test") end) |> Task.await() == "before"
    assert_receive :config_cache_load

    for _ <- 1..20 do
      assert Task.async(fn -> Store.get_config("cache_test") end) |> Task.await() == "before"
    end

    refute_receive :config_cache_load, 50
    assert :ok = Store.put_config("cache_test", "after")
    assert Store.get_config("cache_test") == "after"
    assert_receive :config_cache_load
  end

  def record_query(_event, _measurements, metadata, owner) do
    if metadata.query == "SELECT name, value FROM config", do: send(owner, :config_cache_load)
  end
end
