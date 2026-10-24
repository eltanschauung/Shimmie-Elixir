defmodule ShimmiePhoenix.AuthThrottleTest do
  use ExUnit.Case, async: true
  alias ShimmiePhoenix.AuthThrottle

  test "concurrent calls consume an exact atomic budget" do
    pid = start_supervised!({AuthThrottle, name: nil, account_limit: 10})

    results =
      1..60
      |> Task.async_stream(fn _ -> AuthThrottle.check(:login, "192.0.2.1", "account", pid) end)
      |> Enum.to_list()

    assert Enum.count(results, &(&1 == {:ok, :ok})) == 10
  end

  test "expiry and capacity are bounded, including rejected new identities" do
    clock = start_supervised!({Agent, fn -> 0 end})

    pid =
      start_supervised!(
        {AuthThrottle, name: nil, max_keys: 3, clock: fn -> Agent.get(clock, & &1) end}
      )

    assert :ok = AuthThrottle.check(:login, "192.0.2.1", "one", pid)
    assert {:error, :throttled} = AuthThrottle.check(:login, "192.0.2.2", "two", pid)
    Agent.update(clock, fn _ -> 600_001 end)
    assert :ok = AuthThrottle.check(:login, "192.0.2.2", "two", pid)
    assert map_size(:sys.get_state(pid).entries) == 3
  end
end
