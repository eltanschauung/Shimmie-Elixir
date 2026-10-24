defmodule ShimmiePhoenixWeb.PostAdminControllerTest do
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
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS notes INTEGER NOT NULL DEFAULT 0")

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS note_request (id BIGSERIAL PRIMARY KEY, image_id BIGINT NOT NULL, user_id BIGINT NOT NULL, date TIMESTAMP NOT NULL DEFAULT NOW())"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS notes (id BIGSERIAL PRIMARY KEY, image_id BIGINT NOT NULL, note TEXT)"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS note_histories (id BIGSERIAL PRIMARY KEY, image_id BIGINT NOT NULL)"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS source_histories (id BIGSERIAL PRIMARY KEY, image_id BIGINT NOT NULL)"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS tag_histories (id BIGSERIAL PRIMARY KEY, image_id BIGINT NOT NULL)"
    )

    hash = "bbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["approve_images", "1"])
    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["featured_id", "0"])
    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [1, "admin", "admin"])
    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [2, "alice", "user"])

    Repo.query!(
      """
      INSERT INTO images(id, filename, filesize, hash, ext, source, width, height, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        501,
        "admin.png",
        4321,
        hash,
        "png",
        "https://example.com/src",
        640,
        480,
        ~N[2026-01-03 12:00:00]
      ]
    )

    Repo.query!(
      "INSERT INTO user_favorites(image_id, user_id, created_at) VALUES ($1, $2, NOW())",
      [
        501,
        2
      ]
    )

    :ok
  end

  test "notes and requests cannot mutate another account's invisible post", %{conn: conn} do
    Repo.query!("UPDATE images SET approved = FALSE, owner_id = 1 WHERE id = 501")
    actor = %{id: 2, class: "user"}

    attrs = %{
      "note_x1" => "0",
      "note_y1" => "0",
      "note_width" => "2",
      "note_height" => "2",
      "note_text" => "text"
    }

    assert {:error, :post_not_found} = ShimmiePhoenix.Site.PostAdmin.add_note(501, actor, attrs)

    assert {:error, :post_not_found} =
             ShimmiePhoenix.Site.PostAdmin.edit_note(501, 1, actor, attrs)

    assert {:error, :post_not_found} = ShimmiePhoenix.Site.PostAdmin.add_note_request(501, actor)

    for class <- ["banned", "ghost", "anonymous"] do
      assert {:error, :permission_denied} =
               ShimmiePhoenix.Site.PostAdmin.add_note_request(501, %{id: 2, class: class})
    end

    for route <- ["/note/add_note", "/note/add_request", "/note/edit_note"] do
      result =
        conn
        |> sign_in(2)
        |> post(route, Map.merge(attrs, %{"image_id" => "501", "note_id" => "1"}))

      assert response(result, 404) == "Not Found"
    end

    assert Repo.query!("SELECT COUNT(*) FROM note_request WHERE image_id = 501").rows == [[0]]
    assert :ok = ShimmiePhoenix.Site.PostAdmin.add_note_request(501, %{id: 1, class: "admin"})
    Repo.query!("UPDATE images SET owner_id = 2 WHERE id = 501")
    assert :ok = ShimmiePhoenix.Site.PostAdmin.add_note_request(501, actor)
  end

  test "admin post/view includes full post controls parity block", %{conn: conn} do
    conn = conn |> sign_in(1) |> get("/post/view/501")
    body = html_response(conn, 200)

    assert body =~ "Feature This"
    assert body =~ "Regenerate Thumbnail"
    assert body =~ "/image/delete"
    assert body =~ "/image/replace"
    assert body =~ "Nuke Notes"
    assert body =~ "Nuke Requests"
    assert body =~ "/favourite/add/501"
    assert body =~ "Add Note Request"
  end

  test "non-admin post/view hides admin-only controls", %{conn: conn} do
    conn = conn |> sign_in(2) |> get("/post/view/501")
    body = html_response(conn, 200)

    refute body =~ "Feature This"
    refute body =~ "Regenerate Thumbnail"
    refute body =~ "/image/delete"
    refute body =~ "/image/replace"
    refute body =~ "Nuke Notes"
    refute body =~ "Nuke Requests"
  end

  test "POST /featured_image/set updates featured_id for admins", %{conn: conn} do
    conn =
      conn
      |> sign_in(1)
      |> post("/featured_image/set", %{"image_id" => "501"})

    assert redirected_to(conn) == "/post/view/501"
    assert Repo.query!("SELECT value FROM config WHERE name = 'featured_id'").rows == [["501"]]
  end

  test "POST /image/delete deletes image for admins", %{conn: conn} do
    conn =
      conn
      |> sign_in(1)
      |> post("/image/delete", %{"image_id" => "501"})

    assert redirected_to(conn) == "/post/list"
    assert Repo.query!("SELECT COUNT(*) FROM images WHERE id = 501").rows == [[0]]
  end

  test "POST /note/nuke_requests returns 403 for non-admins", %{conn: conn} do
    conn =
      conn
      |> sign_in(2)
      |> post("/note/nuke_requests", %{"image_id" => "501"})

    assert response(conn, 403) =~ "Permission Denied"
  end
end
