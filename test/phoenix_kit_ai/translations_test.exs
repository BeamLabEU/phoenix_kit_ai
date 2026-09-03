defmodule PhoenixKitAI.TranslationsTest do
  @moduledoc """
  Unit coverage for `PhoenixKitAI.Translations` orchestration that
  doesn't need a live `PhoenixKitAI` plugin or a configured endpoint/prompt,
  plus one `:integration` describe block that DOES need the database:

    * `missing_languages/3` — pure set difference (primary excluded).
    * availability/list helpers, checked against the two states this suite
      can actually produce: disabled (no endpoint) and enabled (with an
      endpoint). A prior version of this block asserted the
      disabled/no-endpoint values under a describe titled "the AI plugin
      is absent" — a *third* state, module-not-loaded, that this test VM
      can never reach (this is `PhoenixKitAI`'s own suite, so
      `function_exported?(PhoenixKitAI, :ask_with_prompt, 4)` is always
      true here). That assertion happened to hold in three unrelated
      states (module absent, database absent, database present-but-
      disabled) and so proved nothing about any one of them. The genuine
      "plugin absent" case belongs in core `phoenix_kit`'s suite, which
      can actually omit this dependency.
    * `broadcast/3` payload scoping — the FULL payload (with `:fields`) goes
      ONLY to the per-resource topic; the global + adapter topics get a
      content-free summary. Pins the payload-minimal fix.
    * `default_endpoint_uuid/0` — characterization of the documented
      resolution order (explicit setting > last successful chat request on
      a still-enabled endpoint > first enabled non-reasoning chat endpoint >
      first enabled endpoint > nil). A safety net, not new behavior: a
      mutation audit found this had zero coverage, and flipping
      `reasoning_model?/1` to always return `false` (which lets a reasoning
      endpoint win the "preferred" slot the `---FIELD---` parser needs a
      standard model for) left the full suite green.
    * `enqueue/1` / `enqueue_all_missing/2` / the `job_in_flight?/1` dedup
      query — per-language and per-scope identity. Same mutation-audit
      finding: dropping the `target_lang` clause from the dedup query makes
      one in-flight job block every OTHER target language for the same
      resource, and the suite stayed green.

  The end-to-end `enqueue`/`TranslateWorker` round-trip (a real AI call)
  needs a seeded endpoint + prompt and lives in each consumer's worker
  test; the dedup/enqueue tests below insert real `TranslateWorker` jobs
  via a locally-supervised `Oban` (manual testing mode — nothing executes)
  but never perform them.
  """

  # async: false — the global `phoenix_kit:ai_translation` topic is shared, so
  # serial runs keep one test's broadcast out of another's mailbox.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitAI.Translations

  describe "missing_languages/3" do
    test "returns enabled non-primary codes that have no translation yet" do
      assert Translations.missing_languages(["en", "es", "fr", "de"], "en", ["es"]) ==
               ["fr", "de"]
    end

    test "excludes the primary language even if it's not in existing" do
      refute "en" in Translations.missing_languages(["en", "es"], "en", [])
    end

    test "everything translated → empty" do
      assert Translations.missing_languages(["en", "es", "fr"], "en", ["es", "fr"]) == []
    end

    test "preserves the enabled-codes order" do
      assert Translations.missing_languages(["de", "fr", "es"], "en", []) == ["de", "fr", "es"]
    end
  end

  describe "availability: disabled vs enabled-with-endpoint" do
    @describetag :integration

    # Manual sandbox checkout (not `use PhoenixKitAI.DataCase`) so this file
    # can keep its pure `missing_languages/3` and `broadcast/3` tests
    # ungated by `:integration` while only this describe block touches the
    # database. Mirrors `PhoenixKitAI.DataCase`'s own setup exactly.
    setup context do
      pid = Sandbox.start_owner!(TestRepo, shared: not context[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
      :ok
    end

    test "disabled: available?/0 is false, list_endpoints/0 and list_prompts/0 are []" do
      {:ok, _} = PhoenixKitAI.disable_system()

      refute Translations.available?()
      assert Translations.list_endpoints() == []
      assert Translations.list_prompts() == []
    end

    test "enabled with an endpoint: available?/0 is true, list_endpoints/0 includes it" do
      {:ok, _} = PhoenixKitAI.enable_system()

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "EP-#{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      assert Translations.available?()
      assert {endpoint.uuid, endpoint.name} in Translations.list_endpoints()
    end
  end

  describe "default_endpoint_uuid/0 resolution order" do
    @describetag :integration

    # Same manual sandbox setup as "availability" above, plus enabling the
    # AI system — `preferred_endpoint_uuid/0` and `first_endpoint_uuid/0`
    # both route through `list_endpoints/0`, which returns `[]` (gated by
    # `PhoenixKitAI.enabled?/0`) while the system is off.
    setup context do
      pid = Sandbox.start_owner!(TestRepo, shared: not context[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
      {:ok, _} = PhoenixKitAI.enable_system()
      :ok
    end

    defp fixture_ep(attrs \\ %{}) do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(
          Map.merge(
            %{
              name: "Reso-Endpoint-#{System.unique_integer([:positive])}",
              provider: "openrouter",
              model: "anthropic/claude-3-haiku",
              api_key: "sk-test-key"
            },
            Map.new(attrs)
          )
        )

      endpoint
    end

    defp successful_chat_request!(endpoint, attrs \\ %{}) do
      {:ok, request} =
        PhoenixKitAI.create_request(
          Map.merge(
            %{
              endpoint_uuid: endpoint.uuid,
              endpoint_name: endpoint.name,
              model: endpoint.model,
              request_type: "chat",
              status: "success"
            },
            Map.new(attrs)
          )
        )

      request
    end

    # `phoenix_kit_ai_requests.inserted_at` is second-precision, so two
    # requests created back-to-back in the same test can collide on
    # "most recent". Stamp an explicit time so ordering is deterministic
    # (same pattern as `coverage_test.exs`).
    defp stamp!(request, seconds_ago) do
      ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-seconds_ago)

      from(r in PhoenixKitAI.Request, where: r.uuid == ^request.uuid)
      |> TestRepo.update_all(set: [inserted_at: ts])

      :ok
    end

    test "no endpoints at all -> nil" do
      assert Translations.default_endpoint_uuid() == nil
    end

    test "1) the explicit setting wins over history and existing endpoints" do
      reasoning_ep = fixture_ep(reasoning_enabled: true)
      other_ep = fixture_ep()
      stamp!(successful_chat_request!(reasoning_ep), 1)

      Settings.update_setting_with_module("ai_translation_endpoint_uuid", other_ep.uuid, "ai")

      assert Translations.default_endpoint_uuid() == other_ep.uuid
    end

    test "2) with no setting, the most recent successful chat request wins — even a reasoning endpoint" do
      standard_ep = fixture_ep()
      reasoning_ep = fixture_ep(reasoning_enabled: true)

      stamp!(successful_chat_request!(standard_ep), 60)
      stamp!(successful_chat_request!(reasoning_ep), 1)

      assert Translations.default_endpoint_uuid() == reasoning_ep.uuid
    end

    test "last-used ignores a non-'success' request even if it is the most recent" do
      good_ep = fixture_ep()
      bad_ep = fixture_ep()

      stamp!(successful_chat_request!(good_ep), 60)
      stamp!(successful_chat_request!(bad_ep, status: "error"), 1)

      assert Translations.default_endpoint_uuid() == good_ep.uuid
    end

    test "last-used ignores a non-'chat' request_type even if it is the most recent" do
      chat_ep = fixture_ep()
      embed_ep = fixture_ep()

      stamp!(successful_chat_request!(chat_ep), 60)
      stamp!(successful_chat_request!(embed_ep, request_type: "embedding"), 1)

      assert Translations.default_endpoint_uuid() == chat_ep.uuid
    end

    test "last-used ignores a request whose endpoint is no longer enabled, falling back to preferred" do
      disabled_ep = fixture_ep()
      stamp!(successful_chat_request!(disabled_ep), 1)
      {:ok, disabled_ep} = PhoenixKitAI.update_endpoint(disabled_ep, %{enabled: false})
      refute disabled_ep.enabled

      fallback_ep = fixture_ep()

      assert Translations.default_endpoint_uuid() == fallback_ep.uuid
    end

    test "3) with no history, the first enabled NON-reasoning chat endpoint wins, regardless of list order" do
      # The reasoning endpoint sorts FIRST (lower sort_order) — a correct
      # `reasoning_model?/1` must still skip over it.
      reasoning_ep = fixture_ep(reasoning_enabled: true, sort_order: 0)
      standard_ep = fixture_ep(sort_order: 1)

      assert Translations.default_endpoint_uuid() == standard_ep.uuid
      refute Translations.default_endpoint_uuid() == reasoning_ep.uuid
    end

    test "4) with no history and no standard chat endpoint, falls back to the first enabled endpoint" do
      reasoning_ep = fixture_ep(reasoning_enabled: true)

      assert Translations.default_endpoint_uuid() == reasoning_ep.uuid
    end

    # Step 1 of the order does NOT validate what the setting points at — the
    # value is returned whether or not that endpoint still exists or is still
    # enabled. Pinned deliberately: consumers that need a usable endpoint
    # (the catalogue sweep is the first) have to pair this call with an
    # availability check of their own, and that obligation only stays visible
    # if the quirk is written down as a test.
    test "the explicit setting is returned unvalidated: a dangling uuid still wins" do
      live_ep = fixture_ep()
      dangling = Ecto.UUID.generate()

      Settings.update_setting_with_module("ai_translation_endpoint_uuid", dangling, "ai")

      assert Translations.default_endpoint_uuid() == dangling
      refute Translations.default_endpoint_uuid() == live_ep.uuid
    end

    test "the explicit setting is returned unvalidated: a DISABLED endpoint still wins" do
      {:ok, disabled_ep} = PhoenixKitAI.update_endpoint(fixture_ep(), %{enabled: false})
      _live_ep = fixture_ep()

      Settings.update_setting_with_module("ai_translation_endpoint_uuid", disabled_ep.uuid, "ai")

      assert Translations.default_endpoint_uuid() == disabled_ep.uuid
    end
  end

  describe "enqueue/1 + job_in_flight?/1 dedup identity" do
    @describetag :integration

    setup context do
      pid = Sandbox.start_owner!(TestRepo, shared: not context[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      # `TranslateWorker` jobs are real Oban rows (`enqueue/1` calls
      # `Oban.insert/1`), but nothing in this host app boots an Oban
      # supervisor (see `translations.ex` moduledoc: the plugin has no
      # `mod:`/supervisor of its own). `testing: :manual` disables queues
      # and plugins — jobs are inserted, never performed.
      start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

      :ok
    end

    defp base_enqueue_params(overrides \\ %{}) do
      Map.merge(
        %{
          resource_type: "catalogue_item",
          resource_uuid: Ecto.UUID.generate(),
          endpoint_uuid: Ecto.UUID.generate(),
          prompt_uuid: Ecto.UUID.generate(),
          source_lang: "en",
          target_lang: "de"
        },
        Map.new(overrides)
      )
    end

    test "an in-flight job for one target language does NOT suppress a different target language for the same resource" do
      params = base_enqueue_params()

      assert {:ok, %{conflict?: false}} = Translations.enqueue(params)
      assert {:ok, %{conflict?: false}} = Translations.enqueue(%{params | target_lang: "fr"})
    end

    test "an in-flight job for the SAME target language reports a conflict" do
      params = base_enqueue_params()

      assert {:ok, %{conflict?: false}} = Translations.enqueue(params)
      assert {:ok, %{conflict?: true}} = Translations.enqueue(params)
    end

    test "resource_scope participates in identity: different scopes don't conflict, same scope does" do
      params = base_enqueue_params(resource_scope: "v1")

      assert {:ok, %{conflict?: false}} = Translations.enqueue(params)
      assert {:ok, %{conflict?: false}} = Translations.enqueue(%{params | resource_scope: "v2"})
      assert {:ok, %{conflict?: true}} = Translations.enqueue(params)
    end

    test "nil resource_scope: an unscoped job and an explicit nil-scope job dedup against each other" do
      unscoped = base_enqueue_params() |> Map.delete(:resource_scope)

      assert {:ok, %{conflict?: false}} = Translations.enqueue(unscoped)

      assert {:ok, %{conflict?: true}} =
               Translations.enqueue(Map.put(unscoped, :resource_scope, nil))
    end

    test "resource_scope is normalized before dedup: integer 2 and string \"2\" are one slice" do
      params = base_enqueue_params(resource_scope: 2)

      assert {:ok, %{conflict?: false}} = Translations.enqueue(params)
      assert {:ok, %{conflict?: true}} = Translations.enqueue(%{params | resource_scope: "2"})
    end

    # The `nil`-scope clause matches `->>` returning NULL, which covers a JSON
    # null AND an absent key. The test above only produces the first form
    # (`to_args/1` always writes the key); this one produces the second — a
    # job enqueued by a build that predates `resource_scope` and is still in
    # flight during an upgrade. It must still block a duplicate.
    test "a legacy in-flight job with no resource_scope key at all still dedups" do
      params = base_enqueue_params() |> Map.delete(:resource_scope)

      legacy_args =
        Map.new(
          [
            :resource_type,
            :resource_uuid,
            :endpoint_uuid,
            :prompt_uuid,
            :source_lang,
            :target_lang
          ],
          &{Atom.to_string(&1), Map.fetch!(params, &1)}
        )

      {:ok, job} = legacy_args |> TranslateWorker.new() |> Oban.insert()
      refute Map.has_key?(job.args, "resource_scope")

      assert {:ok, %{conflict?: true}} = Translations.enqueue(params)
    end

    test "enqueue_all_missing/2 enqueues every missing language independently, even with a pre-existing in-flight job for one of them" do
      base = base_enqueue_params() |> Map.delete(:target_lang)

      # Simulate a job already in flight for "de" before the bulk call.
      assert {:ok, %{conflict?: false}} = Translations.enqueue(Map.put(base, :target_lang, "de"))

      assert {:ok, result} = Translations.enqueue_all_missing(base, ["de", "fr", "es"])

      assert result.errors == []
      assert result.conflicts == 1
      assert result.enqueued == 2
      assert Enum.sort(result.in_flight) == Enum.sort(["de", "fr", "es"])

      # "fr" and "es" genuinely got their own jobs — a real dedup bug (the
      # target_lang clause dropped from `job_in_flight?/1`) would have
      # reported them as conflicts against the pre-existing "de" job
      # instead of inserting them, and this second round would then find
      # only "de" already in flight.
      assert {:ok, %{conflict?: true}} = Translations.enqueue(Map.put(base, :target_lang, "fr"))
      assert {:ok, %{conflict?: true}} = Translations.enqueue(Map.put(base, :target_lang, "es"))
    end
  end

  describe "broadcast/3 payload scoping" do
    test "the per-resource topic receives the FULL payload (with :fields)" do
      uuid = "00000000-0000-0000-0000-0000000000a1"
      :ok = Translations.subscribe("catalogue_item", uuid)

      Translations.broadcast(:translation_completed, %{
        resource_type: "catalogue_item",
        resource_uuid: uuid,
        target_lang: "es",
        fields: %{"name" => "Hola"}
      })

      assert_receive {:ai_translation, :translation_completed, payload}
      assert payload.fields == %{"name" => "Hola"}
      assert payload.target_lang == "es"
    end

    test "the global topic receives a SUMMARY without :fields" do
      uuid = "00000000-0000-0000-0000-0000000000a2"
      :ok = Translations.subscribe()

      Translations.broadcast(:translation_completed, %{
        resource_type: "catalogue_item",
        resource_uuid: uuid,
        target_lang: "es",
        fields: %{"name" => "Hola"}
      })

      assert_receive {:ai_translation, :translation_completed, payload}
      refute Map.has_key?(payload, :fields)
      # The non-content fields still ride along for monitors.
      assert payload.resource_type == "catalogue_item"
      assert payload.target_lang == "es"
    end

    test "extra (adapter) topics also get the content-free summary" do
      extra = "phoenix_kit:test_adapter_topic"
      :ok = PubSubManager.subscribe(extra)

      Translations.broadcast(
        :translation_completed,
        %{
          resource_type: "catalogue_item",
          resource_uuid: "00000000-0000-0000-0000-0000000000a3",
          target_lang: "es",
          fields: %{"name" => "Hola"}
        },
        [extra]
      )

      assert_receive {:ai_translation, :translation_completed, payload}
      refute Map.has_key?(payload, :fields)
    end
  end
end
