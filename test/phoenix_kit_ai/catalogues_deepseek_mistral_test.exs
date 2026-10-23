defmodule PhoenixKitAI.CataloguesDeepSeekMistralTest do
  @moduledoc """
  Two more providers whose own `/models` says what a model can do:
  DeepSeek (input and output modalities, context window, output limit) and
  Mistral (`capabilities.vision`, `capabilities.function_calling`, the
  context length). OpenAI, xAI and Z.ai list nothing of the kind and stay
  unknown unless declared. HTTP goes to `Req.Test` stubs only.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.ModelCapability
  alias PhoenixKitAI.OpenRouterClient
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @deepseek "https://api.deepseek.com/v1"
  @mistral "https://api.mistral.ai/v1"

  @deepseek_models [
    %{
      "id" => "deepseek-v4-flash",
      "object" => "model",
      "owned_by" => "deepseek",
      "input_modalities" => ["text", "image"],
      "output_modalities" => ["text"],
      "context_window" => 1_000_000,
      "max_output_tokens" => 384_000
    },
    %{
      "id" => "deepseek-v4-pro",
      "object" => "model",
      "owned_by" => "deepseek",
      "input_modalities" => ["text"],
      "output_modalities" => ["text"],
      "context_window" => 1_000_000,
      "max_output_tokens" => 384_000
    }
  ]

  @mistral_models [
    %{
      "id" => "pixtral-large-latest",
      "object" => "model",
      "name" => "pixtral-large-2411",
      "capabilities" => %{
        "completion_chat" => true,
        "function_calling" => true,
        "vision" => true
      },
      "max_context_length" => 131_072
    },
    %{
      "id" => "codestral-latest",
      "object" => "model",
      "capabilities" => %{
        "completion_chat" => true,
        "function_calling" => false,
        "vision" => false
      },
      "max_context_length" => 256_000
    },
    %{
      "id" => "mistral-embed",
      "object" => "model",
      "capabilities" => %{"completion_chat" => false, "function_calling" => false},
      "max_context_length" => 8_192
    }
  ]

  setup do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    {:ok, stub: stub}
  end

  describe "which providers have a catalogue" do
    test "DeepSeek and Mistral, by the provider key or by the host" do
      assert Capabilities.catalogue_kind("deepseek", nil) == :deepseek
      assert Capabilities.catalogue_kind(nil, "https://api.deepseek.com") == :deepseek
      assert Capabilities.catalogue_kind("custom", "https://api.deepseek.com/v1/") == :deepseek
      assert Capabilities.catalogue_kind("mistral", nil) == :mistral
      assert Capabilities.catalogue_kind(nil, @mistral) == :mistral
    end

    test "OpenAI, xAI and Z.ai list no capabilities" do
      assert Capabilities.catalogue_kind("openai", "https://api.openai.com/v1") == nil
      assert Capabilities.catalogue_kind("xai", "https://api.x.ai/v1") == nil
      assert Capabilities.catalogue_kind("zai", "https://api.z.ai/api/paas/v4") == nil
    end
  end

  describe "a DeepSeek row" do
    test "images in from the input modalities, images out from the output ones, the context window" do
      assert %Capabilities{
               vision: :yes,
               image_output: :no,
               file_input: :unknown,
               tools: :unknown,
               json_schema: :unknown,
               json: :unknown,
               context_length: 1_000_000,
               text_output: true
             } = Capabilities.from_deepseek(hd(@deepseek_models))

      assert %Capabilities{vision: :no} = Capabilities.from_deepseek(List.last(@deepseek_models))
    end

    test "a file input is documents; a row without modalities says nothing" do
      assert %Capabilities{file_input: :yes, image_output: :yes} =
               Capabilities.from_deepseek(%{
                 "input_modalities" => ["text", "file"],
                 "output_modalities" => ["text", "image"]
               })

      assert %Capabilities{vision: :unknown, image_output: :unknown, text_output: nil} =
               Capabilities.from_deepseek(%{"id" => "deepseek-chat"})
    end
  end

  describe "a Mistral row" do
    test "vision and function calling from its capabilities, the context length; documents unknown" do
      assert %Capabilities{
               vision: :yes,
               tools: :yes,
               file_input: :unknown,
               image_output: :unknown,
               json_schema: :unknown,
               context_length: 131_072,
               text_output: true
             } = Capabilities.from_mistral(hd(@mistral_models))

      assert %Capabilities{vision: :no, tools: :no} =
               Capabilities.from_mistral(Enum.at(@mistral_models, 1))
    end

    test "a model that does not chat is no text model; a row without capabilities says nothing" do
      assert %Capabilities{text_output: false} =
               Capabilities.from_mistral(List.last(@mistral_models))

      assert %Capabilities{vision: :unknown, tools: :unknown, text_output: nil} =
               Capabilities.from_mistral(%{"id" => "mistral-large-latest"})
    end
  end

  describe "the model list" do
    test "Mistral's chat picker excludes non-chat models and its vision picker uses capabilities",
         %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => @mistral_models}))
      opts = [base_url: @mistral, fallback_provider: "mistral"]

      assert {:ok, chat} = OpenRouterClient.fetch_models("key", opts ++ [model_type: :text])
      assert Enum.map(chat, & &1.id) == ["pixtral-large-latest", "codestral-latest"]

      assert {:ok, [%AIModel{id: "pixtral-large-latest"}]} =
               OpenRouterClient.fetch_models("key", opts ++ [model_type: :vision])

      assert {:ok, []} = OpenRouterClient.fetch_models("key", opts ++ [model_type: :image_gen])
    end

    test "a native chat capability takes precedence over an image-like model name", %{stub: stub} do
      row = %{
        "id" => "mistral-image-reader",
        "capabilities" => %{"completion_chat" => true, "vision" => true}
      }

      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => [row]}))

      assert {:ok, [%AIModel{id: "mistral-image-reader"}]} =
               OpenRouterClient.fetch_models("key",
                 base_url: @mistral,
                 fallback_provider: "mistral",
                 model_type: :text
               )
    end

    test "DeepSeek's native modalities drive chat, vision and image-generation pickers",
         %{stub: stub} do
      image_model = %{
        "id" => "deepseek-painter",
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["image"]
      }

      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => @deepseek_models ++ [image_model]}))
      opts = [base_url: @deepseek, fallback_provider: "deepseek"]

      assert {:ok, chat} = OpenRouterClient.fetch_models("key", opts ++ [model_type: :text])
      assert Enum.map(chat, & &1.id) == ["deepseek-v4-flash", "deepseek-v4-pro"]

      assert {:ok, [%AIModel{id: "deepseek-v4-flash"}]} =
               OpenRouterClient.fetch_models("key", opts ++ [model_type: :vision])

      assert {:ok, [%AIModel{id: "deepseek-painter"}]} =
               OpenRouterClient.fetch_models("key", opts ++ [model_type: :image_gen])
    end

    test "DeepSeek's models carry their capabilities, context and output limit", %{stub: stub} do
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:requested, conn.host, conn.request_path})
        Req.Test.json(conn, %{"object" => "list", "data" => @deepseek_models})
      end)

      {:ok, models} =
        OpenRouterClient.fetch_models("sk-deepseek",
          base_url: @deepseek,
          fallback_provider: "deepseek",
          model_type: :all
        )

      assert_received {:requested, "api.deepseek.com", "/v1/models"}

      assert %AIModel{
               context_length: 1_000_000,
               max_completion_tokens: 384_000,
               capabilities: %Capabilities{vision: :yes}
             } = Enum.find(models, &(&1.id == "deepseek-v4-flash"))
    end

    test "Mistral's models carry their capabilities and context", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"object" => "list", "data" => @mistral_models}))

      {:ok, models} =
        OpenRouterClient.fetch_models("mistral-key",
          base_url: @mistral,
          fallback_provider: "mistral",
          model_type: :all
        )

      assert %AIModel{
               context_length: 131_072,
               capabilities: %Capabilities{vision: :yes, tools: :yes}
             } =
               Enum.find(models, &(&1.id == "pixtral-large-latest"))
    end

    test "an xAI model stays unknown", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => [%{"id" => "grok-4"}]}))

      {:ok, [model]} =
        OpenRouterClient.fetch_models("xai-key",
          base_url: "https://api.x.ai/v1",
          fallback_provider: "xai",
          model_type: :all
        )

      assert %AIModel{capabilities: %Capabilities{vision: :unknown, file_input: :unknown}} = model
    end
  end

  describe "recommendations" do
    test "a model of these catalogues is unpriced and its cost is not counted" do
      catalogue = [
        %{
          base_url: @deepseek,
          kind: :deepseek,
          integration_uuid: nil,
          models: [{"deepseek-v4-flash", Capabilities.from_deepseek(hd(@deepseek_models))}]
        }
      ]

      assert %{rows: [row]} =
               PhoenixKitAI.Recommendations.cheapest("plain.task", catalogue: catalogue)

      assert %{provider: :deepseek, price_known?: false, price_per_call: nil} = row
      assert :cost_not_reported in row.notes
    end
  end

  describe "the cache" do
    test "reads both catalogues and snapshots the endpoints' models", %{stub: stub} do
      for {provider, base_url, model} <- [
            {"deepseek", @deepseek, "deepseek-v4-flash"},
            {"mistral", @mistral, "pixtral-large-latest"}
          ] do
        {:ok, _} =
          PhoenixKitAI.create_endpoint(%{
            name: "#{provider} #{System.unique_integer([:positive])}",
            provider: provider,
            base_url: base_url,
            model: model,
            api_key: "#{provider}-test-key"
          })
      end

      Req.Test.stub(stub, fn conn ->
        case conn.host do
          "api.deepseek.com" -> Req.Test.json(conn, %{"data" => @deepseek_models})
          "api.mistral.ai" -> Req.Test.json(conn, %{"data" => @mistral_models})
        end
      end)

      pid =
        start_supervised!(
          {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
        )

      Req.Test.allow(stub, self(), pid)
      _ = :sys.get_state(pid)

      assert :ok = Capabilities.refresh()

      assert %Capabilities{vision: :yes, context_length: 1_000_000} =
               Capabilities.lookup(@deepseek, "deepseek-v4-flash")

      assert %Capabilities{vision: :no} = Capabilities.lookup(@deepseek, "deepseek-v4-pro")
      assert %Capabilities{tools: :no} = Capabilities.lookup(@mistral, "codestral-latest")

      assert [
               %ModelCapability{base_url: @deepseek, model: "deepseek-v4-flash", vision: "yes"},
               %ModelCapability{base_url: @mistral, model: "pixtral-large-latest", tools: "yes"}
             ] = TestRepo.all(from(c in ModelCapability, order_by: c.base_url))
    end
  end
end
