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

  test "PostgreSQL mutations roll back related writes on an error result" do
    Repo.query!("CREATE TEMP TABLE native_mutation_fixture(id INTEGER PRIMARY KEY)")

    assert {:error, :synthetic_failure} =
             Mutation.atomic(fn ->
               Repo.query!("INSERT INTO native_mutation_fixture VALUES(1)")
               {:error, :synthetic_failure}
             end)

    assert Repo.query!("SELECT COUNT(*) FROM native_mutation_fixture").rows == [[0]]
  end
end
