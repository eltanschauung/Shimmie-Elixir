defmodule ShimmiePhoenix.BootstrapTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.{Repo, Bootstrap, PasswordPolicy, SiteSchemaHelper}

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    :ok
  end

  test "missing or weak bootstrap secrets never create an administrator" do
    for password <- [nil, "", "short", String.duplicate("a", 73)] do
      assert_raise RuntimeError, ~r/SHIMMIE_BOOTSTRAP_ADMIN_PASSWORD/, fn ->
        Bootstrap.ensure_admin!(Repo, password: password)
      end
    end

    assert Repo.query!("SELECT COUNT(*) FROM users").rows == [[0]]
  end

  test "explicit setup hashes its secret and cannot reset or promote an existing account" do
    password = "synthetic-bootstrap-secret"
    id = Bootstrap.ensure_admin!(Repo, password: password, name: "operator")
    [[hash]] = Repo.query!("SELECT pass FROM users WHERE id=$1", [id]).rows
    assert Bcrypt.verify_pass(password, hash)
    assert Bootstrap.ensure_admin!(Repo, password: nil) == :existing
    assert Repo.query!("SELECT pass FROM users WHERE id=$1", [id]).rows == [[hash]]
  end

  test "a colliding ordinary account is never promoted or overwritten" do
    Repo.query!("INSERT INTO users(id,name,pass,class) VALUES(5,'admin','unchanged','user')")

    assert_raise RuntimeError, ~r/already exists/, fn ->
      Bootstrap.ensure_admin!(Repo, password: "synthetic-bootstrap-secret")
    end

    assert Repo.query!("SELECT class,pass FROM users WHERE id=5").rows == [["user", "unchanged"]]
  end

  test "password bounds respect bcrypt's UTF-8 byte boundary" do
    assert PasswordPolicy.validate("one", "one") == {:error, :invalid_password}
    assert PasswordPolicy.validate(String.duplicate("a", 72), String.duplicate("a", 72)) == :ok

    assert PasswordPolicy.validate(String.duplicate("界", 25), String.duplicate("界", 25)) ==
             {:error, :invalid_password}
  end
end
