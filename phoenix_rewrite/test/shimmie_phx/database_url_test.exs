defmodule ShimmiePhoenix.DatabaseURLTest do
  use ExUnit.Case, async: false
  alias ShimmiePhoenix.DatabaseURL

  setup do
    keys = ~w(DATABASE_URL SHIMMIE_DATABASE_URL)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  test "explicit PostgreSQL URLs have one precedence" do
    assert DatabaseURL.explicit_url() == nil
    System.put_env("SHIMMIE_DATABASE_URL", "ecto://dummy@localhost/secondary")
    assert DatabaseURL.explicit_url() == "ecto://dummy@localhost/secondary"
    System.put_env("DATABASE_URL", "postgresql://dummy@localhost/primary")
    assert DatabaseURL.explicit_url() == "postgresql://dummy@localhost/primary"
  end

  test "encoded credentials are preserved for Ecto without a second DSN parser" do
    url = "ecto://app%40name:p%40ss%3A%23%2F%3F%25word%3Dok@localhost/synthetic"
    System.put_env("DATABASE_URL", url)
    opts = DatabaseURL.explicit_url() |> Ecto.Repo.Supervisor.parse_url()
    assert opts[:username] == "app@name"
    assert opts[:password] == "p@ss:#/?%word=ok"
  end

  test "unsupported database schemes fail without disclosing their contents" do
    for url <- ["sqlite:private.sqlite", "mysql://dummy@localhost/test", "invalid"] do
      System.put_env("DATABASE_URL", url)

      assert_raise ArgumentError,
                   "A valid PostgreSQL DATABASE_URL is required",
                   &DatabaseURL.explicit_url/0
    end
  end

  test "diagnostics redact credentials and optional query secrets" do
    result = DatabaseURL.redact("ecto://app:dummy%40secret@localhost/test?password=other#private")
    assert result == "ecto://app:******@localhost/test"
    assert DatabaseURL.redact(nil) == nil
    refute DatabaseURL.redact("ecto://localhost/test?password=dummy") =~ "dummy"
  end
end
