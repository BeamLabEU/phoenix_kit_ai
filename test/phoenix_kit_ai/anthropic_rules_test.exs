defmodule PhoenixKitAI.AnthropicRulesTest do
  @moduledoc """
  What Anthropic needs beyond the OpenAI-compatible shape, ported from
  BeamLabEU/phoenix_kit_ai#42 into this module's own code: its `/models`
  request carries the headers the core registry declares for the provider
  (with `anthropic-version` as a fallback), a model from Claude Opus 4.7 on
  gets neither `temperature` nor `top_p` even when the caller sets them
  (the cases #42 checked against live models), and a model whose listing
  names no price shows none instead of $0.00. HTTP goes to `Req.Test`
  stubs only.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.OpenRouterClient

  @anthropic "https://api.anthropic.com/v1"

  defmodule RegistryProvider do
    @moduledoc false
    # Contributes an `anthropic` provider to the core registry, as core
    # releases that know Anthropic declare it.
    def integration_providers do
      [
        %{
          key: "anthropic",
          name: "Anthropic",
          description: "Claude",
          icon: "hero-sparkles",
          auth_type: :api_key,
          oauth_config: nil,
          setup_fields: [],
          capabilities: [:ai_completions],
          base_url: "https://api.anthropic.com/v1",
          validation: %{
            url: "https://api.anthropic.com/v1/models",
            method: :get,
            auth_header: "x-api-key",
            auth_prefix: "",
            extra_headers: [
              {"anthropic-version", "2099-01-01"},
              {"anthropic-beta", "models-listing"}
            ]
          }
        }
      ]
    end
  end

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  describe "sampling (the cases of #42)" do
    test "models from Claude Opus 4.7 on take neither temperature nor top_p" do
      for id <-
            ~w(claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-fable-5-1 claude-haiku-5-5) do
        refute Completion.anthropic_sampling?(id), id
      end

      for id <-
            ~w(claude-sonnet-4-6 claude-opus-4-5-20251101 claude-haiku-4-5-20251001 claude-3-5-sonnet-20241022) do
        assert Completion.anthropic_sampling?(id), id
      end
    end

    test "an id it cannot read is taken for a newer model" do
      refute Completion.anthropic_sampling?("not-a-claude")
      refute Completion.anthropic_sampling?(nil)
    end
  end

  describe "a chat request" do
    defp stub_chat do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "hi"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      end)
    end

    defp anthropic_endpoint(model) do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Anthropic #{System.unique_integer([:positive])}",
          provider: "anthropic",
          base_url: @anthropic,
          model: model,
          api_key: "sk-ant-test"
        })

      endpoint
    end

    test "a model that refuses sampling gets none, even set by the caller" do
      stub_chat()
      ep = anthropic_endpoint("claude-opus-5-5")

      assert {:ok, _} =
               PhoenixKitAI.ask(ep.uuid, "hi", temperature: 0.3, top_p: 0.9, max_tokens: 50)

      assert_received {:body, body}
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")
      assert body["max_tokens"] == 50
    end

    test "an earlier model keeps the caller's temperature, never with top_p" do
      stub_chat()
      ep = anthropic_endpoint("claude-sonnet-4-6")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", temperature: 0.3, top_p: 0.9)
      assert_received {:body, %{"temperature" => 0.3} = body}
      refute Map.has_key?(body, "top_p")
    end

    test "other providers are left alone" do
      stub_chat()

      {:ok, ep} =
        PhoenixKitAI.create_endpoint(%{
          name: "OpenRouter #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "anthropic/claude-opus-5",
          api_key: "sk-or-test"
        })

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", temperature: 0.3)
      assert_received {:body, %{"temperature" => 0.3}}
    end
  end

  describe "the /models request" do
    defp stub_models do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "claude-opus-5-5",
              "type" => "model",
              "display_name" => "Claude Opus 5.5",
              "max_input_tokens" => 1_000_000,
              "max_tokens" => 128_000,
              "capabilities" => %{
                "image_input" => %{"supported" => true},
                "pdf_input" => %{"supported" => true}
              }
            }
          ],
          "has_more" => false
        })
      end)
    end

    defp header(headers, name) do
      for {key, value} <- headers, key == name, do: value
    end

    test "carries the headers the core registry declares for the provider" do
      :ok = ModuleRegistry.register(RegistryProvider)
      on_exit(fn -> ModuleRegistry.unregister(RegistryProvider) end)
      stub_models()

      assert {:ok, [_]} =
               OpenRouterClient.fetch_models("sk-ant-test",
                 base_url: @anthropic,
                 fallback_provider: "anthropic"
               )

      assert_received {:headers, headers}
      assert header(headers, "anthropic-version") == ["2099-01-01"]
      assert header(headers, "anthropic-beta") == ["models-listing"]
    end

    test "without the provider in the registry, the version header is the module's own" do
      stub_models()

      assert {:ok, [_]} =
               OpenRouterClient.fetch_models("sk-ant-test",
                 base_url: @anthropic,
                 fallback_provider: "anthropic"
               )

      assert_received {:headers, headers}
      assert header(headers, "anthropic-version") == ["2023-06-01"]
    end

    test "the model card's data: capabilities, limits, and no made-up price" do
      stub_models()

      assert {:ok, [model]} =
               OpenRouterClient.fetch_models("sk-ant-test", base_url: @anthropic)

      assert %AIModel{
               name: "Claude Opus 5.5",
               context_length: 1_000_000,
               max_completion_tokens: 128_000,
               pricing: %{"prompt" => nil, "completion" => nil}
             } = model

      assert %{vision: :yes, file_input: :yes, image_output: :no, tools: :yes} =
               model.capabilities
    end
  end

  describe "a listing without prices" do
    test "an OpenAI-compatible /models row without a price is unpriced, not free" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"data" => [%{"id" => "grok-4"}]}))

      assert {:ok, [%AIModel{pricing: %{"prompt" => nil, "completion" => nil}}]} =
               OpenRouterClient.fetch_models("xai-key", base_url: "https://api.x.ai/v1")
    end
  end
end
