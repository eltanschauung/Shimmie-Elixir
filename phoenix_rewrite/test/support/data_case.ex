defmodule ShimmiePhoenix.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ShimmiePhoenix.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ShimmiePhoenix.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ShimmiePhoenix.DataCase
    end
  end

  setup tags do
    ShimmiePhoenix.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    unless tags[:async] do
      ShimmiePhoenix.Cache.clear()
      ShimmiePhoenix.AuthThrottle.reset()
    end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ShimmiePhoenix.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    unless tags[:async] do
      # Legacy fixtures insert explicit IDs below this ceiling. PostgreSQL
      # sequences do not roll back with sandbox transactions: reserve a disjoint
      # range once, only moving forward, so repeated/randomized runs cannot collide.
      ShimmiePhoenix.Repo.query!(
        "SELECT quote_ident(schemaname)||'.'||quote_ident(sequencename), COALESCE(last_value,start_value) FROM pg_sequences WHERE schemaname=current_schema()"
      )
      |> Map.fetch!(:rows)
      |> Enum.each(fn [sequence, last] ->
        ShimmiePhoenix.Repo.query!("SELECT setval($1::text::regclass,$2,true)", [
          sequence,
          max(last, 1_000_000)
        ])
      end)
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
