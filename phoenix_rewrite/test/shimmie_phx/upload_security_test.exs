defmodule ShimmiePhoenix.UploadSecurityTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.{BoundedCommand, SiteSchemaHelper}
  alias ShimmiePhoenix.Site.Upload

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    Repo.query!("INSERT INTO users(id,name,class) VALUES(2,'uploader','admin')")
    root = Path.join(System.tmp_dir!(), "upload_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old = Application.fetch_env(:shimmie_phx, :legacy_root)
    Application.put_env(:shimmie_phx, :legacy_root, root)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:shimmie_phx, :legacy_root, value)
        :error -> Application.delete_env(:shimmie_phx, :legacy_root)
      end

      File.rm_rf!(root)
    end)

    %{root: root, actor: %{id: 2, class: "admin"}}
  end

  test "fake images and malformed decodes never publish or insert", %{root: root, actor: actor} do
    path = Path.join(root, "invalid")

    for bytes <- ["not an image", <<137, 80, 78, 71, 13, 10, 26, 10, "not decodable">>] do
      File.write!(path, bytes)
      assert {:error, :invalid_upload} = upload(path, actor)
      assert Repo.query!("SELECT COUNT(*) FROM images").rows == [[0]]
      assert Path.wildcard(Path.join(root, "data/images/**/*"), match_dot: true) == []
    end
  end

  test "valid images have decoded dimensions and actual JPEG thumbnails", %{
    root: root,
    actor: actor
  } do
    path = fixture(root)
    assert {:ok, id} = upload(path, actor)

    assert [[2, 3, hash]] =
             Repo.query!("SELECT width,height,hash FROM images WHERE id=$1", [id]).rows

    [thumb] = Path.wildcard(Path.join(root, "data/thumbs/**/#{hash}"))
    assert <<255, 216, 255, _::binary>> = File.read!(thumb)
    assert File.ls!(Path.join(root, "data/.upload-staging")) == []
    assert {:error, :duplicate} = upload(path, actor)
  end

  test "publication failure rolls back rows and only removes this attempt's files", %{
    root: root,
    actor: actor
  } do
    path = fixture(root)
    hash = :crypto.hash(:md5, File.read!(path)) |> Base.encode16(case: :lower)

    parts =
      for i <- 0..(ShimmiePhoenix.Site.warehouse_splits() - 1), do: String.slice(hash, i * 2, 2)

    thumb = Path.join([root, "data", "thumbs"] ++ parts ++ [hash])
    File.mkdir_p!(Path.dirname(thumb))
    File.write!(thumb, "preexisting-file-do-not-delete")
    assert {:error, :db_failed} = upload(path, actor)
    assert Repo.query!("SELECT COUNT(*) FROM images").rows == [[0]]
    assert Repo.query!("SELECT COUNT(*) FROM tags").rows == [[0]]
    assert File.read!(thumb) == "preexisting-file-do-not-delete"
    assert Path.wildcard(Path.join(root, "data/images/**/#{hash}")) == []
  end

  test "disabled actors are rejected before opening a file", %{actor: _actor} do
    assert {:error, :permission_denied} = upload("/does-not-exist", %{id: 2, class: "banned"})
  end

  defp fixture(root) do
    path = Path.join(root, "real.png")

    assert {:ok, _} =
             BoundedCommand.run("convert", [
               "-limit",
               "thread",
               "1",
               "-size",
               "2x3",
               "xc:red",
               "PNG:" <> path
             ])

    path
  end

  defp upload(path, actor),
    do:
      Upload.create_file_upload(
        %Plug.Upload{path: path, filename: "test.png", content_type: "image/png"},
        actor,
        "192.0.2.1",
        "test_tag",
        "",
        "",
        ""
      )
end
