defmodule PhoenixKitAI.ObanPrefixTest do
  @moduledoc """
  An install with a named schema (`mix phoenix_kit.install --prefix`) keeps
  Oban's tables in that schema and writes `prefix:` into the host's Oban config,
  but neither `Oban.Job` nor the `"oban_jobs"` source carries a prefix of its own.
  A read that leaves it out finds another table or none. Most of these reads fail
  open, so the symptom is not an error: the translation dedupe stops working and
  the same translation is billed twice.

  Here Oban runs in a schema of its own, with `public.oban_jobs` left empty, so a
  read that goes to the wrong table sees nothing.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.ObanQuery
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.Translations
  alias PhoenixKitAI.TranslationSweep

  @prefix "pk_ai_oban_prefix"

  defmodule Source do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 1
    @behaviour PhoenixKitAI.TranslationSweep

    @impl Oban.Worker
    def perform(_job), do: PhoenixKitAI.TranslationSweep.perform(__MODULE__)

    @impl PhoenixKitAI.TranslationSweep
    def sweep_key, do: "prefix_source"

    @impl PhoenixKitAI.TranslationSweep
    def sweep_settings do
      Map.merge(
        %{enabled?: true, interval_minutes: 30, languages: ["de"], source_language: "en"},
        Process.get(:sweep_settings, %{})
      )
    end

    @impl PhoenixKitAI.TranslationSweep
    def sweep_ready(_trigger), do: :ok

    @impl PhoenixKitAI.TranslationSweep
    def sweep_resource_types, do: ["prefix_thing"]

    @impl PhoenixKitAI.TranslationSweep
    def sweep_candidates(_source_lang, _targets), do: Process.get(:sweep_candidates, [])

    @impl PhoenixKitAI.TranslationSweep
    def sweep_prompts, do: {:ok, %{"prefix_thing" => Ecto.UUID.generate()}}
  end

  setup context do
    pid = Sandbox.start_owner!(TestRepo, shared: not context[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Both roll back with the sandbox.
    TestRepo.query!("CREATE SCHEMA #{@prefix}")
    TestRepo.query!("CREATE TABLE #{@prefix}.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)")

    start_oban(@prefix)

    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Prefix-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      })

    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module(
        "ai_translation_endpoint_uuid",
        endpoint.uuid,
        "ai"
      )

    :ok
  end

  # What `testing: :manual` sets, by hand: that mode also verifies the migrations
  # outside the sandbox, where a schema made in this test's transaction is not
  # visible, and `:disabled` skips the check.
  defp start_oban(prefix) do
    start_supervised!(
      {Oban,
       name: Oban,
       repo: TestRepo,
       prefix: prefix,
       testing: :disabled,
       queues: [],
       plugins: [],
       peer: false,
       stage_interval: :infinity,
       notifier: Oban.Notifiers.Isolated}
    )
  end

  defp translate_job!(uuid, state) do
    {:ok, job} =
      %{
        resource_type: "prefix_thing",
        resource_uuid: uuid,
        endpoint_uuid: Ecto.UUID.generate(),
        prompt_uuid: Ecto.UUID.generate(),
        source_lang: "en",
        target_lang: "de"
      }
      |> PhoenixKitAI.TranslateWorker.new()
      |> Oban.insert()

    from(j in Oban.Job, where: j.id == ^job.id)
    |> TestRepo.update_all(
      [set: [state: state, discarded_at: if(state == "discarded", do: DateTime.utc_now())]],
      prefix: @prefix
    )

    job
  end

  defp candidate(uuid), do: %{resource_type: "prefix_thing", uuid: uuid, languages: ["de"]}

  defp jobs_in(prefix), do: TestRepo.aggregate(Oban.Job, :count, prefix: prefix)

  test "the setup holds: a job goes to the named schema, not public" do
    translate_job!(Ecto.UUID.generate(), "available")

    assert jobs_in(@prefix) == 1
    assert jobs_in("public") == 0
  end

  test "a second enqueue of one translation sees the first job" do
    params = %{
      resource_type: "catalogue_item",
      resource_uuid: Ecto.UUID.generate(),
      endpoint_uuid: Ecto.UUID.generate(),
      prompt_uuid: Ecto.UUID.generate(),
      source_lang: "en",
      target_lang: "de"
    }

    assert {:ok, %{conflict?: false}} = Translations.enqueue(params)
    assert {:ok, %{conflict?: true}} = Translations.enqueue(params)
    assert jobs_in(@prefix) == 1
  end

  test "the sweep's ceiling counts the jobs in flight" do
    translate_job!(Ecto.UUID.generate(), "executing")
    Process.put(:sweep_candidates, [candidate(Ecto.UUID.generate())])
    Process.put(:sweep_settings, %{max_in_flight: 1})

    assert {:ceiling_reached, %{in_flight: 1}} = TranslationSweep.run_tick(Source)
  end

  test "the sweep holds back a pair whose latest job was discarded" do
    uuid = Ecto.UUID.generate()
    translate_job!(uuid, "discarded")
    Process.put(:sweep_candidates, [candidate(uuid)])

    assert {:ok, %{enqueued: 0, backed_off: 1}} = TranslationSweep.run_tick(Source)
  end

  test "the sweep's chain is read from and moved in the named schema" do
    assert {:ok, tick} = TranslationSweep.ensure_scheduled(Source)

    assert %DateTime{} = waiting = TranslationSweep.next_tick_at(Source)
    refute TranslationSweep.running?(Source)

    Process.put(:sweep_settings, %{interval_minutes: 5})
    assert {:ok, _} = TranslationSweep.reschedule(Source)
    assert DateTime.compare(TranslationSweep.next_tick_at(Source), waiting) == :lt

    from(j in Oban.Job, where: j.id == ^tick.id)
    |> TestRepo.update_all([set: [state: "executing"]], prefix: @prefix)

    assert TranslationSweep.running?(Source)
  end

  describe "ObanQuery.prefix/0" do
    test "is the running instance's prefix" do
      assert ObanQuery.prefix() == @prefix
    end

    test "is nil for an instance that resolves through the search path" do
      stop_supervised!(Oban)
      start_oban(false)

      assert ObanQuery.prefix() == nil
    end

    test "is nil with no instance running" do
      stop_supervised!(Oban)

      assert ObanQuery.prefix() == nil
    end
  end
end
