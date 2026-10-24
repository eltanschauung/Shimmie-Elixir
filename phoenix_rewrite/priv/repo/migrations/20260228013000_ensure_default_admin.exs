defmodule ShimmiePhoenix.Repo.Migrations.EnsureDefaultAdmin do
  use Ecto.Migration

  def up do
    ShimmiePhoenix.Bootstrap.ensure_admin!(repo())
  end

  def down do
    :ok
  end
end
