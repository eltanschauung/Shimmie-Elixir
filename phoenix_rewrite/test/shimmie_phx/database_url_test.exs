defmodule ShimmiePhoenix.DatabaseURLTest do
  use ExUnit.Case, async: false
  alias ShimmiePhoenix.DatabaseURL
  alias ShimmiePhoenix.Site

  test "ordinary legacy DSNs retain their URL and defaults" do
    assert DatabaseURL.from_legacy_dsn(
             "pgsql:host=localhost;port=5432;user=app;password=dummy;dbname=booru"
           ) == "ecto://app:dummy@localhost:5432/booru"

    assert Site.legacy_dsn_to_ecto_url("pgsql:") == "ecto://postgres@localhost/shimmie"
    assert DatabaseURL.from_legacy_dsn(nil) == nil
    assert DatabaseURL.from_legacy_dsn("sqlite:data/test.sqlite") == nil
  end

  test "reserved characters in credentials and database names round trip through Ecto" do
    url =
      DatabaseURL.from_legacy_dsn(
        "pgsql: user=app@name;password=p@ss:#/?%word=ok;dbname=booru/name?x"
      )

    opts = Ecto.Repo.Supervisor.parse_url(url)
    assert opts[:username] == "app@name"
    assert opts[:password] == "p@ss:#/?%word=ok"
    assert opts[:database] == "booru/name?x"
  end

  test "IPv6 hosts and explicit ports are represented correctly" do
    for host <- ["::1", "[::1]"] do
      url = DatabaseURL.from_legacy_dsn("pgsql:host=#{host};port=55439;dbname=test")
      assert %URI{host: "::1", port: 55439} = URI.parse(url)
    end
  end

  test "diagnostics redact credentials and optional query secrets" do
    result = DatabaseURL.redact("ecto://app:dummy%40secret@localhost/test?password=other#private")
    assert result == "ecto://app:******@localhost/test"
    assert DatabaseURL.redact(nil) == nil
    refute DatabaseURL.redact("ecto://localhost/test?password=dummy") =~ "dummy"
  end

  test "runtime config and Site share the same parser" do
    keys = ["SHIMMIE_LEGACY_DSN", "SHIMMIE_DATABASE_URL"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    dsn = "pgsql:host=localhost;user=dummy;password=p@ss;dbname=synthetic"
    System.delete_env("SHIMMIE_DATABASE_URL")
    System.put_env("SHIMMIE_LEGACY_DSN", dsn)

    config =
      Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__),
        env: :dev,
        target: :host
      )

    assert config[:shimmie_phx][ShimmiePhoenix.Repo][:url] == Site.legacy_dsn_to_ecto_url(dsn)
  end
end
