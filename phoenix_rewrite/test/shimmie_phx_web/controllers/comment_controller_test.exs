defmodule ShimmiePhoenixWeb.CommentControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  alias ShimmiePhoenix.Site.Comments
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
    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [3, "admin", "admin"])

    Repo.query!("INSERT INTO users(id, name, class) VALUES ($1, $2, $3)", [
      4,
      "tag_dono",
      "Tag-Dono"
    ])

    Repo.query!(
      """
      INSERT INTO images(id, filename, filesize, hash, ext, source, width, height, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        101,
        "demo.png",
        12345,
        "abaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "png",
        nil,
        640,
        480,
        ~N[2026-01-01 12:00:00]
      ]
    )

    :ok
  end

  test "POST /comment/add creates comment for logged-in user", %{conn: conn} do
    conn =
      conn
      |> sign_in(2)
      |> post("/comment/add", %{
        "image_id" => "101",
        "comment" => "test comment",
        "hash" => Comments.form_hash("127.0.0.1")
      })

    assert redirected_to(conn) == "/post/view/101#comment_on_101"

    assert Repo.query!(
             "SELECT image_id, owner_id, comment FROM comments ORDER BY id DESC LIMIT 1"
           ).rows == [[101, 2, "test comment"]]
  end

  test "POST /comment/add creates anonymous comment with valid form hash", %{conn: conn} do
    valid_hash = Comments.form_hash("127.0.0.1")

    conn =
      post(conn, "/comment/add", %{
        "image_id" => "101",
        "comment" => "anon comment",
        "hash" => valid_hash
      })

    assert redirected_to(conn) == "/post/view/101#comment_on_101"

    assert Repo.query!("SELECT owner_id, comment FROM comments ORDER BY id DESC LIMIT 1").rows ==
             [[1, "anon comment"]]
  end

  test "comment create permission is enforced on direct submissions", %{conn: conn} do
    assert :ok = ShimmiePhoenix.Site.Store.put_config("perm_comment_create", "admin")

    for actor <- [nil, %{id: 2, class: "user"}, %{id: 0, class: "admin"}] do
      assert {:error, :permission_denied} =
               Comments.add(
                 %{
                   "image_id" => "101",
                   "comment" => "not allowed",
                   "hash" => Comments.form_hash("127.0.0.1")
                 },
                 actor,
                 "127.0.0.1"
               )
    end

    conn =
      conn
      |> sign_in(2)
      |> post("/comment/add", %{
        "image_id" => "101",
        "comment" => "not allowed",
        "hash" => Comments.form_hash("127.0.0.1")
      })

    assert response(conn, 403) == "Comment Blocked"
    assert Repo.query!("SELECT COUNT(*) FROM comments").rows == [[0]]
  end

  test "anonymous UI permission matches the configurable create capability" do
    assert Comments.can_create_comment?(nil)
    refute Comments.can_create_comment?(%{id: 0, class: "admin"})
    assert :ok = ShimmiePhoenix.Site.Store.put_config("perm_comment_create", "admin")
    refute Comments.can_create_comment?(nil)
    assert Comments.can_create_comment?(%{id: 3, class: "admin"})
  end

  test "comments cannot be submitted to another user's unapproved post" do
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN")
    Repo.query!("INSERT INTO users(id, name, class) VALUES (5, 'owner', 'user')")
    Repo.query!("UPDATE images SET approved = FALSE, owner_id = 5 WHERE id = 101")

    params = %{
      "image_id" => "101",
      "comment" => "private comment",
      "hash" => Comments.form_hash("127.0.0.1")
    }

    for actor <- [nil, %{id: 2, class: "user"}] do
      assert {:error, :post_not_found} = Comments.add(params, actor, "127.0.0.1")
    end

    assert {:ok, 101} = Comments.add(params, %{id: 5, class: "user"}, "127.0.0.1")
  end

  test "POST /comment/add rejects empty comment", %{conn: conn} do
    conn =
      conn
      |> sign_in(2)
      |> post("/comment/add", %{"image_id" => "101", "comment" => " \n\t"})

    assert redirected_to(conn) ==
             "/post/view/101?error=#{URI.encode_www_form("Comments need text...")}#comment_on_101"

    assert Repo.query!("SELECT COUNT(*) FROM comments").rows == [[0]]
  end

  test "POST /comment/add rejects anonymous request with invalid hash", %{conn: conn} do
    conn =
      post(conn, "/comment/add", %{
        "image_id" => "101",
        "comment" => "anon comment",
        "hash" => "bad-hash"
      })

    assert redirected_to(conn) ==
             "/post/view/101?error=#{URI.encode_www_form("Comment submission form is out of date; refresh and try again~")}#comment_on_101"

    assert Repo.query!("SELECT COUNT(*) FROM comments").rows == [[0]]
  end

  test "GET confirms without deleting and POST with CSRF deletes for admin", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [501, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "delete me"]
    )

    conn =
      conn
      |> sign_in(3)
      |> put_private(:plug_skip_csrf_protection, false)
      |> get("/comment/delete/501/999")

    body = html_response(conn, 200)
    assert body =~ ~s(action="/comment/delete/501/101" method="POST")
    assert body =~ ~s(href="/post/view/101")
    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 501").rows == [[1]]
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body)

    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/comment/delete/501/999", %{"_csrf_token" => token})

    assert redirected_to(conn) == "/post/view/101"

    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 501").rows == [[0]]
  end

  test "POST /comment/delete/:comment_id/:image_id deletes comment for Tag-Dono", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [502, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "delete me too"]
    )

    conn =
      conn
      |> sign_in(4)
      |> post("/comment/delete/502/101")

    assert redirected_to(conn) == "/post/view/101"

    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 502").rows == [[0]]
  end

  test "GET /comment/delete/:comment_id/:image_id denies regular users", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [503, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "no delete"]
    )

    conn =
      conn
      |> sign_in(2)
      |> get("/comment/delete/503/101")

    assert response(conn, 403) =~ "Permission Denied"
    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 503").rows == [[1]]

    conn =
      build_conn() |> sign_in(2) |> post("/comment/delete/503/101")

    assert response(conn, 403) == "Permission Denied"
    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 503").rows == [[1]]
  end

  test "comment deletion rejects missing and invalid CSRF tokens", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, comment) VALUES (504, 101, 2, 'keep me')"
    )

    for params <- [%{}, %{"_csrf_token" => "invalid"}] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> sign_in(3)
        |> put_private(:plug_skip_csrf_protection, false)
        |> post("/comment/delete/504/101", params)
      end

      assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 504").rows == [[1]]
    end
  end

  test "confirmation rejects invalid and missing comments", %{conn: conn} do
    conn = sign_in(conn, 3)
    assert response(get(conn, "/comment/delete/not-an-id/101"), 400) == "Bad Request"
    assert response(get(conn, "/comment/delete/999/101"), 404) == "Not Found"
  end
end
