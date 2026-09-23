defmodule PhoenixKitAI.TranslationSweepTest do
  @moduledoc """
  The shared translation sweep: the chain keeps one tick waiting, a tick
  stops for the right reason and records it, and a sweep admits
  candidates within both caps — skipping the (resource, language) pairs
  already in flight or whose latest job was discarded, so they cannot hold
  up the rest.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.TranslationSweep

  defmodule Source do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 1
    @behaviour PhoenixKitAI.TranslationSweep

    @impl Oban.Worker
    def perform(_job), do: PhoenixKitAI.TranslationSweep.perform(__MODULE__)

    @impl PhoenixKitAI.TranslationSweep
    def sweep_key, do: "test_source"

    @impl PhoenixKitAI.TranslationSweep
    def sweep_settings do
      Map.merge(
        %{enabled?: true, interval_minutes: 30, languages: ["de", "fr"], source_language: "en"},
        Process.get(:sweep_settings, %{})
      )
    end

    @impl PhoenixKitAI.TranslationSweep
    def sweep_ready(trigger) do
      send(self(), {:ready_asked, trigger})
      Process.get(:sweep_ready, :ok)
    end

    @impl PhoenixKitAI.TranslationSweep
    def sweep_resource_types, do: ["sweep_thing"]

    @impl PhoenixKitAI.TranslationSweep
    def sweep_candidates(_source_lang, _targets), do: Process.get(:sweep_candidates, [])

    @impl PhoenixKitAI.TranslationSweep
    def sweep_prompts,
      do: Process.get(:sweep_prompts, {:ok, %{"sweep_thing" => Ecto.UUID.generate()}})
  end

  setup context do
    pid = Sandbox.start_owner!(TestRepo, shared: not context[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, _endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Sweep-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      })

    :ok
  end

  defp candidate(uuid, langs), do: %{resource_type: "sweep_thing", uuid: uuid, languages: langs}

  defp translate_jobs do
    from(j in Oban.Job, where: j.worker == "PhoenixKitAI.TranslateWorker")
    |> TestRepo.all()
    |> Enum.map(&{&1.args["resource_uuid"], &1.args["target_lang"]})
    |> Enum.sort()
  end

  defp translate_job!(uuid, lang, state) do
    %{
      resource_type: "sweep_thing",
      resource_uuid: uuid,
      endpoint_uuid: Ecto.UUID.generate(),
      prompt_uuid: Ecto.UUID.generate(),
      source_lang: "en",
      target_lang: lang
    }
    |> PhoenixKitAI.TranslateWorker.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(
      state: state,
      discarded_at: if(state == "discarded", do: DateTime.utc_now())
    )
    |> TestRepo.update!()
  end

  describe "take_within_budget/3" do
    test "admits in order, a candidate that does not fit whole for the languages that do" do
      list = [candidate("a", ~w(de fr es)), candidate("b", ~w(de)), candidate("c", ~w(fr))]

      assert TranslationSweep.take_within_budget(list, :infinity, 4) ==
               [candidate("a", ~w(de fr es)), candidate("b", ~w(de))]

      assert TranslationSweep.take_within_budget(list, :infinity, 2) == [
               candidate("a", ~w(de fr))
             ]

      assert TranslationSweep.take_within_budget(list, 2, :infinity) == Enum.take(list, 2)
      assert TranslationSweep.take_within_budget(list, 0, 10) == []
    end
  end

  describe "a tick" do
    test "enqueues the missing languages and records what it did" do
      [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      Process.put(:sweep_candidates, [candidate(a, ~w(de fr)), candidate(b, ~w(fr nl))])

      assert {:ok, info} = TranslationSweep.run_tick(Source)
      assert info.enqueued == 3
      assert info.candidates == 2
      # "nl" is not a target language.
      assert translate_jobs() == Enum.sort([{a, "de"}, {a, "fr"}, {b, "fr"}])
      assert %{"reason" => "ok", "enqueued" => 3} = TranslationSweep.last_run(Source)
    end

    test "stops for each gate, and a manual run skips only the automatic switch" do
      Process.put(:sweep_candidates, [candidate(Ecto.UUID.generate(), ~w(de))])

      Process.put(:sweep_settings, %{enabled?: false})
      assert {:sweep_disabled, _} = TranslationSweep.run_tick(Source, :interval)
      assert_received {:ready_asked, :interval}
      assert {:ok, %{enqueued: 1}} = TranslationSweep.run_tick(Source, :manual)
      assert_received {:ready_asked, :manual}

      Process.put(:sweep_ready, {:stop, :feature_off})
      assert {:feature_off, _} = TranslationSweep.run_tick(Source, :manual)
      Process.delete(:sweep_ready)

      Process.put(:sweep_settings, %{languages: []})
      assert {:no_target_languages, _} = TranslationSweep.run_tick(Source)

      Process.put(:sweep_settings, %{batch: 0})
      assert {:sweep_stalled, _} = TranslationSweep.run_tick(Source)

      # A fresh candidate: the first one's de is in flight since the manual run.
      Process.put(:sweep_candidates, [candidate(Ecto.UUID.generate(), ~w(de))])
      Process.put(:sweep_settings, %{})
      Process.put(:sweep_prompts, {:error, :no_prompt})
      assert {:prompts_unavailable, _} = TranslationSweep.run_tick(Source)
      assert %{"reason" => "prompts_unavailable"} = TranslationSweep.last_run(Source)

      {:ok, _} = PhoenixKitAI.disable_system()
      assert {:ai_unavailable, _} = TranslationSweep.run_tick(Source)
    end

    test "the in-flight ceiling counts the source's incomplete jobs" do
      translate_job!(Ecto.UUID.generate(), "de", "executing")
      translate_job!(Ecto.UUID.generate(), "de", "available")
      new = Ecto.UUID.generate()
      Process.put(:sweep_candidates, [candidate(new, ~w(de fr))])

      Process.put(:sweep_settings, %{max_in_flight: 2})
      assert {:ceiling_reached, %{in_flight: 2}} = TranslationSweep.run_tick(Source)

      # One slot left: the candidate is admitted for one language.
      Process.put(:sweep_settings, %{max_in_flight: 3})
      assert {:ok, %{enqueued: 1}} = TranslationSweep.run_tick(Source)
      assert {new, "de"} in translate_jobs()
    end

    # Two ticks at once read the same in-flight count and each admit up to
    # the room it leaves, so between them they can pass the ceiling and
    # enqueue one pair twice. The scheduled tick is the one that must run;
    # an operator's button waits.
    test "a manual run refuses while a tick of this source is running" do
      Process.put(:sweep_candidates, [candidate(Ecto.UUID.generate(), ~w(de))])
      {:ok, _tick} = TranslationSweep.ensure_scheduled(Source)
      TestRepo.update_all(Oban.Job, set: [state: "executing"])

      assert {:sweep_running, %{}} = TranslationSweep.run_tick(Source, :manual)
      assert translate_jobs() == []
      # A refusal is not an outcome: it does not overwrite the last run.
      refute TranslationSweep.last_run(Source)

      # The scheduled tick itself is the running job, and must not refuse.
      assert {:ok, %{enqueued: 1}} = TranslationSweep.run_tick(Source)
    end

    test "a pair already in flight takes no batch slot and cuts off no later language" do
      [busy, next] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      translate_job!(busy, "de", "executing")

      # One resource per tick: the busy one's de must not spend it.
      Process.put(:sweep_candidates, [candidate(busy, ~w(de)), candidate(next, ~w(de))])
      Process.put(:sweep_settings, %{batch: 1, max_in_flight: 5})

      assert {:ok, %{enqueued: 1, candidates: 1, in_flight: 1}} =
               TranslationSweep.run_tick(Source)

      assert {next, "de"} in translate_jobs()

      # One job of room: fr goes, rather than the busy de being admitted again.
      Process.put(:sweep_candidates, [candidate(busy, ~w(de fr))])
      Process.put(:sweep_settings, %{max_in_flight: 3})
      assert {:ok, %{enqueued: 1}} = TranslationSweep.run_tick(Source)
      assert {busy, "fr"} in translate_jobs()
    end

    test "a resource listed twice takes one batch slot" do
      [twice, next] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      Process.put(:sweep_candidates, [
        candidate(twice, ~w(de)),
        candidate(twice, ~w(de fr)),
        candidate(next, ~w(de))
      ])

      Process.put(:sweep_settings, %{batch: 2})
      assert {:ok, %{enqueued: 3, candidates: 2}} = TranslationSweep.run_tick(Source)
      assert translate_jobs() == Enum.sort([{twice, "de"}, {twice, "fr"}, {next, "de"}])
    end

    test "a stored outcome without a reason reads as none" do
      {:ok, _} =
        PhoenixKit.Settings.update_json_setting_with_module(
          TranslationSweep.last_run_key(Source),
          %{"since" => "2026-09-22T00:00:00Z"},
          "ai"
        )

      assert TranslationSweep.last_run(Source) == nil
    end

    test "an outcome is written only when it changes, so repeats add no settings history" do
      key = TranslationSweep.last_run_key(Source)
      earlier = %{"reason" => "sweep_disabled", "since" => "2026-01-01T00:00:00Z"}
      {:ok, _} = PhoenixKit.Settings.update_json_setting_with_module(key, earlier, "ai")

      Process.put(:sweep_settings, %{enabled?: false})
      for _ <- 1..3, do: assert({:sweep_disabled, _} = TranslationSweep.run_tick(Source))
      assert TranslationSweep.last_run(Source) == earlier
      assert length(PhoenixKit.Settings.history(key)) == 1

      Process.put(:sweep_settings, %{})
      assert {:ok, _} = TranslationSweep.run_tick(Source)
      assert %{"reason" => "ok", "since" => since} = TranslationSweep.last_run(Source)
      refute since == earlier["since"]
      assert length(PhoenixKit.Settings.history(key)) == 2
    end

    test "a pair whose latest job was discarded is skipped, and does not hold up the rest" do
      [poisoned, next] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      translate_job!(poisoned, "de", "discarded")

      Process.put(:sweep_candidates, [candidate(poisoned, ~w(de fr)), candidate(next, ~w(de))])
      Process.put(:sweep_settings, %{max_in_flight: 2})

      assert {:ok, %{backed_off: 1, enqueued: 2}} = TranslationSweep.run_tick(Source)
      assert {poisoned, "fr"} in translate_jobs()
      assert {next, "de"} in translate_jobs()
      refute Enum.count(translate_jobs(), &(&1 == {poisoned, "de"})) > 1
    end

    test "a discard older than the window no longer holds the pair back" do
      uuid = Ecto.UUID.generate()

      translate_job!(uuid, "de", "discarded")
      |> Ecto.Changeset.change(
        discarded_at: DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      )
      |> TestRepo.update!()

      Process.put(:sweep_candidates, [candidate(uuid, ~w(de))])
      assert {:ok, %{backed_off: 0, enqueued: 1}} = TranslationSweep.run_tick(Source)
    end

    test "a later success clears the back-off" do
      uuid = Ecto.UUID.generate()
      translate_job!(uuid, "de", "discarded")
      translate_job!(uuid, "de", "completed")
      Process.put(:sweep_candidates, [candidate(uuid, ~w(de))])

      assert {:ok, %{backed_off: 0, enqueued: 1}} = TranslationSweep.run_tick(Source)
    end
  end

  describe "the chain" do
    test "keeps one tick waiting, and reschedule replaces it at the current interval" do
      assert {:ok, first} = TranslationSweep.ensure_scheduled(Source)
      assert {:ok, again} = TranslationSweep.ensure_scheduled(Source)
      assert again.id == first.id

      Process.put(:sweep_settings, %{interval_minutes: 5})
      assert {:ok, _} = TranslationSweep.reschedule(Source)

      # The waiting tick moved; nothing was cancelled or added.
      assert [%{id: id, state: "scheduled"}] = TestRepo.all(Oban.Job)
      assert id == first.id

      at = TranslationSweep.next_tick_at(Source)
      assert DateTime.diff(at, DateTime.utc_now()) in 290..300

      assert %{running?: false, next_tick_at: ^at} = TranslationSweep.status(Source)
    end

    test "reschedule never touches a tick that is already running" do
      assert {:ok, tick} = TranslationSweep.ensure_scheduled(Source)
      TestRepo.update_all(Oban.Job, set: [state: "executing"])

      Process.put(:sweep_settings, %{interval_minutes: 5})
      assert {:ok, successor} = TranslationSweep.reschedule(Source)

      assert TestRepo.get!(Oban.Job, tick.id).state == "executing"
      refute successor.id == tick.id
      assert DateTime.diff(TranslationSweep.next_tick_at(Source), DateTime.utc_now()) in 290..300
      assert TranslationSweep.status(Source).running?
    end

    test "reschedule starts a chain that has none waiting" do
      refute TranslationSweep.next_tick_at(Source)
      assert {:ok, _} = TranslationSweep.reschedule(Source)
      assert TranslationSweep.next_tick_at(Source)
    end

    test "a tick schedules its successor before sweeping" do
      Process.put(:sweep_settings, %{enabled?: false})
      assert TranslationSweep.perform(Source) == :ok
      assert TranslationSweep.next_tick_at(Source)
      assert %{"reason" => "sweep_disabled"} = TranslationSweep.last_run(Source)
    end
  end
end
