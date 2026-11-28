defmodule PhoenixKitAI.TranslationPinsTest do
  @moduledoc """
  A translation pinned to the source it was made from
  (`PhoenixKitAI.Translations` "Pinned to the source they were made from"):
  the worker pins every persisted translation, the adapter gets the hash, and
  `stale?/5` / `stale_languages/4` find translations of an older source.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.Test.FakeTranslatableValid
  alias PhoenixKitAI.{TranslateWorker, Translations}

  describe "pins, by hand" do
    test "stale? is :unknown without a pin, then false for the same source, true for another" do
      uuid = Ecto.UUID.generate()
      source = %{"title" => "Hall A", "body" => "Seats 40"}

      assert Translations.stale?("page", uuid, "ru", source) == :unknown

      assert {:ok, _} =
               Translations.pin_translation("page", uuid, "ru", source, source_lang: "en")

      refute Translations.stale?("page", uuid, "ru", source)
      # Whitespace is not a change of source.
      refute Translations.stale?("page", uuid, "ru", %{
               "title" => " Hall  A",
               "body" => "Seats 40"
             })

      assert Translations.stale?("page", uuid, "ru", %{"title" => "Hall A", "body" => "Seats 45"})

      assert %{source_hash: "sha256:" <> _, source_lang: "en", translated_at: %DateTime{}} =
               Translations.translation_pin("page", uuid, "ru")
    end

    test "stale_languages lists the pinned languages made from another source" do
      uuid = Ecto.UUID.generate()
      old = %{"body" => "v1"}
      new = %{"body" => "v2"}

      {:ok, _} = Translations.pin_translation("page", uuid, "ru", old)
      {:ok, _} = Translations.pin_translation("page", uuid, "et", new)
      {:ok, _} = Translations.pin_translation("page", uuid, "de", old)
      # Another resource and another type are not this one's.
      {:ok, _} = Translations.pin_translation("page", Ecto.UUID.generate(), "fr", old)
      {:ok, _} = Translations.pin_translation("post", uuid, "fr", old)

      assert Translations.stale_languages("page", uuid, new) == ["de", "ru"]
      assert Translations.stale_languages("page", uuid, old) == ["et"]
      assert Map.keys(Translations.translation_pins("page", uuid)) == ["de", "et", "ru"]
    end

    test "a host's own hash is the source, and scopes keep their own pins" do
      uuid = Ecto.UUID.generate()
      {:ok, _} = Translations.pin_translation("page", uuid, "ru", {:hash, "crawl:abc"})
      {:ok, _} = Translations.pin_translation("page", uuid, "ru", {:hash, "crawl:v2"}, scope: "2")

      refute Translations.stale?("page", uuid, "ru", {:hash, "crawl:abc"})
      assert Translations.stale?("page", uuid, "ru", {:hash, "crawl:abc"}, scope: "2")
      assert Translations.stale_languages("page", uuid, {:hash, "crawl:v2"}) == ["ru"]
      assert Translations.stale_languages("page", uuid, {:hash, "crawl:v2"}, scope: 2) == []
    end
  end

  describe "enqueue/1" do
    test "carries source_hash only when given" do
      start_supervised!({Oban, name: Oban, repo: PhoenixKitAI.Test.Repo, testing: :manual})

      base = %{
        resource_type: "page",
        resource_uuid: Ecto.UUID.generate(),
        endpoint_uuid: Ecto.UUID.generate(),
        prompt_uuid: Ecto.UUID.generate(),
        source_lang: "en",
        target_lang: "ru"
      }

      assert {:error, {:invalid, [:source_hash]}} =
               Translations.enqueue(Map.put(base, :source_hash, String.duplicate("é", 51)))

      assert {:ok, %{conflict?: false}} = Translations.enqueue(base)

      assert {:ok, %{conflict?: false}} =
               Translations.enqueue(%{base | target_lang: "et"} |> Map.put(:source_hash, "h1"))

      args =
        PhoenixKit.RepoHelper.repo().all(Oban.Job)
        |> Enum.filter(&(&1.args["resource_uuid"] == base.resource_uuid))
        |> Map.new(&{&1.args["target_lang"], &1.args})

      refute Map.has_key?(args["ru"], "source_hash")
      assert args["et"]["source_hash"] == "h1"
    end
  end

  describe "the worker" do
    defmodule RecordingAdapter do
      @moduledoc false
      def put_translation(resource, _lang, _fields, opts) do
        send(self(), {:put_opts, opts})
        {:ok, resource}
      end
    end

    setup do
      PhoenixKitAI.enable_system()
      :ok = PhoenixKit.ModuleRegistry.register(FakeTranslatableValid)

      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      {:ok, _} =
        PhoenixKit.Settings.update_json_setting(
          "integration:openrouter:default",
          %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
        )

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "EP-pins-#{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "anthropic/claude-3-haiku",
          api_key: "sk-test-key"
        })

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Prompt-pins-#{System.unique_integer([:positive])}",
          content: "Translate {{name}} from {{SourceLanguage}} to {{TargetLanguage}}."
        })

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "---NAME---\nBonjour"}}
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
        })
      end)

      on_exit(fn ->
        PhoenixKit.ModuleRegistry.unregister(FakeTranslatableValid)
        Application.delete_env(:phoenix_kit_ai, :req_options)
      end)

      %{endpoint: endpoint, prompt: prompt}
    end

    defp job(endpoint, prompt, uuid, extra \\ %{}) do
      %Oban.Job{
        args:
          Map.merge(
            %{
              "resource_type" => FakeTranslatableValid.resource_type(),
              "resource_uuid" => uuid,
              "endpoint_uuid" => endpoint.uuid,
              "prompt_uuid" => prompt.uuid,
              "source_lang" => "en",
              "target_lang" => "fr"
            },
            extra
          ),
        attempt: 1,
        max_attempts: 3
      }
    end

    test "pins a persisted translation to a hash of the fields it sent", %{
      endpoint: endpoint,
      prompt: prompt
    } do
      uuid = Ecto.UUID.generate()
      type = FakeTranslatableValid.resource_type()
      assert :ok = TranslateWorker.perform(job(endpoint, prompt, uuid))

      source = %{"name" => "Hello world"}
      assert %{source_lang: "en"} = Translations.translation_pin(type, uuid, "fr")
      refute Translations.stale?(type, uuid, "fr", source)
      assert Translations.stale?(type, uuid, "fr", %{"name" => "Hello there"})
    end

    test "a job's source_hash is the pin, and the adapter is handed it", %{
      endpoint: endpoint,
      prompt: prompt
    } do
      uuid = Ecto.UUID.generate()
      type = FakeTranslatableValid.resource_type()

      assert :ok =
               TranslateWorker.perform(job(endpoint, prompt, uuid, %{"source_hash" => "page:v7"}))

      assert %{source_hash: "page:v7"} = Translations.translation_pin(type, uuid, "fr")

      ctx = %{
        adapter: RecordingAdapter,
        resource: %{},
        target: "fr",
        actor: nil,
        source_hash: "h"
      }

      assert {:ok, _} = TranslateWorker.safe_put_translation(ctx, %{"name" => "x"}, %{})
      assert_received {:put_opts, opts}
      assert opts[:source_hash] == "h"

      ctx = Map.delete(ctx, :source_hash)
      assert {:ok, _} = TranslateWorker.safe_put_translation(ctx, %{}, %{"name" => "Hello world"})
      assert_received {:put_opts, opts}
      assert opts[:source_hash] == Translations.source_hash(%{"name" => "Hello world"})
    end
  end
end
