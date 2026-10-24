defmodule ShimmiePhoenixWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ShimmiePhoenixWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ShimmiePhoenixWeb.Endpoint

      use ShimmiePhoenixWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ShimmiePhoenixWeb.ConnCase
    end
  end

  setup tags do
    ShimmiePhoenix.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Issues production credential-bound session proof for a synthetic fixture account."
  def sign_in(conn, id) do
    user = ShimmiePhoenix.Site.Users.get_user_by_id(id)
    if is_nil(user), do: raise("Create the synthetic account before signing in")

    conn
    |> Plug.Test.init_test_session(%{})
    |> ShimmiePhoenix.Site.Users.put_user_session(user)
  end
end
