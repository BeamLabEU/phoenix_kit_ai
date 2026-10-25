defmodule PhoenixKitAI.JournalPruneWorkerTest do
  @moduledoc """
  `PhoenixKitAI.JournalPruneWorker`: the nightly run (periods, a day to
  settle after a change, once a night, the module off), the manual run
  (boundaries in the job, checked again) and its uniqueness against the
  nightly one.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{GuardEvent, JournalPruneWorker, Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    PhoenixKit.Settings.update_setting("time_zone", "0")
    Application.put_env(:phoenix_kit_ai, :journal_prune, request_batch: 2, pause_ms: 0)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :journal_prune) end)
    PhoenixKitAI.enable_system()
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ago(seconds), do: DateTime.add(now(), -seconds)
  @day 86_400

  defp request!(at) do
    TestRepo.insert!(%Request{
      model: "m",
      request_type: "chat",
      status: "success",
      metadata: %{"messages" => [%{"content" => "x"}], "task" => "t"},
      inserted_at: at,
      updated_at: at
    })
  end

  defp event!(at),
    do: TestRepo.insert!(%GuardEvent{kind: "limit_forgiven", task_key: "t", inserted_at: at})

  defp exists?(%Request{uuid: uuid}), do: TestRepo.get(Request, uuid) != nil
  defp exists?(%GuardEvent{uuid: uuid}), do: TestRepo.get(GuardEvent, uuid) != nil

  defp periods!(periods, changed_ago) do
    at = ago(changed_ago) |> DateTime.to_iso8601()

    doc =
      periods
      |> Map.new(fn {kind, period} ->
        {Atom.to_string(kind), Retention.period_to_json(period)}
      end)
      |> Map.put("changed_at", Map.new(periods, fn {kind, _} -> {Atom.to_string(kind), at} end))

    {:ok, _} = Retention.write_settings(doc)
  end

  defp nightly, do: JournalPruneWorker.perform(%Oban.Job{args: %{}})

  defp manual(cutoffs, actor \\ nil) do
    %Ecto.Changeset{changes: %{args: args}} = JournalPruneWorker.manual_job(cutoffs, actor)
    JournalPruneWorker.perform(%Oban.Job{args: args})
  end

  defp min_cutoff(kind), do: kind |> Retention.floor() |> DateTime.truncate(:second)

  defp pruned_entries do
    TestRepo.all(from(e in PhoenixKit.Activity.Entry, where: e.action == "journal.pruned"))
  end

  describe "nightly" do
    test "every kind forever: nothing deleted, an ok stamp, no Activity" do
      row = request!(ago(3000 * @day))

      assert :ok = nightly()
      assert exists?(row)
      assert %{scheduled: %{status: :ok, counts: %{requests: 0}}} = Retention.last_run()
      assert pruned_entries() == []
    end

    test "applies the periods set more than a day ago" do
      periods!(%{requests: {3, :month}, guard_events: {3, :month}}, 2 * @day)
      old = request!(ago(3000 * @day))
      recent = request!(ago(60))
      old_event = event!(ago(3000 * @day))

      assert :ok = nightly()
      refute exists?(old)
      assert exists?(recent)
      refute exists?(old_event)
      assert [%{mode: "cron"}] = pruned_entries()
    end

    test "a period changed less than a day ago waits" do
      periods!(%{requests: {3, :month}}, 3600)
      old = request!(ago(3000 * @day))

      assert :ok = nightly()
      assert exists?(old)
    end

    test "once a night: a second run after an ok one less than 20 hours ago does nothing" do
      periods!(%{requests: {3, :month}}, 2 * @day)
      assert :ok = nightly()
      first = Retention.last_run().scheduled

      old = request!(ago(3000 * @day))
      assert :ok = nightly()
      assert exists?(old)
      assert Retention.last_run().scheduled == first
    end

    test "an ok run more than 20 hours ago does not hold the night back" do
      periods!(%{requests: {3, :month}}, 2 * @day)
      at = ago(21 * 3600) |> DateTime.to_iso8601()

      {:ok, _} =
        PhoenixKit.Settings.update_json_setting_with_module(
          Retention.last_run_key(),
          %{"scheduled" => %{"at" => at, "status" => "ok"}},
          "ai",
          history: false
        )

      old = request!(ago(3000 * @day))
      assert :ok = nightly()
      refute exists?(old)
    end

    test "with the module off: skipped, nothing deleted" do
      periods!(%{requests: {3, :month}}, 2 * @day)
      PhoenixKitAI.disable_system()
      old = request!(ago(3000 * @day))

      assert :ok = nightly()
      assert exists?(old)
      assert %{scheduled: %{status: :skipped}} = Retention.last_run()
    end

    test "a period without its changed_at is not applied" do
      {:ok, _} = Retention.write_settings(%{"requests" => %{"n" => 3, "unit" => "month"}})
      old = request!(ago(3000 * @day))

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = nightly() end)
      assert exists?(old)
    end

    test "the run's options come from the app env" do
      Application.put_env(:phoenix_kit_ai, :journal_prune,
        request_batch: 1,
        pause_ms: 0,
        max_rows: 1
      )

      periods!(%{requests: {3, :month}}, 2 * @day)
      for n <- 1..3, do: request!(ago((3000 + n) * @day))

      assert :ok = nightly()
      assert %{scheduled: %{counts: %{requests: 1}, more_left: true}} = Retention.last_run()
    end
  end

  describe "manual" do
    test "deletes by the boundaries in the job, with the actor" do
      actor = Fixtures.user_fixture()
      old = request!(ago(3000 * @day))

      assert :ok = manual(%{requests: min_cutoff(:requests)}, actor.uuid)
      refute exists?(old)
      assert %{manual: %{status: :ok, actor_uuid: actor_uuid}} = Retention.last_run()
      assert actor_uuid == actor.uuid
      assert [%{mode: "manual", actor_uuid: ^actor_uuid}] = pruned_entries()
    end

    test "a forged job with a boundary inside the month deletes nothing newer than the floor" do
      floor = min_cutoff(:requests)
      old = request!(DateTime.add(floor, -60))
      kept = request!(DateTime.add(floor, 60))
      recent = request!(ago(120))

      assert :ok = manual(%{requests: ago(60)})
      refute exists?(old)
      assert exists?(kept)
      assert exists?(recent)
    end

    test "a job with a boundary in the future is cancelled, nothing deleted" do
      row = request!(ago(3000 * @day))

      assert {:cancel, {:cutoff_in_future, :requests}} =
               manual(%{requests: DateTime.add(now(), 3600)})

      assert exists?(row)
      assert %{manual: %{status: :failed, error: "cutoff_in_future"}} = Retention.last_run()
    end

    test "a moment in the app env is not the job's: the floor stays where it is" do
      Application.put_env(:phoenix_kit_ai, :journal_prune,
        pause_ms: 0,
        now: DateTime.add(now(), 400 * @day)
      )

      floor = min_cutoff(:requests)
      old = request!(DateTime.add(floor, -60))
      kept = request!(DateTime.add(floor, 60))
      recent = request!(ago(60))

      assert :ok = manual(%{requests: ago(30)})
      refute exists?(old)
      assert exists?(kept)
      assert exists?(recent)
    end

    test "app env options that are not a keyword list are ignored, with a warning" do
      Application.put_env(:phoenix_kit_ai, :journal_prune, [1, 2])
      old = request!(ago(3000 * @day))

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = manual(%{requests: ago(30)}) end)
      refute exists?(old)
      assert log =~ "not a keyword list"
    end

    test "unreadable boundaries are cancelled and stamped" do
      assert {:cancel, :invalid_args} =
               JournalPruneWorker.perform(%Oban.Job{
                 args: %{"mode" => "manual", "cutoffs" => %{"requests" => "yesterday"}}
               })

      assert %{manual: %{status: :failed, error: "invalid_args"}} = Retention.last_run()
    end

    test "with the module off: skipped" do
      PhoenixKitAI.disable_system()
      old = request!(ago(3000 * @day))

      assert :ok = manual(%{requests: min_cutoff(:requests)})
      assert exists?(old)
      assert %{manual: %{status: :skipped}} = Retention.last_run()
    end
  end

  describe "the job" do
    setup do
      start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})
      :ok
    end

    test "a nightly job while a manual one is queued conflicts" do
      assert {:ok, %Oban.Job{conflict?: false}} =
               %{requests: min_cutoff(:requests)}
               |> JournalPruneWorker.manual_job(nil)
               |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true}} = %{} |> JournalPruneWorker.new() |> Oban.insert()
    end

    test "a job running for longer than a minute still conflicts" do
      {:ok, job} = %{} |> JournalPruneWorker.new() |> Oban.insert()
      long_ago = DateTime.add(DateTime.utc_now(), -600)

      TestRepo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: long_ago, inserted_at: long_ago]
      )

      assert {:ok, %Oban.Job{conflict?: true}} =
               %{requests: min_cutoff(:requests)}
               |> JournalPruneWorker.manual_job(nil)
               |> Oban.insert()
    end

    test "a finished job does not" do
      {:ok, job} = %{} |> JournalPruneWorker.new() |> Oban.insert()
      TestRepo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])

      assert {:ok, %Oban.Job{conflict?: false}} = %{} |> JournalPruneWorker.new() |> Oban.insert()
    end

    test "default queue, three attempts, 25 minutes" do
      assert JournalPruneWorker.__opts__()[:queue] == :default
      assert JournalPruneWorker.__opts__()[:max_attempts] == 3
      assert JournalPruneWorker.timeout(%Oban.Job{}) == :timer.minutes(25)
    end
  end
end
