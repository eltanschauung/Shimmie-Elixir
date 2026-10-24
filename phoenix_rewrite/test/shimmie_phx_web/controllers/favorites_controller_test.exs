defmodule ShimmiePhoenixWeb.FavoritesControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  alias ShimmiePhoenix.SiteSchemaHelper
  alias ShimmiePhoenix.Repo

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["anon_id", "1"])

    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [
      1,
      "Anonymous",
      "anonymous"
    ])

    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [2, "alice", "user"])

    Repo.query!(
      """
      INSERT INTO images(id, filename, filesize, hash, ext, source, width, height, favorites, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
      """,
      [
        301,
        "fav.png",
        1,
        "addddddddddddddddddddddddddddddd",
        "png",
        nil,
        1,
        1,
        0,
        ~N[2026-01-01 12:00:00]
      ]
    )

    :ok
  end

  test "POST /favourite/add/:id adds favorite and redirects", %{conn: conn} do
    conn = conn |> init_test_session(%{site_user_id: 2}) |> post("/favourite/add/301", %{})
    assert redirected_to(conn) == "/post/view/301"

    assert Repo.query!("SELECT COUNT(*) FROM user_favorites WHERE image_id = 301 AND user_id = 2").rows ==
             [[1]]

    assert Repo.query!("SELECT favorites FROM images WHERE id = 301").rows == [[1]]

    conn = post(recycle(conn), "/favourite/add/301", %{"user_id" => "2"})
    assert redirected_to(conn) == "/post/view/301"

    assert Repo.query!("SELECT COUNT(*) FROM user_favorites WHERE image_id = 301 AND user_id = 2").rows ==
             [[1]]

    assert Repo.query!("SELECT favorites FROM images WHERE id = 301").rows == [[1]]
  end

  test "POST /favourite/remove/:id removes favorite and redirects", %{conn: conn} do
    Repo.query!(
      "INSERT INTO user_favorites(image_id, user_id, created_at) VALUES ($1, $2, NOW()) ON CONFLICT (image_id, user_id) DO NOTHING",
      [301, 2]
    )

    Repo.query!(
      "UPDATE images SET favorites = (SELECT COUNT(*) FROM user_favorites WHERE image_id = 301) WHERE id = 301"
    )

    conn = conn |> init_test_session(%{site_user_id: 2}) |> post("/favourite/remove/301", %{})
    assert redirected_to(conn) == "/post/view/301"

    assert Repo.query!("SELECT COUNT(*) FROM user_favorites WHERE image_id = 301 AND user_id = 2").rows ==
             [[0]]

    assert Repo.query!("SELECT favorites FROM images WHERE id = 301").rows == [[0]]
  end

  test "POST /favourite/add/:id returns 404 for missing post", %{conn: conn} do
    conn = conn |> init_test_session(%{site_user_id: 2}) |> post("/favourite/add/999999", %{})
    assert response(conn, 404)
  end

  test "favorite writes reject nonexistent accounts without creating orphan rows" do
    assert ShimmiePhoenix.Site.Favorites.user_exists?(2)
    refute ShimmiePhoenix.Site.Favorites.user_exists?(999_999)

    assert {:error, :user_not_found} =
             ShimmiePhoenix.Site.Favorites.set(301, %{id: 999_999, class: "user"}, true)

    assert Repo.query!("SELECT COUNT(*) FROM user_favorites WHERE user_id = 999999").rows == [[0]]
  end

  test "favorites derive account identity from authentication and hide inaccessible targets", %{
    conn: conn
  } do
    Repo.query!("INSERT INTO users(id,name,class) VALUES(3,'other','user')")
    assert response(post(conn, "/favourite/add/301", %{"user_id" => "2"}), 403)

    denied =
      conn
      |> init_test_session(%{site_user_id: 2})
      |> post("/favourite/add/301", %{"user_id" => "3"})

    assert response(denied, 403)
    assert Repo.query!("SELECT COUNT(*) FROM user_favorites").rows == [[0]]

    Repo.query!(
      "ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN NOT NULL DEFAULT TRUE"
    )

    Repo.query!("INSERT INTO config(name,value) VALUES('approve_images','1')")
    Repo.query!("UPDATE images SET approved=FALSE,owner_id=3 WHERE id=301")
    hidden = conn |> init_test_session(%{site_user_id: 2}) |> post("/favourite/add/301", %{})
    assert response(hidden, 404)

    for class <- ["anonymous", "banned", "ghost"] do
      assert {:error, :permission_denied} =
               ShimmiePhoenix.Site.Favorites.set(301, %{id: 2, class: class}, true)
    end
  end
end
