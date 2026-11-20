defmodule PhoenixKitAI.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  Tests using this case are **automatically tagged `:integration`** so
  they are excluded when the test database is unavailable (the tag is
  filtered out in `test/test_helper.exs`).

  The SQL sandbox is enabled so changes done to the database are
  reverted at the end of every test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitAI.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitAI.ActivityLogAssertions
      import PhoenixKitAI.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.Test

  setup tags do
    pid = Sandbox.start_owner!(Test.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    clear_settings_cache()

    # The guard's per-node caches outlive the sandbox's rollback. Only in a
    # synchronous test: the table is shared with tests running alongside.
    unless tags[:async], do: PhoenixKitAI.Guard.reset_caches()
    :ok
  end

  @doc """
  Clears core's `:settings` cache around a test.

  The cache is one process outside the sandbox: a value read inside the
  test's transaction would survive the rollback and leak into a later test,
  and a setting written with a direct `insert!` bypasses the write-side
  invalidation, so a stale entry would be served instead. Cleared on the way
  in (a previous test may have left entries) and on the way out (this test's
  reads must not survive either). The cache only runs when the repo is up
  (see `test_helper.exs`), hence the guard — `Cache.clear/1` logs when the
  process is absent.
  """
  def clear_settings_cache do
    if Application.get_env(:phoenix_kit_ai, :test_repo_available, false) do
      PhoenixKit.Cache.clear(:settings)
      on_exit(fn -> PhoenixKit.Cache.clear(:settings) end)
    end

    :ok
  end
end
