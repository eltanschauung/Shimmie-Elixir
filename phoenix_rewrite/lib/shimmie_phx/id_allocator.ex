defmodule ShimmiePhoenix.IDAllocator do
  @moduledoc "Concurrent-safe IDs for imported schemas; never substitutes an unsafe fallback ID."
  alias ShimmiePhoenix.Repo

  @tables ~w(users images tags comments blotter wiki_pages source_histories tag_histories bans notes note_request note_histories private_message)

  def next!(table) when table in @tables do
    [[id]] = Repo.query!("SELECT nextval(pg_get_serial_sequence($1, 'id'))", [table]).rows
    if is_integer(id) and id > 0, do: id, else: raise("ID allocation migration is required")
  end

  def next_sqlite!(path, table) when table in @tables do
    sql =
      "BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS shimmie_id_allocations(name TEXT PRIMARY KEY, value INTEGER NOT NULL); " <>
        "INSERT INTO shimmie_id_allocations(name,value) VALUES ('#{table}', (SELECT MAX(COALESCE(MAX(id),0),0)+1 FROM #{table})) " <>
        "ON CONFLICT(name) DO UPDATE SET value=MAX(value,(SELECT COALESCE(MAX(id),0) FROM #{table}))+1; " <>
        "SELECT value FROM shimmie_id_allocations WHERE name='#{table}'; COMMIT;"

    case System.cmd("sqlite3", ["-bail", "-cmd", ".timeout 5000", path, sql],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {id, ""} = output |> String.trim() |> Integer.parse()
        id

      _ ->
        raise "SQLite ID allocation failed"
    end
  end

  # Called only by the approved forward migration (and synthetic schema tests).
  # Deploy with legacy MAX+1 writers stopped. Existing IDs and higher sequence
  # positions are preserved, including identity/serial sequences already owned.
  def install!(repo, schema \\ "public") do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, schema), do: raise("Invalid schema")

    Enum.each(@tables, fn table ->
      qualified = ~s("#{schema}"."#{table}")

      if repo.query!("SELECT to_regclass($1)", [qualified]).rows != [[nil]] do
        repo.query!("LOCK TABLE #{qualified} IN ACCESS EXCLUSIVE MODE")

        [[type, default, identity]] =
          repo.query!(
            "SELECT data_type, column_default, is_identity FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 AND column_name='id'",
            [schema, table]
          ).rows

        unless type in ["bigint", "integer", "smallint"],
          do: raise("Noninteger ID requires manual review")

        [[sequence]] = repo.query!("SELECT pg_get_serial_sequence($1,'id')", [qualified]).rows

        sequence =
          if is_nil(sequence) do
            unless is_nil(default) and identity == "NO",
              do: raise("Unrecognized ID default requires manual review")

            sequence = ~s("#{schema}"."#{table}_shimmie_id_seq")
            repo.query!("CREATE SEQUENCE #{sequence} AS BIGINT")
            repo.query!("ALTER SEQUENCE #{sequence} OWNED BY #{qualified}.id")

            repo.query!(
              "ALTER TABLE #{qualified} ALTER COLUMN id SET DEFAULT nextval('#{sequence}'::regclass)"
            )

            sequence
          else
            sequence
          end

        [[max_id]] = repo.query!("SELECT GREATEST(COALESCE(MAX(id),0),0) FROM #{qualified}").rows
        # Use a regclass-derived identifier from PostgreSQL, not request input.
        [[last, called]] = repo.query!("SELECT last_value,is_called FROM #{sequence}").rows
        next = max(max_id + 1, if(called, do: last + 1, else: last))

        [[increment, cycle]] =
          repo.query!(
            "SELECT seqincrement,seqcycle FROM pg_sequence WHERE seqrelid=$1::text::regclass",
            [sequence]
          ).rows

        unless increment == 1 and cycle == false,
          do: raise("Nonstandard sequence requires manual review")

        repo.query!("SELECT setval($1::text::regclass,$2,false)", [sequence, next])
      end
    end)
  end
end
