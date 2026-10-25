defmodule PhoenixKitAI.Integration.MigrationsBuildAloneTest do
  @moduledoc """
  This module's chain builds all eight of its tables exactly as core's chain
  does, on a database where core did not create the three it used to — the
  proof core needs before it stops creating them (core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`).

  `PhoenixKit.TestSupport.ModuleChainCheck` does the work in a scratch schema
  of its own, through `Ecto.Migrator` — so `ExUnit.Case`, not `DataCase`, and
  `async: false`. Excluded (`:requires_module_chain_check`, see
  `test_helper.exs`) against a core that does not ship the check yet.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.TestSupport.ModuleChainCheck
  alias PhoenixKitAI.Migrations
  alias PhoenixKitAI.Test.Repo

  @moduletag :integration
  @moduletag :requires_module_chain_check
  @moduletag timeout: :timer.minutes(3)

  test "the chain builds the AI tables without core" do
    assert :ok = ModuleChainCheck.check(Repo, Migrations)
  end
end
