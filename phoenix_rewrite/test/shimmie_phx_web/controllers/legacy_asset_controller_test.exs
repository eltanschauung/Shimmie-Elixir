defmodule ShimmiePhoenixWeb.LegacyAssetControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "shimmie_phx_assets_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([root, "themes", "danbooru2"]))
    File.mkdir_p!(Path.join([root, "data", "config"]))
    File.mkdir_p!(Path.join([root, "data", "cache", "themes"]))

    File.write!(Path.join([root, "themes", "danbooru2", "style.css"]), "body{color:#000}")
    File.write!(Path.join([root, "themes", "danbooru2", "page.class.php"]), "<?php echo 1;")
    File.write!(Path.join([root, "data", "config", "shimmie.conf.php"]), "<?php secret();")

    old_root = Application.get_env(:shimmie_phx, :legacy_root)
    old_assets = Application.get_env(:shimmie_phx, :legacy_assets_dir)
    old_config = Application.get_env(:shimmie_phx, :legacy_config_path)

    Application.put_env(:shimmie_phx, :legacy_root, root)
    Application.put_env(:shimmie_phx, :legacy_assets_dir, Path.join(root, "assets"))

    Application.put_env(
      :shimmie_phx,
      :legacy_config_path,
      Path.join([root, "data", "config", "shimmie.conf.php"])
    )

    on_exit(fn ->
      Application.put_env(:shimmie_phx, :legacy_root, old_root)
      Application.put_env(:shimmie_phx, :legacy_assets_dir, old_assets)
      Application.put_env(:shimmie_phx, :legacy_config_path, old_config)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "serves allowed static theme assets", %{conn: conn} do
    conn = get(conn, "/themes/danbooru2/style.css")
    assert response(conn, 200) == "body{color:#000}"
  end

  test "blocks executable theme files", %{conn: conn} do
    conn = get(conn, "/themes/danbooru2/page.class.php")
    assert response(conn, 404) == "Not Found"
  end

  test "blocks config files under /data", %{conn: conn} do
    conn = get(conn, "/data/config/shimmie.conf.php")
    assert response(conn, 404) == "Not Found"
  end

  test "trusted static scope links work without allowing descendant link escapes", %{
    conn: conn,
    root: root
  } do
    release = Path.join(root, "release-themes")
    File.rename!(Path.join(root, "themes"), release)
    File.ln_s!(release, Path.join(root, "themes"))
    assert response(get(conn, "/themes/danbooru2/style.css"), 200) == "body{color:#000}"
    private = Path.join(root, "private")
    File.mkdir_p!(private)
    File.write!(Path.join(private, "style.css"), "private fixture")
    File.ln_s!(private, Path.join(release, "danbooru2/escape"))
    assert response(get(conn, "/themes/danbooru2/escape/style.css"), 404) == "Not Found"
    ext = Path.join(root, "release-ext")
    File.mkdir_p!(ext)
    File.write!(Path.join(ext, "script.js"), "window.fixture=true;")
    File.ln_s!(ext, Path.join(root, "ext"))
    assert response(get(conn, "/ext/script.js"), 200) == "window.fixture=true;"
  end
end
