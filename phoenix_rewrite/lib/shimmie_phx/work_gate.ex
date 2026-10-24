defmodule ShimmiePhoenix.WorkGate do
  @moduledoc "A finite, non-queuing lease budget; crashed request owners release their slot."
  use GenServer
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def run(fun) do
    case GenServer.call(__MODULE__, :checkout) do
      {:ok, lease} ->
        try do
          fun.()
        after
          GenServer.call(__MODULE__, {:release, lease})
        end

      :busy ->
        {:error, :busy}
    end
  end

  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call(:checkout, {owner, _}, state) when map_size(state) < 2 do
    lease = Process.monitor(owner)
    {:reply, {:ok, lease}, Map.put(state, lease, owner)}
  end

  def handle_call(:checkout, _, state), do: {:reply, :busy, state}

  def handle_call({:release, lease}, {owner, _}, state) do
    if Map.get(state, lease) == owner do
      Process.demonitor(lease, [:flush])
      {:reply, :ok, Map.delete(state, lease)}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, lease, :process, _, _}, state), do: {:noreply, Map.delete(state, lease)}
end
