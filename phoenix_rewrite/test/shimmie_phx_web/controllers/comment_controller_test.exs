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
      |> init_test_session(%{site_user_id: 2})
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
      |> init_test_session(%{site_user_id: 2})
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

  test "POST /comment/add rejects empty comment", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{site_user_id: 2})
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

  test "GET /comment/delete/:comment_id/:image_id deletes comment for admin", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [501, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "delete me"]
    )

    conn =
      conn
      |> init_test_session(%{site_user_id: 3})
      |> get("/comment/delete/501/101")

    assert redirected_to(conn) == "/post/view/101"

    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 501").rows == [[0]]
  end

  test "GET /comment/delete/:comment_id/:image_id deletes comment for Tag-Dono", %{conn: conn} do
    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [502, 101, 2, "127.0.0.1", ~N[2026-01-01 13:00:00], "delete me too"]
    )

    conn =
      conn
      |> init_test_session(%{site_user_id: 4})
      |> get("/comment/delete/502/101")

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
      |> init_test_session(%{site_user_id: 2})
      |> get("/comment/delete/503/101")

    assert response(conn, 403) =~ "Permission Denied"
    assert Repo.query!("SELECT COUNT(*) FROM comments WHERE id = 503").rows == [[1]]
  end
end
