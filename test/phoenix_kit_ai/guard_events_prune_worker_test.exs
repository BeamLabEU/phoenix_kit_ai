defmodule PhoenixKitAI.GuardEventsPruneWorkerTest do
  @moduledoc """
  The old pruning worker of the guard's events is a shim: it deletes
  nothing, only queues `PhoenixKitAI.JournalPruneWorker`, and is no longer
  scheduled by the module.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{GuardEvent, GuardEventsPruneWorker, JournalPruneWorker}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})
    :ok
  end

  defp jobs(worker) do
    name = inspect(worker)
    TestRepo.all(from(j in Oban.Job, where: j.worker == ^name))
  end

  test "deletes nothing and queues one journal cleanup" do
    PhoenixKitAI.enable_system()
    at = DateTime.utc_now() |> DateTime.add(-400 * 86_400) |> DateTime.truncate(:second)
    old = TestRepo.insert!(%GuardEvent{kind: "limit_forgiven", task_key: "t", inserted_at: at})

    assert :ok = GuardEventsPruneWorker.perform(%Oban.Job{args: %{}})
    assert :ok = GuardEventsPruneWorker.perform(%Oban.Job{args: %{}})

    assert TestRepo.get(GuardEvent, old.uuid)
    assert [%Oban.Job{args: %{}, queue: "default"}] = jobs(JournalPruneWorker)
  end

  test "the module schedules the journal cleanup instead, daily, in a core queue" do
    assert [{cron, JournalPruneWorker}] = PhoenixKitAI.oban_crons()
    assert [_minute, _hour, "*", "*", "*"] = String.split(cron)
    assert GuardEventsPruneWorker.__opts__()[:queue] == :default
  end
end
