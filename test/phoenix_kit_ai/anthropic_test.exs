defmodule PhoenixKitAI.AnthropicTest do
  @moduledoc """
  Anthropic behind the OpenAI-compatible client: its `/models` gets the
  provider's `anthropic-version` header and its entries map onto model
  cards, and a chat request leaves out the sampling parameters the model
  refuses.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Anthropic, Completion, OpenRouterClient}

  @models %{
    "data" => [
      %{
        "type" => "model",
        "id" => "claude-opus-5-5",
        "display_name" => "Claude Opus 5.5",
        "max_input_tokens" => 1_000_000,
        "max_tokens" => 128_000,
        "capabilities" => %{"image_input" => %{"supported" => true}}
      },
      %{
        "type" => "model",
        "id" => "claude-sonnet-4-5-20250929",
        "display_name" => "Claude Sonnet 4.5",
        "max_input_tokens" => 200_000,
        "max_tokens" => 64_000,
        "capabilities" => %{"image_input" => %{"supported" => false}}
      }
    ]
  }

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  describe "sampling" do
    test "models from Claude Opus 4.7 on take neither temperature nor top_p" do
      for id <-
            ~w(claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-fable-5-1 claude-haiku-5-5) do
        refute Anthropic.sampling?(id), id
        assert Anthropic.supported_parameters(id) == ~w(max_tokens stop top_k)
      end

      for id <-
            ~w(claude-sonnet-4-6 claude-opus-4-5-20251101 claude-haiku-4-5-20251001 claude-3-5-sonnet-20241022) do
        assert Anthropic.sampling?(id), id
      end

      refute Anthropic.sampling?("not-a-claude")
      refute Anthropic.sampling?(nil)
    end

    test "sampling_opts/2 drops what the model refuses" do
      opts = [temperature: 0.7, top_p: 0.9, max_tokens: 10]

      assert Anthropic.sampling_opts(opts, "claude-opus-5") == [max_tokens: 10]

      assert Anthropic.sampling_opts(opts, "claude-sonnet-4-6") == [
               temperature: 0.7,
               max_tokens: 10
             ]

      assert Anthropic.sampling_opts([top_p: 0.9], "claude-sonnet-4-6") == [top_p: 0.9]
    end
  end

  describe "model discovery" do
    test "sends the extra headers and maps the entries onto model cards" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        Plug.Conn.send_resp(conn, 200, Jason.encode!(@models))
      end)

      assert {:ok, [{"anthropic", [opus, sonnet]}]} =
               OpenRouterClient.fetch_models_grouped("sk-ant-test",
                 base_url: "https://api.anthropic.com/v1",
                 fallback_provider: "anthropic",
                 extra_headers: [{"anthropic-version", "2023-06-01"}]
               )

      assert opus.name == "Claude Opus 5.5"
      assert opus.context_length == 1_000_000
      assert opus.max_completion_tokens == 128_000
      assert opus.supported_parameters == ~w(max_tokens stop top_k)
      assert "temperature" in sonnet.supported_parameters
    end

    test "the vision list keeps the models that take images" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, Jason.encode!(@models)))

      assert {:ok, [opus]} =
               OpenRouterClient.fetch_models("k",
                 base_url: "https://api.anthropic.com/v1",
                 model_type: :vision
               )

      assert opus.id == "claude-opus-5-5"
    end
  end

  describe "chat" do
    setup do
      {:ok, _} =
        PhoenixKit.Settings.update_json_setting("integration:anthropic:default", %{
          "api_key" => "sk-ant-test",
          "status" => "connected",
          "provider" => "anthropic"
        })

      me = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:body, Jason.decode!(body)})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "hi"}}]
          })
        )
      end)

      :ok
    end

    defp endpoint(model) do
      {:ok, ep} =
        PhoenixKitAI.create_endpoint(%{
          name: "Anthropic #{System.unique_integer([:positive])}",
          provider: "anthropic",
          model: model,
          base_url: "https://api.anthropic.com/v1",
          api_key: "sk-ant-test"
        })

      ep
    end

    test "a model that refuses sampling gets none, whatever the endpoint stores" do
      ep = endpoint("claude-opus-5-5")
      opts = [temperature: ep.temperature, top_p: 0.9, max_tokens: 50]

      assert {:ok, _} = Completion.chat_completion(ep, [%{role: "user", content: "hi"}], opts)
      assert_received {:body, body}
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")
      assert body["max_tokens"] == 50
    end

    test "an earlier model keeps its temperature" do
      ep = endpoint("claude-sonnet-4-6")

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}],
                 temperature: 0.3,
                 top_p: 0.9
               )

      assert_received {:body, %{"temperature" => 0.3} = body}
      refute Map.has_key?(body, "top_p")
    end
  end
end
