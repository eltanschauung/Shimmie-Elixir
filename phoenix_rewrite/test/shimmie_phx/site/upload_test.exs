defmodule ShimmiePhoenix.Site.UploadTest do
  use ShimmiePhoenix.DataCase, async: false

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site.Upload
  alias ShimmiePhoenix.SiteSchemaHelper

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    ensure_upload_columns!()
    SiteSchemaHelper.reset_legacy_tables!()
    Repo.query!("INSERT INTO config(name, value) VALUES ($1, $2)", ["transload_engine", "fopen"])

    root =
      Path.join(System.tmp_dir!(), "shimmie_phx_upload_#{System.unique_integer([:positive])}")

    old_root = Application.get_env(:shimmie_phx, :legacy_root)
    Application.put_env(:shimmie_phx, :legacy_root, root)

    on_exit(fn ->
      Application.put_env(:shimmie_phx, :legacy_root, old_root)
      File.rm_rf(root)
    end)

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

  test "file uploads preserve spaces in stored filenames" do
    upload_path =
      Path.join(System.tmp_dir!(), "shimmie_upload_#{System.unique_integer([:positive])}.zip")

    File.write!(upload_path, "zip")

    on_exit(fn -> File.rm(upload_path) end)

    upload = %Plug.Upload{
      path: upload_path,
      filename: "two words.zip",
      content_type: "application/zip"
    }

    assert {:ok, image_id} =
             Upload.create_file_upload(
               upload,
               %{id: 2, class: "user"},
               "203.0.113.7",
               "",
               "",
               "",
               ""
             )

    assert %{rows: [["two words.zip"]]} =
             Repo.query!("SELECT filename FROM images WHERE id = $1", [image_id])
  end

  defp ensure_upload_columns! do
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS approved_by_id BIGINT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS rating TEXT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS parent_id BIGINT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS mime TEXT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS length BIGINT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS video_codec TEXT")
    Repo.query!("ALTER TABLE images ADD COLUMN IF NOT EXISTS notes BIGINT")
  end
end
