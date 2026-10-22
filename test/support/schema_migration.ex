defmodule PhoenixKitAI.Test.SchemaMigration do
  @moduledoc """
  Test-boot wrapper around the module-owned migration chain — the shape of the
  migration file `mix phoenix_kit.update` generates in a host app.

  `test_helper.exs` runs it through `Ecto.Migrator`, keyed on
  `PhoenixKitAI.Migrations.current_version/0`, so a chain bump re-applies on
  the next run.
  """

  use Ecto.Migration

  alias PhoenixKitAI.Migrations

  def up, do: Migrations.up(prefix: "public")
  def down, do: Migrations.down(prefix: "public")
end
