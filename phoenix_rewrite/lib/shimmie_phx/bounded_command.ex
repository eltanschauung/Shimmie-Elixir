defmodule ShimmiePhoenix.BoundedCommand do
  @moduledoc "Linux external jobs with a finite worker, wall-time, memory, file and output budget."
  @supervisor ShimmiePhoenix.ExternalSupervisor

  def run(command, args, opts \\ []) do
    owner = self()
    reference = make_ref()
    timeout = min(max(Keyword.get(opts, :timeout, 30_000), 1), 30_000)

    case Task.Supervisor.start_child(@supervisor, fn ->
           result = execute(command, args, owner, timeout, Keyword.get(opts, :max_output, 65_536))
           send(owner, {reference, result})
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^reference, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^pid, _} ->
            {:error, :command_failed}
        after
          timeout + 2000 -> {:error, :timeout}
        end

      {:error, :max_children} ->
        {:error, :busy}

      _ ->
        {:error, :command_failed}
    end
  end

  defp execute(command, args, owner, timeout, output_limit) do
    monitor = Process.monitor(owner)
    executable = System.find_executable(command)
    timer = System.find_executable("timeout")
    limits = System.find_executable("prlimit")

    if executable && timer && limits do
      argv = [
        "--signal=KILL",
        "--kill-after=1s",
        "#{timeout / 1000}s",
        limits,
        "--as=335544320",
        "--cpu=25",
        "--fsize=67108864",
        "--nofile=128",
        "--",
        executable | args
      ]

      port =
        Port.open({:spawn_executable, timer}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          :hide,
          args: argv
        ])

      deadline = System.monotonic_time(:millisecond) + timeout + 500

      try do
        collect(port, monitor, deadline, min(max(output_limit, 1), 1_048_576), "")
      after
        Process.demonitor(monitor, [:flush])
        kill_group(port)
      end
    else
      {:error, :missing_tool}
    end
  rescue
    _ -> {:error, :command_failed}
  end

  defp collect(port, monitor, deadline, limit, output) do
    receive do
      {^port, {:data, chunk}} when byte_size(output) + byte_size(chunk) <= limit ->
        collect(port, monitor, deadline, limit, output <> chunk)

      {^port, {:data, _}} ->
        {:error, :output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} when status in [124, 137] ->
        {:error, :timeout}

      {^port, {:exit_status, _}} ->
        {:error, :command_failed}

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, :cancelled}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end

  defp kill_group(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when pid > 1 ->
        # GNU timeout starts its own process group; kill includes decoder children.
        System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
        Port.close(port)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
