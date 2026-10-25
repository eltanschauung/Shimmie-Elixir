defmodule ShimmiePhoenix.NativeContextsTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.Site.{PrivateMessages, UserProfile}
  alias ShimmiePhoenix.SiteSchemaHelper

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      "INSERT INTO users(id,name,class) VALUES(2,'sender','user'),(3,'recipient','user')"
    )

    :ok
  end

  test "PostgreSQL private messages retain visibility, unread counts and deletion" do
    sender = %{id: 2, name: "sender", class: "user"}
    recipient = %{id: 3, name: "recipient", class: "user"}
    assert :ok = PrivateMessages.send(sender, 3, "subject", "message", "192.0.2.1")
    assert PrivateMessages.unread_count(recipient) == 1
    assert [message] = PrivateMessages.list_for_display(recipient, recipient)
    assert PrivateMessages.list_for_display(recipient, sender) == []
    assert {:ok, _} = PrivateMessages.get_visible(message.id, recipient)
    assert {:error, :permission_denied} = PrivateMessages.get_visible(message.id, sender)
    assert :ok = PrivateMessages.mark_read(message.id)
    assert PrivateMessages.unread_count(recipient) == 0
    assert :ok = PrivateMessages.delete(message.id, recipient)
    assert PrivateMessages.list_for_user(3) == []
  end

  test "PostgreSQL biography reads and writes retain their contract" do
    assert UserProfile.biography(2) == ""
    assert :ok = UserProfile.set_biography(2, "example biography")
    assert UserProfile.biography(2) == "example biography"
  end
end
