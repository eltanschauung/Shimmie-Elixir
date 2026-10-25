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
    old_config = Application.get_env(:shimmie_phx, :site_config_path)

    Application.put_env(:shimmie_phx, :legacy_root, root)
    Application.put_env(:shimmie_phx, :legacy_assets_dir, Path.join(root, "assets"))

    Application.put_env(
      :shimmie_phx,
      :site_config_path,
      Path.join([root, "data", "config", "site.json"])
    )

    on_exit(fn ->
      Application.put_env(:shimmie_phx, :legacy_root, old_root)
      Application.put_env(:shimmie_phx, :legacy_assets_dir, old_assets)
      Application.put_env(:shimmie_phx, :site_config_path, old_config)
      File.rm_rf(root)
    end)

    %{legacy_root: root}
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

  test "legacy media routes preserve zero and multiple warehouse splits", %{
    conn: conn,
    legacy_root: root
  } do
    hash = "abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    for splits <- [0, 2] do
      config = Path.join(root, "warehouse_#{splits}.json")
      File.write!(config, Jason.encode!(%{"warehouse_splits" => splits}))
      Application.put_env(:shimmie_phx, :site_config_path, config)
      prefixes = if splits == 0, do: [], else: ["ab", "bb"]

      for warehouse <- ["images", "thumbs"] do
        parts = ["data", warehouse] ++ prefixes ++ [hash]
        path = Path.join([root | parts])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "LAYOUT-#{splits}")
        assert response(get(conn, "/" <> Enum.join(parts, "/")), 200) == "LAYOUT-#{splits}"
      end
    end
  end

  test "thumbnail filename cannot select another post's unapproved file", %{
    conn: conn,
    legacy_root: root
  } do
    hash = private_post!(root)
    conn = get(conn, "/thumb/202/#{hash}.jpg")
    assert response(conn, 200) == "THUMBDATA"
  end

  test "private thumbnail is hidden from guests but available to its owner", %{
    conn: conn,
    legacy_root: root
  } do
    hash = private_post!(root)
    assert response(get(conn, "/thumb/203/#{hash}"), 404) == "Not Found"
    conn = conn |> sign_in(77) |> get("/thumb/203/#{hash}")
    assert response(conn, 200) == "PRIVATE-THUMB"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "legacy data routes enforce the same media visibility", %{conn: conn, legacy_root: root} do
    hash = private_post!(root)

    for warehouse <- ["images", "thumbs"] do
      path = "/data/#{warehouse}/cd/#{hash}"
      assert response(get(conn, path), 404) == "Not Found"
      owner_conn = conn |> sign_in(77) |> get(path)
      expected = if warehouse == "images", do: "PRIVATE-IMAGE", else: "PRIVATE-THUMB"
      assert response(owner_conn, 200) == expected
      assert get_resp_header(owner_conn, "cache-control") == ["private, no-store"]
    end

    assert response(get(conn, "/data/images/ab/abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), 200) ==
             "PNGDATA"

    assert response(get(conn, "/data/thumbs/ab/abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), 200) ==
             "THUMBDATA"
  end

  defp private_post!(root) do
    hash = "cdcccccccccccccccccccccccccccccc"
    Repo.query!("INSERT INTO users(id, name, class) VALUES (77, 'owner', 'user')")

    Repo.query!(
      "INSERT INTO images(id, owner_id, filename, filesize, width, height, hash, ext, approved) VALUES (203, 77, 'private.png', 13, 1, 1, $1, 'png', FALSE)",
      [hash]
    )

    for {warehouse, contents} <- [{"images", "PRIVATE-IMAGE"}, {"thumbs", "PRIVATE-THUMB"}] do
      dir = Path.join([root, "data", warehouse, "cd"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, hash), contents)
    end

    hash
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
      |> sign_in(77)
      |> get("/image/202/sample.png")

    assert response(conn, 200) == "PNGDATA"
  end
end
