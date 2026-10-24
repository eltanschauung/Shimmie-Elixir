defmodule ShimmiePhoenix.SearchBudgetTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.Site.Index

  test "complex searches are rejected before queries, rather than silently dropping filters" do
    for search <- [String.duplicate("x", 4097), Enum.join(List.duplicate("x", 51), " "), <<255>>] do
      assert Index.list_posts(search, 1, 24) == {[], 0}
    end

    assert Index.list_posts("", 10_001, 24) == {[], 0}
    assert Index.list_posts("", 1, -1) == {[], 0}
  end

  test "twenty terms load the alias map only once" do
    ShimmiePhoenix.SiteSchemaHelper.ensure_legacy_tables!()

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS aliases (oldtag TEXT PRIMARY KEY, newtag TEXT NOT NULL)"
    )

    reference = make_ref()
    owner = self()
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :telemetry.attach(
      reference,
      event,
      fn _, _, metadata, _ -> send(owner, {:query, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(reference) end)
    Index.list_posts(Enum.map_join(1..20, " ", &"tag#{&1}"), 1, 24)
    queries = drain([])
    assert Enum.count(queries, &String.contains?(&1, "SELECT oldtag, newtag FROM aliases")) == 1
    assert length(queries) <= 7
  end

  defp drain(acc) do
    receive do
      {:query, sql} -> drain([sql | acc])
    after
      0 -> acc
    end
  end
end
