defmodule PhoenixKitAI.GuardEventsPruneWorkerTest do
  @moduledoc """
  The daily pruning of the guard's events (`PhoenixKitAI.GuardEventsPruneWorker`):
  events older than 180 days go, newer ones stay, nothing is touched while
  the module is off; the module schedules it through `oban_crons/0`.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{GuardEvent, GuardEventsPruneWorker}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defp event(days_ago) do
    at = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400) |> DateTime.truncate(:second)
    TestRepo.insert!(%GuardEvent{kind: "limit_forgiven", task_key: "t", inserted_at: at})
  end

  defp kept, do: TestRepo.all(GuardEvent) |> Enum.map(& &1.uuid) |> Enum.sort()

  test "deletes the events older than 180 days and keeps the rest" do
    PhoenixKitAI.enable_system()
    _old = event(181)
    _older = event(400)
    recent = event(179)
    today = event(0)

    assert {:ok, 2} = GuardEventsPruneWorker.perform(%Oban.Job{args: %{}})
    assert kept() == Enum.sort([recent.uuid, today.uuid])
  end

  test "does nothing while the module is off" do
    PhoenixKitAI.disable_system()
    old = event(200)

    assert {:ok, 0} = GuardEventsPruneWorker.perform(%Oban.Job{args: %{}})
    assert kept() == [old.uuid]
  end

  test "is scheduled by the module, daily, in a core queue" do
    assert [{cron, GuardEventsPruneWorker}] = PhoenixKitAI.oban_crons()
    assert [_minute, _hour, "*", "*", "*"] = String.split(cron)
    assert GuardEventsPruneWorker.__opts__()[:queue] == :default
  end
end
