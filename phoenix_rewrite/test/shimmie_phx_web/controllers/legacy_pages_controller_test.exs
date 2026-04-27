defmodule ShimmiePhoenixWeb.LegacyPagesControllerTest do
  use ShimmiePhoenixWeb.ConnCase, async: false

  alias ShimmiePhoenix.SiteSchemaHelper
  alias ShimmiePhoenix.Repo

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      """
      INSERT INTO images(id, filename, filesize, hash, ext, source, width, height, posted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        200,
        "demo.png",
        100,
        "bbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "png",
        nil,
        640,
        480,
        ~N[2026-01-01 00:00:00]
      ]
    )

    Repo.query!(
      "INSERT INTO users(id, name, pass, email, joindate, class) VALUES ($1, $2, $3, $4, $5, $6)",
      [
        20,
        "tester",
        Bcrypt.hash_pwd_salt("secret"),
        "tester@example.com",
        ~N[2026-01-01 00:00:00],
        "user"
      ]
    )

    Repo.query!(
      "INSERT INTO users(id, name, pass, email, joindate, class) VALUES ($1, $2, $3, $4, $5, $6)",
      [
        30,
        "admin_user",
        Bcrypt.hash_pwd_salt("admin_secret"),
        "admin@example.com",
        ~N[2026-01-01 00:00:00],
        "admin"
      ]
    )

    Repo.query!("INSERT INTO tags(id, tag, count) VALUES ($1, $2, $3)", [1, "demo_tag", 3])

    Repo.query!(
      "INSERT INTO comments(id, image_id, owner_id, owner_ip, posted, comment) VALUES ($1, $2, $3, $4, $5, $6)",
      [1, 200, 20, "127.0.0.1", ~N[2026-01-01 01:00:00], "hello [thumb]200[/thumb]"]
    )

    Repo.query!(
      "INSERT INTO blotter(id, entry_date, entry_text, important) VALUES ($1, $2, $3, $4)",
      [1, ~N[2026-01-02 00:00:00], "hello blotter", true]
    )

    Repo.query!(
      "INSERT INTO wiki_pages(id, owner_id, owner_ip, date, title, revision, locked, body) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      [1, 20, "127.0.0.1", ~N[2026-01-03 00:00:00], "Index", 1, false, "welcome wiki"]
    )

    :ok
  end

  test "core legacy navigation routes are online", %{conn: conn} do
    assert html_response(get(conn, "/comment/list"), 200) =~ "Comments"
    assert html_response(get(conn, "/upload"), 200) =~ "Upload"
    assert redirected_to(get(conn, "/tags"), 302) == "/tags/map"
    assert html_response(get(conn, "/tags/map"), 200) =~ "demo tag"
    assert redirected_to(get(conn, "/help"), 302) == "/help/search"
    assert html_response(get(conn, "/help/search"), 200) =~ "General"
    assert html_response(get(conn, "/help/licenses"), 200) =~ "Software Licenses"
    assert response(get(conn, "/help/does-not-exist"), 404) =~ "Not Found"
    assert redirected_to(get(conn, "/system"), 302) == "/ext_doc"
    assert html_response(get(conn, "/ext_doc"), 200) =~ "Board Help"
    assert html_response(get(conn, "/ext_manager"), 200) =~ "Board Help"
    assert html_response(get(conn, "/ext_doc/comment"), 200) =~ "Comments Help"
    assert html_response(get(conn, "/cron_upload"), 200) =~ "Cron Upload"
    assert response(get(conn, "/setup"), 403) =~ "Permission Denied"
    assert response(get(conn, "/admin"), 403) =~ "Permission Denied"
    assert response(get(conn, "/blotter/editor"), 403) =~ "Permission Denied"
    assert response(get(conn, "/system_info"), 403) =~ "Permission Denied"
    assert response(get(conn, "/ip_ban/list"), 403) =~ "Permission Denied"
    assert response(get(conn, "/source_history/all/1"), 403) =~ "Permission Denied"
    assert response(get(conn, "/tag_history/all/1"), 403) =~ "Permission Denied"
    assert redirected_to(get(conn, "/wiki"), 302) == "/wiki/Index"
    assert html_response(get(conn, "/wiki/Index"), 200) =~ "welcome wiki"
    assert html_response(get(conn, "/blotter/list"), 200) =~ "hello blotter"
    assert html_response(get(conn, "/user_admin/login"), 200) =~ "Login"
  end

  test "comment list shows moderation controls for admin only", %{conn: conn} do
    admin_body =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> get("/comment/list")
      |> html_response(200)

    assert admin_body =~ "c_ip=127.0.0.1"
    assert admin_body =~ ~s(datetime="2026-01-01T01:00:00Z")
    assert admin_body =~ "/comment/delete/1/200"
    assert admin_body =~ "c_ip=127.0.0.1"

    user_body =
      conn
      |> init_test_session(%{site_user_id: 20})
      |> get("/comment/list")
      |> html_response(200)

    refute user_body =~ "c_ip=127.0.0.1"
    refute user_body =~ "/comment/delete/1/200"
    refute user_body =~ "c_ip=127.0.0.1"
  end

  test "admin can create and delete IP bans from /ip_ban routes", %{conn: conn} do
    create_conn =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> post("/ip_ban/create", %{
        "c_ip" => "74.91.116.171",
        "c_mode" => "block",
        "c_reason" => "test ban",
        "c_expires" => "+1 week"
      })

    assert redirected_to(create_conn, 302) =~ "/ip_ban/list?notice="

    [[ban_id, ip, mode, reason]] =
      Repo.query!(
        "SELECT id, ip, mode, reason FROM bans WHERE ip = '74.91.116.171' ORDER BY id DESC LIMIT 1"
      ).rows

    assert ip == "74.91.116.171"
    assert mode == "block"
    assert reason == "test ban"

    delete_conn =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> post("/ip_ban/delete", %{"d_id" => to_string(ban_id)})

    assert redirected_to(delete_conn, 302) =~ "/ip_ban/list?notice="
    assert Repo.query!("SELECT COUNT(*) FROM bans WHERE id = $1", [ban_id]).rows == [[0]]
  end

  test "ip ban list supports paged browsing with legacy params", %{conn: conn} do
    actor = %{id: 30, class: "admin"}

    for n <- 1..3 do
      assert {:ok, _} =
               ShimmiePhoenix.Site.IPBans.create(
                 %{
                   "c_ip" => "10.0.0.#{n}",
                   "c_mode" => "block",
                   "c_reason" => "page test #{n}",
                   "c_expires" => ""
                 },
                 actor
               )
    end

    page_1_html =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> get("/ip_ban/list?r_all=on&r__size=2&r__page=1")
      |> html_response(200)

    assert page_1_html =~ "10.0.0.3"
    assert page_1_html =~ "10.0.0.2"
    refute page_1_html =~ "10.0.0.1"
    assert page_1_html =~ "r__page=2"

    page_2_html =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> get("/ip_ban/list?r_all=on&r__size=2&r__page=2")
      |> html_response(200)

    assert page_2_html =~ "10.0.0.1"
    assert page_2_html =~ "r__page=1"
  end

  test "block-mode IP bans return 403 with configured message", %{conn: conn} do
    assert {:ok, _ip} =
             ShimmiePhoenix.Site.IPBans.create(
               %{
                 "c_ip" => "0.0.0.0/0",
                 "c_mode" => "block",
                 "c_reason" => "test reason",
                 "c_expires" => ""
               },
               %{id: 30, class: "admin"}
             )

    body = response(get(conn, "/post/list"), 403)

    assert body =~ "test reason"
    assert body =~ "0.0.0.0/0"
  end

  test "ghost-mode IP bans allow request and render notice block", %{conn: conn} do
    assert {:ok, _ip} =
             ShimmiePhoenix.Site.IPBans.create(
               %{
                 "c_ip" => "0.0.0.0/0",
                 "c_mode" => "ghost",
                 "c_reason" => "ghost reason",
                 "c_expires" => ""
               },
               %{id: 30, class: "admin"}
             )

    body = html_response(get(conn, "/post/list"), 200)

    assert body =~ "Notice"
    assert body =~ "ghost reason"
    assert body =~ "/ ghost -->"
  end

  test "comment list renders inline comment postbox for admin", %{conn: conn} do
    body =
      conn
      |> init_test_session(%{site_user_id: 30})
      |> get("/comment/list")
      |> html_response(200)

    assert body =~ ~s(form action="/comment/add" method="POST")
    assert body =~ ~s(name="image_id" value="200")
    assert body =~ ~s(id="comment_on_200")
    assert body =~ "Post Comment"
  end

  test "comment list renders [thumb] bbcode embeds", %{conn: conn} do
    body = get(conn, "/comment/list") |> html_response(200)
    assert body =~ "class=\"bb-thumb\""
    assert body =~ "href=\"/post/view/200\""
    assert body =~ "src=\"/thumb/200/thumb\""
  end

  test "comment list falls back to add-comment link for anonymous when captcha is enabled", %{
    conn: conn
  } do
    Repo.query!(
      "INSERT INTO config(name, value) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value",
      ["comment_captcha", "Y"]
    )

    body =
      conn
      |> get("/comment/list")
      |> html_response(200)

    refute body =~ ~s(form action="/comment/add" method="POST")
    assert body =~ ~s(href="/post/view/200")
    assert body =~ "Add Comment"
  end

  test "system section switches to admin routes for logged in admin", %{conn: conn} do
    conn = init_test_session(conn, %{site_user_id: 30})

    assert redirected_to(get(conn, "/system"), 302) == "/setup"
    assert html_response(get(conn, "/setup"), 200) =~ "Board Config"
    assert html_response(get(conn, "/ext_manager"), 200) =~ "Extension Manager"
    assert html_response(get(conn, "/admin"), 200) =~ "Admin Tools"
    assert html_response(get(conn, "/blotter/editor"), 200) =~ "Blotter Editor"
    assert html_response(get(conn, "/system_info"), 200) =~ "System Info"
    user_list_html = html_response(get(conn, "/user_admin/list"), 200)
    assert user_list_html =~ "User List"
    assert user_list_html =~ "admin@example.com"
    assert user_list_html =~ "Board Config"
    assert html_response(get(conn, "/ip_ban/list"), 200) =~ "IP Bans"
    assert html_response(get(conn, "/source_history/all/1"), 200) =~ "Global Source History"
    assert html_response(get(conn, "/tag_history/all/1"), 200) =~ "Global Tag History"

    system_html = html_response(get(conn, "/setup"), 200)
    assert system_html =~ "User List"
    assert system_html =~ "Comment Options"
    assert system_html =~ "Comment_Options-setup"
    assert system_html =~ "IP Bans"
    assert system_html =~ "Source Changes"
    assert system_html =~ "Tag Changes"
  end

  test "user admin route surface is online", %{conn: conn} do
    assert redirected_to(get(conn, "/user_admin"), 302) == "/user_admin/login"
    assert html_response(get(conn, "/user_admin/create"), 200) =~ "Signup"
    assert response(get(conn, "/user_admin/list"), 403) =~ "Permission Denied"
    assert redirected_to(get(conn, "/user_admin/logout"), 302) == "/post/list"
  end

  test "account subnavbar shows logged-in account links and no duplicate logout button", %{
    conn: conn
  } do
    body =
      conn
      |> init_test_session(%{site_user_id: 20})
      |> get("/user")
      |> html_response(200)

    assert body =~ "/user_config"
    assert body =~ "/post/list/favorited_by=tester/1"
    assert body =~ "/user#private-messages"
    assert body =~ "/user_admin/logout"
    refute body =~ ~s(form action="/user_admin/logout" method="GET")
  end

  test "/user_config route resolves to the account page for logged in user", %{conn: conn} do
    body =
      conn
      |> init_test_session(%{site_user_id: 20})
      |> get("/user_config")
      |> html_response(200)

    assert body =~ "tester&#39;s Page"
    assert body =~ "Log Out"
  end

  test "self password change redirects back to account page", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{site_user_id: 20})
      |> post("/user_admin/change_pass", %{
        "user_id" => "20",
        "pass1" => "new_secret",
        "pass2" => "new_secret"
      })

    assert redirected_to(conn, 302) == "/user?notice=Password+changed"

    assert {:ok, _user, _token} =
             ShimmiePhoenix.Site.Users.login("tester", "new_secret", "127.0.0.1")
  end

  test "user admin login post accepts valid credentials", %{conn: conn} do
    conn = post(conn, "/user_admin/login", %{"user" => "tester", "pass" => "secret"})
    assert redirected_to(conn, 302) == "/post/list"
  end

  test "user admin login post rejects invalid credentials", %{conn: conn} do
    conn = post(conn, "/user_admin/login", %{"user" => "tester", "pass" => "wrong"})
    assert redirected_to(conn, 302) =~ "/user_admin/login?error="
  end

  test "user admin create post creates a user", %{conn: conn} do
    conn =
      post(conn, "/user_admin/create", %{
        "name" => "new_user",
        "pass1" => "abc123",
        "pass2" => "abc123",
        "email" => "new_user@example.com"
      })

    assert redirected_to(conn, 302) == "/post/list"

    rows = Repo.query!("SELECT name FROM users WHERE name = 'new_user'").rows
    assert rows == [["new_user"]]
  end

  test "search API compatibility routes are online", %{conn: conn} do
    xml = response(get(conn, "/browser_search.xml"), 200)
    assert xml =~ "SearchPlugin"

    json = json_response(get(conn, "/browser_search/demo"), 200)
    assert Enum.at(json, 0) == "demo"

    autocomplete = json_response(get(conn, "/api/internal/autocomplete?s=demo"), 200)
    assert is_map(autocomplete)
  end

  test "random routes render random list page and random image redirect stays online", %{
    conn: conn
  } do
    body = html_response(get(conn, "/random"), 200)
    assert body =~ "Random Posts"
    assert body =~ "Refresh the page to view more posts"
    assert redirected_to(get(conn, "/random_image/view"), 302) == "/post/view/200"
  end

  test "fallback keeps unknown legacy path online", %{conn: conn} do
    body = html_response(get(conn, "/note/list"), 200)
    assert body =~ "Legacy Route Placeholder"
  end
end
