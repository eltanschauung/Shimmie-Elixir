defmodule ShimmiePhoenix.Mutation do
  @moduledoc "All-or-nothing context mutations, including a single-connection SQLite write batch."
  alias ShimmiePhoenix.{BoundedCommand, Repo, Site}

  def atomic(fun) do
    case Site.sqlite_db_path() do
      nil ->
        case Repo.transaction(fn -> checked(fun.()) end) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end

      path ->
        sqlite_atomic(path, fun)
    end
  rescue
    _ -> {:error, :update_failed}
  end

  defp checked({:error, reason}), do: Repo.rollback(reason)
  defp checked(result), do: result

  defp sqlite_atomic(path, fun) do
    key = {__MODULE__, path}

    if Process.get(key) do
      fun.()
    else
      Process.put(key, [])

      try do
        case fun.() do
          {:error, _} = error ->
            error

          result ->
            sql = Process.get(key) |> Enum.reverse() |> Enum.join("; ")

            case execute(path, "BEGIN IMMEDIATE; " <> sql <> "; COMMIT;") do
              :ok -> result
              error -> error
            end
        end
      after
        Process.delete(key)
      end
    end
  end

  def sqlite_exec(path, sql) do
    key = {__MODULE__, path}

    case Process.get(key) do
      nil ->
        execute(path, sql)

      statements ->
        Process.put(key, [sql | statements])
        :ok
    end
  end

  defp execute(path, sql) do
    case BoundedCommand.run("sqlite3", ["-bail", "-cmd", ".timeout 5000", path, sql],
           timeout: 10_000
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :sqlite_failed}
    end
  end
end
