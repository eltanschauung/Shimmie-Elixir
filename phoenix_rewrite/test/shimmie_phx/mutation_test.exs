defmodule ShimmiePhoenix.MutationTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.{Mutation, SiteSchemaHelper}
  alias ShimmiePhoenix.Site.PostSet

  test "invalid metadata rolls back tag mutations too" do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      "INSERT INTO images(id,filename,filesize,hash,ext,width,height,source) VALUES(101,'test.png',1,'abcdefabcdefabcdefabcdefabcdefab','png',1,1,'original')"
    )

    assert {:error, :invalid_source} =
             PostSet.apply(
               101,
               %{"tags" => "new_tag", "source" => "javascript:bad"},
               %{id: 2, class: "admin"},
               "192.0.2.1"
             )

    assert Repo.query!("SELECT COUNT(*) FROM tags").rows == [[0]]
    assert Repo.query!("SELECT source FROM images WHERE id=101").rows == [["original"]]
  end

  test "SQLite stops and rolls back the entire write batch on an error" do
    path =
      Path.join(
        System.tmp_dir!(),
        "mutation_fixture_#{System.unique_integer([:positive])}.sqlite"
      )

    previous = System.get_env("SHIMMIE_LEGACY_DSN")

    on_exit(fn ->
      if previous,
        do: System.put_env("SHIMMIE_LEGACY_DSN", previous),
        else: System.delete_env("SHIMMIE_LEGACY_DSN")

      File.rm(path)
    end)

    System.put_env("SHIMMIE_LEGACY_DSN", "sqlite:" <> path)
    {_, 0} = System.cmd("sqlite3", [path, "CREATE TABLE fixture(id INTEGER PRIMARY KEY);"])

    assert {:error, :sqlite_failed} =
             Mutation.atomic(fn ->
               :ok = Mutation.sqlite_exec(path, "INSERT INTO fixture VALUES(1)")
               :ok = Mutation.sqlite_exec(path, "INSERT INTO missing_table VALUES(2)")
               Mutation.sqlite_exec(path, "INSERT INTO fixture VALUES(3)")
             end)

    assert {"0\n", 0} = System.cmd("sqlite3", [path, "SELECT COUNT(*) FROM fixture"])
  end

  test "SQLite tag edits and metadata use a single transaction" do
    path =
      Path.join(System.tmp_dir!(), "tag_fixture_#{System.unique_integer([:positive])}.sqlite")

    previous = System.get_env("SHIMMIE_LEGACY_DSN")

    on_exit(fn ->
      if previous,
        do: System.put_env("SHIMMIE_LEGACY_DSN", previous),
        else: System.delete_env("SHIMMIE_LEGACY_DSN")

      File.rm(path)
    end)

    System.put_env("SHIMMIE_LEGACY_DSN", "sqlite:" <> path)

    {_, 0} =
      System.cmd("sqlite3", [
        path,
        "CREATE TABLE config(name TEXT PRIMARY KEY,value TEXT); CREATE TABLE images(id INTEGER PRIMARY KEY,hash TEXT,ext TEXT,filename TEXT,width INTEGER,height INTEGER,filesize INTEGER,source TEXT,posted TEXT,owner_ip TEXT,parent_id INTEGER,rating TEXT,locked INTEGER); CREATE TABLE tags(id INTEGER PRIMARY KEY,tag TEXT UNIQUE,count INTEGER); CREATE TABLE image_tags(image_id INTEGER,tag_id INTEGER,UNIQUE(image_id,tag_id)); INSERT INTO images VALUES(101,'abcdefabcdefabcdefabcdefabcdefab','png','test.png',1,1,1,'original','2026-01-01','','','?',0);"
      ])

    actor = %{id: 2, class: "admin"}

    assert {:error, :invalid_source} =
             PostSet.apply(
               101,
               %{"tags" => "new_tag", "source" => "javascript:bad"},
               actor,
               "192.0.2.1"
             )

    assert {"0\n", 0} = System.cmd("sqlite3", [path, "SELECT COUNT(*) FROM tags"])

    assert :ok =
             PostSet.apply(
               101,
               %{"tags" => "new_tag", "source" => "https://example.test/"},
               actor,
               "192.0.2.1"
             )

    assert {"new_tag|1\n", 0} = System.cmd("sqlite3", [path, "SELECT tag,count FROM tags"])
    assert :ok = PostSet.apply(101, %{"tags" => "second_tag"}, actor, "192.0.2.1")

    assert {"new_tag|0\nsecond_tag|1\n", 0} =
             System.cmd("sqlite3", [path, "SELECT tag,count FROM tags ORDER BY tag"])
  end

  test "a failed note counter write rolls back the note insert" do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      "INSERT INTO images(id,filename,filesize,hash,ext,width,height) VALUES(101,'test.png',1,'abcdefabcdefabcdefabcdefabcdefab','png',1,1)"
    )

    Repo.query!(
      "CREATE FUNCTION pg_temp.fail_counter() RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER fail_counter BEFORE UPDATE OF notes ON images FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_counter()"
    )

    attrs = %{
      "note_x1" => "0",
      "note_y1" => "0",
      "note_width" => "1",
      "note_height" => "1",
      "note_text" => "test"
    }

    assert {:error, :db_failed} =
             ShimmiePhoenix.Site.PostAdmin.add_note(101, %{id: 2, class: "admin"}, attrs)

    assert Repo.query!("SELECT COUNT(*) FROM notes WHERE image_id=101").rows == [[0]]
  end
end
