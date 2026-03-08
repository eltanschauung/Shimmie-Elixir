defmodule ShimmiePhoenixWeb.MediaControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  alias ShimmiePhoenix.SiteSchemaHelper
  alias ShimmiePhoenix.Repo

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved_by_id BIGINT")

    hash = "abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    Repo.query!(
      """
      INSERT INTO images(id, owner_id, filename, filesize, hash, ext, source, width, height, posted, approved)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [202, 2, "sample.png", 11, hash, "png", nil, 1, 1, ~N[2026-01-01 12:00:00], true]
    )

    root =
      Path.join(System.tmp_dir!(), "shimmie_phx_legacy_#{System.unique_integer([:positive])}")

    image_dir = Path.join([root, "data", "images", "ab"])
    thumb_dir = Path.join([root, "data", "thumbs", "ab"])
    File.mkdir_p!(image_dir)
    File.mkdir_p!(thumb_dir)

    image_path = Path.join(image_dir, hash)
    thumb_path = Path.join(thumb_dir, hash)

    File.write!(image_path, "PNGDATA")
    File.write!(thumb_path, "THUMBDATA")

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

    :ok
  end

  test "GET /image/:id/:filename serves original media", %{conn: conn} do
    conn = get(conn, "/image/202/sample.png")
    assert response(conn, 200) == "PNGDATA"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "image/png"
  end

  test "GET /_images/:hash/:filename serves original media via legacy hash route", %{conn: conn} do
    conn =
      get(
        conn,
        "/_images/abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/1907%20-%20forward_facing%20sample.png"
      )

    assert response(conn, 200) == "PNGDATA"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "image/png"
  end

  test "GET /thumb/:id/:filename serves thumbnail", %{conn: conn} do
    conn = get(conn, "/thumb/202/thumb")
    assert response(conn, 200) == "THUMBDATA"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "image/jpeg"
  end

  test "GET /image/:id/:filename hides unapproved media from anonymous users", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE, owner_id = 77 WHERE id = 202")
    conn = get(conn, "/image/202/sample.png")
    assert response(conn, 404) == "Not Found"
  end

  test "GET /image/:id/:filename allows owners to view unapproved media", %{conn: conn} do
    Repo.query!(
      "INSERT INTO users(id, name, pass, class, joindate) VALUES ($1, $2, $3, $4, NOW())",
      [77, "owner", "", "user"]
    )

    Repo.query!("UPDATE images SET approved = FALSE, owner_id = 77 WHERE id = 202")

    conn =
      conn
      |> init_test_session(%{site_user_id: 77, site_user_name: "owner"})
      |> get("/image/202/sample.png")

    assert response(conn, 200) == "PNGDATA"
  end
end
