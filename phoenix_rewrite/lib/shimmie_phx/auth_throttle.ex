defmodule ShimmiePhoenix.AuthThrottle do
  @moduledoc "Atomic, bounded authentication attempt budgets; identifiers are never retained in cleartext."
  use GenServer

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def check(operation, ip, identity, server \\ __MODULE__)
      when operation in [:login, :signup, :password_change] do
    GenServer.call(server, {:check, operation, digest(ip), digest(identity)})
  catch
    :exit, _ -> {:error, :throttled}
  end

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    Process.send_after(self(), :prune, 60_000)

    {:ok,
     %{
       entries: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       window: Keyword.get(opts, :window, 600_000),
       global_window: Keyword.get(opts, :global_window, 60_000),
       ip_limit: Keyword.get(opts, :ip_limit, 30),
       account_limit: Keyword.get(opts, :account_limit, 10),
       global_limit: Keyword.get(opts, :global_limit, 120),
       max_keys: Keyword.get(opts, :max_keys, 4096)
     }}
  end

  @impl true
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | entries: %{}}}

  def handle_call({:check, operation, ip, identity}, _from, state) do
    now = state.clock.()
    entries = prune(state.entries, now)

    budgets = [
      {{operation, :global}, state.global_limit, state.global_window},
      {{operation, :ip, ip}, state.ip_limit, state.window},
      {{operation, :account, identity}, state.account_limit, state.window}
    ]

    new_keys = Enum.count(budgets, fn {key, _, _} -> not Map.has_key?(entries, key) end)

    if map_size(entries) + new_keys > state.max_keys or
         Enum.any?(budgets, fn {key, limit, _} ->
           elem(Map.get(entries, key, {0, now}), 0) >= limit
         end) do
      {:reply, {:error, :throttled}, %{state | entries: entries}}
    else
      entries =
        Enum.reduce(budgets, entries, fn {key, _, window}, acc ->
          Map.update(acc, key, {1, now + window}, fn {count, expires} -> {count + 1, expires} end)
        end)

      {:reply, :ok, %{state | entries: entries}}
    end
  end

  @impl true
  def handle_info(:prune, state) do
    Process.send_after(self(), :prune, 60_000)
    {:noreply, %{state | entries: prune(state.entries, state.clock.())}}
  end

  defp prune(entries, now), do: Map.reject(entries, fn {_, {_, expires}} -> expires <= now end)

  defp digest(value),
    do: :crypto.hash(:sha256, value |> to_string() |> String.trim() |> String.downcase())
end
