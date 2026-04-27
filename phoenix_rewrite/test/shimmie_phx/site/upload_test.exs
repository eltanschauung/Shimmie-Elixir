defmodule ShimmiePhoenix.Site.UploadTest do
  use ShimmiePhoenix.DataCase, async: false

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site.Upload
  alias ShimmiePhoenix.SiteSchemaHelper

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["transload_engine", "fopen"])
    :ok
  end

  test "URL uploads reject loopback targets before fetching" do
    actor = %{id: 2, class: "user"}

    assert {:error, :invalid_url} =
             Upload.create_url_upload(
               "http://127.0.0.1/private.png",
               actor,
               "127.0.0.1",
               "",
               "",
               "",
               ""
             )

    assert {:error, :invalid_url} =
             Upload.create_url_upload(
               "http://localhost/private.png",
               actor,
               "127.0.0.1",
               "",
               "",
               "",
               ""
             )
  end
end
