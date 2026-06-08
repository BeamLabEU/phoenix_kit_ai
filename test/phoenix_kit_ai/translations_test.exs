defmodule PhoenixKitAI.TranslationsTest do
  @moduledoc """
  Unit coverage for `PhoenixKitAI.Translations` orchestration that
  doesn't need a live `PhoenixKitAI` plugin or a configured endpoint/prompt:

    * `missing_languages/3` — pure set difference (primary excluded).
    * availability/list helpers degrade to safe defaults when the plugin
      isn't loaded (core CI doesn't load `PhoenixKitAI`).
    * `broadcast/3` payload scoping — the FULL payload (with `:fields`) goes
      ONLY to the per-resource topic; the global + adapter topics get a
      content-free summary. Pins the payload-minimal fix.

  The end-to-end `enqueue`/`TranslateWorker` round-trip needs a seeded
  endpoint + prompt and lives in each consumer's worker test.
  """

  # async: false — the global `phoenix_kit:ai_translation` topic is shared, so
  # serial runs keep one test's broadcast out of another's mailbox.
  use ExUnit.Case, async: false

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
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

  describe "availability when the AI plugin is absent (core CI)" do
    test "available?/0 is false" do
      refute Translations.available?()
    end

    test "list_endpoints/0 and list_prompts/0 degrade to []" do
      assert Translations.list_endpoints() == []
      assert Translations.list_prompts() == []
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
