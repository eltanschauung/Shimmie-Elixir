defmodule ShimmiePhoenix.IDAllocator do
  @moduledoc "Concurrent-safe IDs for imported schemas; never substitutes an unsafe fallback ID."
  alias ShimmiePhoenix.Repo

  @tables ~w(users images tags comments blotter wiki_pages source_histories tag_histories bans notes note_request note_histories private_message)

  def next!(table) when table in @tables do
    [[id]] = Repo.query!("SELECT nextval(pg_get_serial_sequence($1, 'id'))", [table]).rows

    if is_integer(id) and id > 0 do
      id
    else
      raise("ID allocation migration is required")
    end
  end

  def install!(repo, schema \\ "public") do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, schema) do
      raise("Invalid schema")
    end

    Enum.each(@tables, fn table ->
      qualified = ~s("#{schema}"."#{table}")

      if repo.query!("SELECT to_regclass($1)", [qualified]).rows != [[nil]] do
        repo.query!("LOCK TABLE #{qualified} IN ACCESS EXCLUSIVE MODE")

        [[type, default, identity]] =
          repo.query!(
            "SELECT data_type, column_default, is_identity FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 AND column_name='id'",
            [schema, table]
          ).rows

        unless type in ["bigint", "integer", "smallint"] do
          raise("Noninteger ID requires manual review")
        end

        [[sequence]] = repo.query!("SELECT pg_get_serial_sequence($1,'id')", [qualified]).rows

        sequence =
          if is_nil(sequence) do
            unless is_nil(default) and identity == "NO" do
              raise("Unrecognized ID default requires manual review")
            end

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
        [[last, called]] = repo.query!("SELECT last_value,is_called FROM #{sequence}").rows

        next =
          max(
            max_id + 1,
            if(called) do
              last + 1
            else
              last
            end
          )

        [[increment, cycle]] =
          repo.query!(
            "SELECT seqincrement,seqcycle FROM pg_sequence WHERE seqrelid=$1::text::regclass",
            [sequence]
          ).rows

        unless increment == 1 and cycle == false do
          raise("Nonstandard sequence requires manual review")
        end

        repo.query!("SELECT setval($1::text::regclass,$2,false)", [sequence, next])
      end
    end)
  end
end
