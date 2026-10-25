defmodule ShimmiePhoenix.BackendSelectionTest do
  use ShimmiePhoenix.DataCase, async: false

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Index
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.SiteSchemaHelper

  @environment ~w(DATABASE_URL SHIMMIE_DATABASE_URL SHIMMIE_LEGACY_DSN SHIMMIE_LEGACY_ROOT SHIMMIE_LEGACY_CONFIG_PATH SECRET_KEY_BASE)

  setup do
    previous_env = Map.new(@environment, &{&1, System.get_env(&1)})

    previous_app =
      Map.new([:legacy_root, :legacy_config_path], &{&1, Application.fetch_env(:shimmie_phx, &1)})

    root = Path.join(System.tmp_dir!(), "backend_selection_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "empty.sqlite"), "")
    config = Path.join(root, "legacy.php")

    File.write!(
      config,
      "<?php\ndefine('DATABASE_DSN', 'sqlite:empty.sqlite');\ndefine('SECRET', 'synthetic-stable-secret');\n"
    )

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Enum.each(previous_app, fn
        {key, {:ok, value}} -> Application.put_env(:shimmie_phx, key, value)
        {key, :error} -> Application.delete_env(:shimmie_phx, key)
      end)

      ShimmiePhoenix.Cache.clear()
      File.rm_rf!(root)
    end)

    Enum.each(@environment, &System.delete_env/1)
    System.put_env("SHIMMIE_LEGACY_ROOT", root)
    System.put_env("SHIMMIE_LEGACY_CONFIG_PATH", config)
    System.put_env("SECRET_KEY_BASE", String.duplicate("synthetic-test-secret", 4))
    Application.put_env(:shimmie_phx, :legacy_root, root)
    Application.put_env(:shimmie_phx, :legacy_config_path, config)
    %{root: root}
  end

  test "DATABASE_URL overrides the legacy SQLite configuration without changing the legacy secret" do
    url = "ecto://dummy:dummy@localhost/synthetic"
    System.put_env("DATABASE_URL", url)
    assert Site.database_url() == url
    assert Site.database_url_source() == :env_url
    refute function_exported?(Site, :sqlite_db_path, 0)
    assert Site.secret() == "synthetic-stable-secret"
  end

  test "SHIMMIE_DATABASE_URL also overrides an explicit SQLite DSN" do
    url = "ecto://dummy:dummy@localhost/synthetic"
    System.put_env("SHIMMIE_DATABASE_URL", url)
    System.put_env("SHIMMIE_LEGACY_DSN", "sqlite:another.sqlite")
    assert Site.database_url() == url
    refute function_exported?(Site, :sqlite_db_path, 0)
  end

  test "runtime configuration and helpers use the same URL precedence in dev and prod" do
    primary = "ecto://dummy:dummy@localhost/primary"
    System.put_env("DATABASE_URL", primary)
    System.put_env("SHIMMIE_DATABASE_URL", "ecto://dummy:dummy@localhost/secondary")

    for environment <- [:dev, :prod] do
      config =
        Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__),
          env: environment,
          target: :host
        )

      assert config[:shimmie_phx][ShimmiePhoenix.Repo][:url] == primary
      assert Site.database_url() == primary
      refute function_exported?(Site, :sqlite_db_path, 0)
    end
  end

  test "SQLite selectors and allocators are no longer exposed" do
    refute function_exported?(Site, :sqlite_db_path, 0)
    refute function_exported?(ShimmiePhoenix.IDAllocator, :next_sqlite!, 2)
  end

  test "legacy-only PostgreSQL remains supported" do
    System.put_env("SHIMMIE_LEGACY_DSN", "pgsql:host=localhost;user=dummy;dbname=synthetic")
    assert Site.database_url() == "ecto://dummy@localhost/synthetic"
    refute function_exported?(Site, :sqlite_db_path, 0)
  end

  for variable <- ~w(DATABASE_URL SHIMMIE_DATABASE_URL) do
    test "#{variable} keeps post and configuration queries on PostgreSQL" do
      System.put_env(unquote(variable), "ecto://dummy:dummy@localhost/synthetic")
      SiteSchemaHelper.ensure_legacy_tables!()
      SiteSchemaHelper.reset_legacy_tables!()
      Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN DEFAULT TRUE")

      Repo.query!(
        "INSERT INTO images(id,filename,filesize,hash,ext,width,height,approved) VALUES(101,'fixture.png',1,'abcdefabcdefabcdefabcdefabcdefab','png',1,1,TRUE)"
      )

      Repo.query!("INSERT INTO config(name,value) VALUES('index_images','28')")

      assert Index.posts_per_page() == 28
      assert {[%{id: 101}], 1} = Index.list_posts("", 1, 28)
      assert Store.count_posts() == 1
      assert Store.put_config("index_images", "30") == :ok
      assert Repo.query!("SELECT value FROM config WHERE name='index_images'").rows == [["30"]]
    end
  end
end
