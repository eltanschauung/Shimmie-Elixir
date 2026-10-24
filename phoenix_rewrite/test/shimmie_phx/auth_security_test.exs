defmodule ShimmiePhoenix.AuthSecurityTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.Site.Users

  setup do
    ShimmiePhoenix.SiteSchemaHelper.ensure_legacy_tables!()
    ShimmiePhoenix.SiteSchemaHelper.reset_legacy_tables!()
    :ok
  end

  test "successful legacy authentication upgrades the stored credential before issuing a session" do
    hash = :crypto.hash(:md5, "legacy" <> "old-password") |> Base.encode16(case: :lower)
    Repo.query!("INSERT INTO users (id,name,pass,class) VALUES (9101,'legacy',$1,'user')", [hash])

    assert {:ok, %{passhash: upgraded} = user, token} =
             Users.login("legacy", "old-password", "192.0.2.1")

    assert String.starts_with?(upgraded, "$2")
    assert Bcrypt.verify_pass("old-password", upgraded)
    assert String.starts_with?(token, "v2.")

    assert {:error, :invalid_password} =
             Users.change_pass(
               user,
               %{"id" => "9101", "pass1" => "x", "pass2" => "x"},
               "192.0.2.1"
             )

    assert Users.recover("legacy") == Users.recover("nonexistent")
  end

  test "public signup never replaces explicit administrator bootstrap" do
    assert {:ok, %{class: "user"}, _} =
             Users.create_user(
               %{
                 "name" => "ordinary",
                 "pass1" => "strong-test-password",
                 "pass2" => "strong-test-password"
               },
               "192.0.2.1"
             )
  end
end
