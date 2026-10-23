defmodule PhoenixKitAI.GuardFailureTest do
  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Guard, GuardBlocks, Request, TaskLimits, Tasks}
  alias PhoenixKitAI.Test.FakeGuardTasks

  defmodule UnavailableRepo do
    @moduledoc false
    def all(_query), do: unavailable()
    # Keep core's timezone setting lookup outside this module's fault injection.
    def get_by(PhoenixKit.Settings.Setting, _clauses), do: nil
    def get_by(_schema, _clauses), do: unavailable()
    def one(_query), do: unavailable()

    defp unavailable, do: exit({:database_unavailable, "PRIVATE-DATABASE-DETAIL"})
  end

  test "database exits keep the guard's documented fallbacks and omit the exit payload" do
    :ok = ModuleRegistry.register(FakeGuardTasks)
    on_exit(fn -> ModuleRegistry.unregister(FakeGuardTasks) end)
    flagged = Tasks.for_call("test.flagged")
    ruled = Tasks.for_call("test.rules")
    user = Ecto.UUID.generate()
    repo = Application.fetch_env!(:phoenix_kit, :repo)

    request = %Request{
      user_uuid: user,
      total_tokens: 1,
      metadata: %{"task" => ruled.key, "source" => "Allowed.Caller"}
    }

    log =
      capture_log(fn ->
        Application.put_env(:phoenix_kit, :repo, UnavailableRepo)

        try do
          assert Guard.self_flag?(flagged)
          assert Guard.self_flag_instruction(flagged) =~ flagged.purpose
          assert :ok = GuardBlocks.check(flagged, user)
          assert :ok = TaskLimits.check(flagged, user_uuid: user)
          assert :ok = Guard.check_anomalies(request)
        after
          Application.put_env(:phoenix_kit, :repo, repo)
        end
      end)

    assert log =~ "exit"
    refute log =~ "PRIVATE-DATABASE-DETAIL"
  end
end
