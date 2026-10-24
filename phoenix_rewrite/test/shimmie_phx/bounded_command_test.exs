defmodule ShimmiePhoenix.BoundedCommandTest do
  use ExUnit.Case, async: false
  alias ShimmiePhoenix.BoundedCommand

  test "jobs have output and wall time limits" do
    assert {:ok, "safe"} = BoundedCommand.run("printf", ["safe"])
    assert {:error, :output_limit} = BoundedCommand.run("yes", [], max_output: 100)
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = BoundedCommand.run("sleep", ["10"], timeout: 100)
    assert System.monotonic_time(:millisecond) - started < 3000
  end

  test "workers cannot grow an unbounded job queue" do
    tasks = for _ <- 1..2, do: Task.async(fn -> BoundedCommand.run("sleep", ["2"]) end)
    wait_for_workers(20)
    assert {:error, :busy} = BoundedCommand.run("printf", ["not started"])
    Enum.each(tasks, &Task.await(&1, 5000))
  end

  test "a dead request owner cancels the external job and releases its worker" do
    owner = spawn(fn -> BoundedCommand.run("sleep", ["20"], timeout: 25_000) end)
    wait_until(fn -> length(Task.Supervisor.children(ShimmiePhoenix.ExternalSupervisor)) == 1 end)
    Process.exit(owner, :kill)
    wait_until(fn -> Task.Supervisor.children(ShimmiePhoenix.ExternalSupervisor) == [] end)
  end

  defp wait_until(predicate, retries \\ 100)
  defp wait_until(_, 0), do: flunk("job lifecycle deadline exceeded")

  defp wait_until(predicate, retries) do
    unless predicate.() do
      Process.sleep(10)
      wait_until(predicate, retries - 1)
    end
  end

  defp wait_for_workers(0), do: flunk("workers did not start")

  defp wait_for_workers(left) do
    if length(Task.Supervisor.children(ShimmiePhoenix.ExternalSupervisor)) < 2 do
      Process.sleep(10)
      wait_for_workers(left - 1)
    end
  end
end
