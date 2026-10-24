defmodule ShimmiePhoenix.Repo.Migrations.SafeIdAllocation do
  use Ecto.Migration

  def up do
    ShimmiePhoenix.IDAllocator.install!(repo())
    # Imported installations may have retained the old VARCHAR(32) MD5 column.
    execute("ALTER TABLE users ALTER COLUMN pass TYPE TEXT")
  end

  def down do
    raise "Forward-only: restoring MAX+1 allocation is unsafe; keep sequences and IDs"
  end
end
