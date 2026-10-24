defmodule ShimmiePhoenix.SessionSecurityTest do
  use ShimmiePhoenixWeb.ConnCase, async: false
  alias ShimmiePhoenix.{Repo, SiteSchemaHelper}
  alias ShimmiePhoenix.Site.Users
  alias ShimmiePhoenixWeb.Endpoint

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    hash = Bcrypt.hash_pwd_salt("test-account-password")
    Repo.query!("INSERT INTO users(id,name,pass,class) VALUES(2,'account',$1,'user')", [hash])
    %{user: Users.get_user_by_id(2)}
  end

  test "logout GET is non-mutating and POST requires a real CSRF token", %{conn: conn} do
    confirmation = conn |> sign_in(2) |> get("/user_admin/logout")
    body = html_response(confirmation, 200)
    assert Users.current_user(confirmation).id == 2
    refute confirmation.private[:plug_session_info] == :drop

    for params <- [%{}, %{"_csrf_token" => "invalid"}] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> sign_in(2)
        |> put_private(:plug_skip_csrf_protection, false)
        |> post("/user_admin/logout", params)
      end
    end

    token =
      body
      |> Floki.parse_document!()
      |> Floki.find("form[action='/user_admin/logout'] input[name='_csrf_token']")
      |> Floki.attribute("value")
      |> List.last()

    result =
      confirmation
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/user_admin/logout", %{"_csrf_token" => token})

    assert redirected_to(result) == "/post/list"
    assert result.private[:plug_session_info] == :drop
  end

  test "bare pre-upgrade signed account IDs are not authentication", %{conn: conn} do
    assert Users.current_user(init_test_session(conn, %{site_user_id: 2})) == nil
    assert Users.session_user_id(init_test_session(conn, %{legacy_user_id: 2})) == nil
  end

  test "password change revokes both signed sessions and legacy proofs", %{conn: conn, user: user} do
    signed = sign_in(conn, 2)
    token = Users.session_id(user, "127.0.0.1")

    cookie =
      init_test_session(conn, %{})
      |> put_req_header("cookie", "shm_user=account; shm_session=" <> token)

    assert Users.current_user(signed).id == 2
    assert Users.current_user(cookie).id == 2

    assert {:ok, new_user, new_token} =
             Users.change_pass(
               user,
               %{
                 "id" => "2",
                 "pass1" => "new-test-account-password",
                 "pass2" => "new-test-account-password"
               },
               "127.0.0.1"
             )

    assert Users.current_user(signed) == nil
    assert Users.current_user(cookie) == nil

    assert Users.current_user(Users.put_user_session(init_test_session(conn, %{}), new_user)).id ==
             2

    renewed =
      init_test_session(conn, %{})
      |> put_req_header("cookie", "shm_user=account; shm_session=" <> new_token)

    assert Users.current_user(renewed).id == 2
  end

  test "proofs expire server-side and cannot be moved between accounts", %{conn: conn} do
    authenticated = sign_in(conn, 2)
    proof = get_session(authenticated, :site_session_proof_v2)
    {:ok, payload} = Phoenix.Token.verify(Endpoint, "account-session-v2", proof, max_age: 60)

    expired =
      Phoenix.Token.sign(Endpoint, "account-session-v2", payload,
        signed_at: System.system_time(:second) - 366 * 86_400
      )

    assert Users.current_user(
             init_test_session(conn, %{site_user_id: 2, site_session_proof_v2: expired})
           ) == nil

    Repo.query!(
      "INSERT INTO users(id,name,pass,class) SELECT 3,'other',pass,'user' FROM users WHERE id=2"
    )

    assert Users.current_user(
             init_test_session(conn, %{site_user_id: 3, site_session_proof_v2: proof})
           ) == nil

    legacy =
      Phoenix.Token.sign(Endpoint, "legacy-session-v2", Map.put(payload, :subnet, "127.0.0.0"),
        signed_at: System.system_time(:second) - 366 * 86_400
      )

    expired_cookie =
      init_test_session(conn, %{})
      |> put_req_header("cookie", "shm_user=account; shm_session=v2." <> legacy)

    assert Users.current_user(expired_cookie) == nil

    old_cookie =
      init_test_session(conn, %{})
      |> put_req_header("cookie", "shm_user=account; shm_session=unversioned-old-token")

    assert Users.current_user(old_cookie) == nil
  end
end
