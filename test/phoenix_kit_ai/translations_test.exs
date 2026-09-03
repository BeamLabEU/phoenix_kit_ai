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

  The end-to-end `enqueue`/`TranslateWorker` round-trip needs a seeded
  endpoint + prompt and lives in each consumer's worker test.
  """

  # async: false — the global `phoenix_kit:ai_translation` topic is shared, so
  # serial runs keep one test's broadcast out of another's mailbox.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKitAI.Test.Repo, as: TestRepo
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
