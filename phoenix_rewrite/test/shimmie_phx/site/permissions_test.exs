defmodule ShimmiePhoenix.Site.PermissionsTest do
  use ShimmiePhoenix.DataCase, async: false

  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.SiteSchemaHelper

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    :ok
  end

  test "empty permission config is a deny-all override" do
    assert Permissions.allowed?(:comment_create, "user")

    assert :ok = Store.put_config("perm_comment_create", "")

    refute Permissions.allowed?(:comment_create, "user")
    assert Permissions.classes_for(:comment_create) == []
  end
end
