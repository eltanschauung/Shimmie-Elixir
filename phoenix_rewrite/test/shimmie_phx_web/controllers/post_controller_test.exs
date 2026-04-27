defmodule ShimmiePhoenixWeb.PostControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  alias ShimmiePhoenix.SiteSchemaHelper
  alias ShimmiePhoenix.Repo

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      "ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN NOT NULL DEFAULT TRUE"
    )

    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved_by_id BIGINT")

    hash = "abaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    hash2 = "acaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["index_images", "1"])
    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["approve_images", "1"])

    Repo.query!(
      """
      INSERT INTO images(id, owner_id, owner_ip, filename, filesize, hash, ext, source, width, height, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        101,
        2,
        "74.91.116.171",
        "demo.png",
        12345,
        hash,
        "png",
        "https://example.com/src",
        640,
        480,
        ~N[2026-01-01 12:00:00]
      ]
    )

    Repo.query!(
      """
      INSERT INTO images(id, owner_id, owner_ip, filename, filesize, hash, ext, source, width, height, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        102,
        2,
        "74.91.116.171",
        "other.jpg",
        5678,
        hash2,
        "jpg",
        nil,
        300,
        200,
        ~N[2026-01-02 12:00:00]
      ]
    )

    Repo.query!("INSERT INTO tags(id, tag, count) VALUES ($1, $2, $3)", [1, "demo_tag", 1])
    Repo.query!("INSERT INTO tags(id, tag, count) VALUES ($1, $2, $3)", [2, "other_tag", 1])
    Repo.query!("INSERT INTO image_tags(image_id, tag_id) VALUES ($1, $2)", [101, 1])
    Repo.query!("INSERT INTO image_tags(image_id, tag_id) VALUES ($1, $2)", [102, 2])
    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [2, "alice", "user"])
    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [1, "admin", "admin"])

    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [
      3,
      "tag_dono",
      "Tag-Dono"
    ])

    Repo.query!(
      "INSERT INTO user_favorites(image_id, user_id, created_at) VALUES ($1, $2, NOW())",
      [101, 2]
    )

    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [901, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "hello [thumb]102[/thumb]"]
    )

    :ok
  end

  test "GET /post/view/:id renders legacy post details", %{conn: conn} do
    conn = get(conn, "/post/view/101")
    body = html_response(conn, 200)
    assert body =~ "Post 101: demo_tag"
    assert body =~ "/image/101/101%20-%20demo_tag.png"
    assert body =~ "640x480"
    assert body =~ ~s(datetime="2026-01-01T12:00:00Z")
    assert body =~ ~s(datetime="2026-01-01T13:00:00Z")
    assert body =~ "Favorited By:"
    assert body =~ "alice"
  end

  test "GET /post/view/:id hides approval controls for non-admins", %{conn: conn} do
    conn = get(conn, "/post/view/101")
    body = html_response(conn, 200)
    refute body =~ "/approve_image/101"
    refute body =~ "/disapprove_image/101"
  end

  test "GET /post/view/:id shows Approve control for admins on pending posts", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE WHERE id = 101")

    conn = conn |> init_test_session(%{site_user_id: 1}) |> get("/post/view/101")
    body = html_response(conn, 200)
    assert body =~ "/approve_image/101"
    assert body =~ "Approve"
  end

  test "GET /post/view/:id shows Disapprove control for admins on approved posts", %{conn: conn} do
    conn = conn |> init_test_session(%{site_user_id: 1}) |> get("/post/view/102")
    body = html_response(conn, 200)
    assert body =~ "/disapprove_image/102"
    assert body =~ "Disapprove"
  end

  test "GET /post/view/:id shows comment IP and delete control for admin", %{conn: conn} do
    conn = conn |> init_test_session(%{site_user_id: 1}) |> get("/post/view/101")
    body = html_response(conn, 200)
    assert body =~ "Uploader:"
    assert body =~ "74.91.116.171"
    assert body =~ "c_ip=74.91.116.171"
    assert body =~ "c_reason=Post+posted"
    assert body =~ "/comment/delete/901/101"
    assert body =~ "c_ip=127.0.0.1"
  end

  test "GET /post/view/:id renders [thumb] bbcode comment embeds", %{conn: conn} do
    body = conn |> get("/post/view/101") |> html_response(200)
    assert body =~ "class=\"bb-thumb\""
    assert body =~ "href=\"/post/view/102\""
    assert body =~ "src=\"/thumb/102/thumb\""
  end

  test "GET /post/view/:id shows comment delete but not IP for Tag-Dono", %{conn: conn} do
    conn = conn |> init_test_session(%{site_user_id: 3}) |> get("/post/view/101")
    body = html_response(conn, 200)
    refute body =~ "(74.91.116.171,"
    refute body =~ "c_reason=Post+posted"
    refute body =~ "IP: 127.0.0.1"
    assert body =~ "/comment/delete/901/101"
    refute body =~ "c_ip=127.0.0.1"
  end

  test "POST /approve_image/:id approves pending posts for admins", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE, approved_by_id = NULL WHERE id = 101")

    conn =
      conn
      |> init_test_session(%{site_user_id: 1})
      |> post("/approve_image/101", %{"image_id" => "101"})

    assert redirected_to(conn) == "/post/view/101"

    [[approved, approved_by_id]] =
      Repo.query!("SELECT approved, approved_by_id FROM images WHERE id = 101").rows

    assert approved in [true, 1]
    assert approved_by_id == 1
  end

  test "POST /disapprove_image/:id disapproves approved posts for admins", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{site_user_id: 1})
      |> post("/disapprove_image/102", %{"image_id" => "102"})

    assert redirected_to(conn) == "/post/view/102"

    [[approved, approved_by_id]] =
      Repo.query!("SELECT approved, approved_by_id FROM images WHERE id = 102").rows

    assert approved in [false, 0]
    assert is_nil(approved_by_id)
  end

  test "POST /approve_image/:id returns 403 for non-admin users", %{conn: conn} do
    conn = post(conn, "/approve_image/101", %{"image_id" => "101"})
    assert response(conn, 403) =~ "Permission Denied"
  end

  test "GET /post/view/:id shows Approve control for Tag-Dono on pending posts", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE WHERE id = 101")

    conn = conn |> init_test_session(%{site_user_id: 3}) |> get("/post/view/101")
    body = html_response(conn, 200)
    assert body =~ "/approve_image/101"
    assert body =~ "Approve"
  end

  test "POST /approve_image/:id approves pending posts for Tag-Dono", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE, approved_by_id = NULL WHERE id = 101")

    conn =
      conn
      |> init_test_session(%{site_user_id: 3})
      |> post("/approve_image/101", %{"image_id" => "101"})

    assert redirected_to(conn) == "/post/view/101"

    [[approved, approved_by_id]] =
      Repo.query!("SELECT approved, approved_by_id FROM images WHERE id = 101").rows

    assert approved in [true, 1]
    assert approved_by_id == 3
  end

  test "GET /post/list/approved=no/1 shows pending posts for Tag-Dono", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE WHERE id = 101")

    conn = conn |> init_test_session(%{site_user_id: 3}) |> get("/post/list/approved=no/1")
    assert redirected_to(conn, 302) == "/post/view/101"
  end

  test "GET /post/view/:id returns 404 for invalid id", %{conn: conn} do
    conn = get(conn, "/post/view/not-a-number")
    assert response(conn, 404)
  end

  test "GET /post/list renders index page", %{conn: conn} do
    conn = get(conn, "/post/list")
    body = html_response(conn, 200)
    assert body =~ "shm-image-list"
    assert body =~ "/post/view/102"
    refute body =~ "/post/view/101"
  end

  test "GET /post/list/:page paginates results", %{conn: conn} do
    conn = get(conn, "/post/list/2")
    body = html_response(conn, 200)
    assert body =~ "/post/view/101"
    refute body =~ "/post/view/102"
  end

  test "GET /post/list/:search/:page redirects when one result matches", %{conn: conn} do
    conn = get(conn, "/post/list/demo_tag/1")
    assert redirected_to(conn, 302) == "/post/view/101"
  end

  test "GET /post/list/:search/:page matches mixed-case tags case-insensitively", %{conn: conn} do
    Repo.query!("UPDATE tags SET tag = $1 WHERE id = $2", ["Peter_Griffin", 1])

    conn = get(conn, "/post/list/Peter_Griffin/1")
    assert redirected_to(conn, 302) == "/post/view/101"

    conn = Phoenix.ConnTest.build_conn() |> get("/post/list/peter_griffin/1")
    assert redirected_to(conn, 302) == "/post/view/101"
  end

  test "GET /post/list with query search redirects to canonical path", %{conn: conn} do
    conn = get(conn, "/post/list", %{"search" => "demo_tag"})
    assert redirected_to(conn, 302) == "/post/list/demo_tag/1"
  end
end
