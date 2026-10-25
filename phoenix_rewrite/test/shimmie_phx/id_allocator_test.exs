defmodule ShimmiePhoenix.IDAllocatorTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.IDAllocator

  test "legacy migration preserves rows and never moves an existing sequence backward" do
    Repo.query!("CREATE SCHEMA id_fixture")
    Repo.query!("CREATE TABLE id_fixture.images(id BIGINT PRIMARY KEY, value TEXT)")
    Repo.query!("INSERT INTO id_fixture.images VALUES(71,'preserved')")
    Repo.query!("CREATE TABLE id_fixture.tags(id BIGSERIAL PRIMARY KEY)")
    Repo.query!("SELECT setval('id_fixture.tags_id_seq',900,true)")
    IDAllocator.install!(Repo, "id_fixture")

    assert [[72]] ==
             Repo.query!("INSERT INTO id_fixture.images(value) VALUES('new') RETURNING id").rows

    assert [[901]] == Repo.query!("INSERT INTO id_fixture.tags DEFAULT VALUES RETURNING id").rows
    IDAllocator.install!(Repo, "id_fixture")

    assert [[73]] ==
             Repo.query!("INSERT INTO id_fixture.images(value) VALUES('newer') RETURNING id").rows

    assert [["preserved"]] == Repo.query!("SELECT value FROM id_fixture.images WHERE id=71").rows
  end

  test "PostgreSQL allocates unique IDs under concurrency" do
    # Sequences are atomic even when the sandbox shares a connection across tasks.
    ids =
      1..80
      |> Task.async_stream(fn _ -> IDAllocator.next!("images") end)
      |> Enum.map(fn {:ok, id} -> id end)

    assert length(Enum.uniq(ids)) == 80
  end
end
