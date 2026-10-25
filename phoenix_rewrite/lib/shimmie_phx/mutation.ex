defmodule ShimmiePhoenix.Mutation do
  @moduledoc "All-or-nothing PostgreSQL context mutations."
  alias ShimmiePhoenix.Repo

  def atomic(fun) do
    case Repo.transaction(fn -> checked(fun.()) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :update_failed}
  end

  defp checked({:error, reason}) do
    Repo.rollback(reason)
  end

  defp checked(result) do
    result
  end
end
