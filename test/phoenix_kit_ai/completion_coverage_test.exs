defmodule PhoenixKitAI.CompletionCoverageTest do
  @moduledoc """
  Coverage push for `Completion` (HTTP wrapper) and the public
  HTTP-driven entry points on `PhoenixKitAI` (`complete/3`, `ask/3`,
  `embed/3`, `ask_with_prompt/4`, `complete_with_system_prompt/5`).

  Uses `Req.Test` plug stubs to avoid external traffic. Production code
  is unaffected — the test setup opts in via
  `Application.put_env(:phoenix_kit_ai, :req_options, plug: ...)`.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Completion, Endpoint, Prompt}

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.CompletionCoverageTest},
      retry: false
    )

    # Register a connected OpenRouter integration so `validate_endpoint/1`
    # doesn't short-circuit on `:integration_not_configured`. Done via the
    # public Settings API so the row format matches what
    # `PhoenixKit.Integrations.connected?/1` expects to read back.
    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{
          "api_key" => "sk-test-key",
          "status" => "connected",
          "provider" => "openrouter"
        }
      )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  defp stub_response(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp stub_raw(status, raw_body) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, status, raw_body)
    end)
  end

  defp stub_transport_error(reason) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, reason)
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "anthropic/claude-3-haiku",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp success_payload(content \\ "Hi!") do
    %{
      "id" => "gen-1",
      "model" => "anthropic/claude-3-haiku",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ],
      "usage" => %{
        "prompt_tokens" => 5,
        "completion_tokens" => 3,
        "total_tokens" => 8,
        "cost" => 0.000005
      }
    }
  end

  describe "Completion.chat_completion/3" do
    test "200 returns the parsed body with latency_ms" do
      stub_response(200, success_payload())
      ep = endpoint_fixture()

      assert {:ok, %{"choices" => _, "latency_ms" => latency}} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])

      assert is_integer(latency)
    end

    test "200 with non-JSON body returns :invalid_json_response" do
      stub_raw(200, "<html>")
      ep = endpoint_fixture()

      assert {:error, :invalid_json_response} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "401 returns :invalid_api_key" do
      stub_response(401, %{})
      ep = endpoint_fixture()

      assert {:error, :invalid_api_key} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "402 returns :insufficient_credits" do
      stub_response(402, %{})
      ep = endpoint_fixture()

      assert {:error, :insufficient_credits} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "429 returns :rate_limited" do
      stub_response(429, %{})
      ep = endpoint_fixture()

      assert {:error, :rate_limited} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "transport :timeout returns :request_timeout" do
      stub_transport_error(:timeout)
      ep = endpoint_fixture()

      assert {:error, :request_timeout} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "transport :nxdomain returns {:connection_error, :nxdomain}" do
      stub_transport_error(:nxdomain)
      ep = endpoint_fixture()

      assert {:error, {:connection_error, :nxdomain}} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end

    test "build_chat_body adds optional knobs (temperature, max_tokens, etc.)" do
      stub_response(200, success_payload())
      ep = endpoint_fixture()

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}],
                 temperature: 0.5,
                 max_tokens: 100,
                 top_p: 0.9,
                 top_k: 40,
                 frequency_penalty: 0.1,
                 presence_penalty: 0.1,
                 repetition_penalty: 1.0,
                 stop: ["\n"],
                 seed: 42,
                 stream: false,
                 reasoning_enabled: true,
                 reasoning_effort: "medium",
                 reasoning_max_tokens: 2048
               )
    end

    test "string-keyed messages are normalized" do
      stub_response(200, success_payload())
      ep = endpoint_fixture()

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{"role" => "user", "content" => "hi"}])
    end
  end

  describe "Completion.embeddings/3" do
    test "200 returns the parsed embeddings response" do
      stub_response(200, %{
        "data" => [%{"embedding" => [0.1, 0.2]}],
        "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
      })

      ep = endpoint_fixture(%{model: "openai/text-embedding-3-small"})
      assert {:ok, %{"data" => _}} = Completion.embeddings(ep, "hello", dimensions: 256)
    end

    test "200 with non-JSON returns :invalid_json_response" do
      stub_raw(200, "<html>")
      ep = endpoint_fixture()
      assert {:error, :invalid_json_response} = Completion.embeddings(ep, "hello")
    end

    test "non-2xx routes through handle_error_status" do
      stub_response(429, %{})
      ep = endpoint_fixture()
      assert {:error, :rate_limited} = Completion.embeddings(ep, "hello")
    end

    test "transport :timeout returns :request_timeout" do
      stub_transport_error(:timeout)
      ep = endpoint_fixture()
      assert {:error, :request_timeout} = Completion.embeddings(ep, "hello")
    end

    test "transport other reason returns {:connection_error, reason}" do
      stub_transport_error(:closed)
      ep = endpoint_fixture()
      assert {:error, {:connection_error, :closed}} = Completion.embeddings(ep, "hello")
    end
  end

  describe "PhoenixKitAI.complete/3 — full path" do
    test "logs a Request row on success" do
      stub_response(200, success_payload("hello"))
      ep = endpoint_fixture()

      assert {:ok, %{"choices" => _}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      requests = PhoenixKitAI.list_requests() |> elem(0)
      assert Enum.any?(requests, &(&1.endpoint_uuid == ep.uuid and &1.status == "success"))
    end

    test "transport error returns the tuple and runs the failed-request logger" do
      stub_transport_error(:nxdomain)
      ep = endpoint_fixture()

      assert {:error, {:connection_error, :nxdomain}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      # Failed-request row must land. error_message is a :string column,
      # so the tuple-shaped reason gets rendered via Errors.message/1
      # while the original shape is kept in metadata.error_reason.
      requests = PhoenixKitAI.list_requests() |> elem(0)

      assert %{
               status: "error",
               error_message: error_message,
               metadata: %{"error_reason" => "{:connection_error, :nxdomain}"}
             } = Enum.find(requests, &(&1.endpoint_uuid == ep.uuid))

      assert is_binary(error_message)
      assert error_message =~ "Connection error"
    end

    test "rejects an unknown endpoint with :endpoint_not_found" do
      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.complete("019abc12-3456-7def-8901-234567890abc", [
                 %{role: "user", content: "hi"}
               ])
    end

    test "rejects a disabled endpoint with :endpoint_disabled" do
      ep = endpoint_fixture(%{enabled: false})

      assert {:error, :endpoint_disabled} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])
    end
  end

  describe "PhoenixKitAI.ask/3" do
    test "wraps the user prompt and returns the response map" do
      stub_response(200, success_payload("Greetings!"))
      ep = endpoint_fixture()

      assert {:ok, %{"choices" => _} = response} = PhoenixKitAI.ask(ep.uuid, "Hi there")
      assert {:ok, "Greetings!"} = PhoenixKitAI.extract_content(response)
    end

    test "honours :system option" do
      stub_response(200, success_payload("Bonjour"))
      ep = endpoint_fixture()

      assert {:ok, %{"choices" => _}} =
               PhoenixKitAI.ask(ep.uuid, "Hi", system: "Reply in French.")
    end

    test "returns the underlying error" do
      stub_response(401, %{})
      ep = endpoint_fixture()
      assert {:error, :invalid_api_key} = PhoenixKitAI.ask(ep.uuid, "Hi")
    end
  end

  describe "PhoenixKitAI.embed/3" do
    test "returns the embedding response" do
      stub_response(200, %{"data" => [%{"embedding" => [0.1]}], "usage" => %{}})
      ep = endpoint_fixture(%{model: "openai/text-embedding-3-small"})

      assert {:ok, %{"data" => _}} = PhoenixKitAI.embed(ep.uuid, "hello")
    end

    test "logs an embedding Request on success" do
      stub_response(200, %{
        "data" => [%{"embedding" => [0.1]}],
        "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5}
      })

      ep = endpoint_fixture(%{model: "openai/text-embedding-3-small"})
      {:ok, _} = PhoenixKitAI.embed(ep.uuid, "hello")
      requests = PhoenixKitAI.list_requests() |> elem(0)
      assert Enum.any?(requests, &(&1.endpoint_uuid == ep.uuid))
    end

    test "embed/3 error path returns the underlying error" do
      stub_response(429, %{})
      ep = endpoint_fixture(%{model: "openai/text-embedding-3-small"})
      assert {:error, :rate_limited} = PhoenixKitAI.embed(ep.uuid, "hello")
    end

    test "rejects unknown endpoint" do
      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.embed("019abc12-3456-7def-8901-234567890abc", "hi")
    end
  end

  describe "ask_with_prompt + complete_with_system_prompt" do
    setup do
      ep = endpoint_fixture()

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "AWP-#{System.unique_integer([:positive])}",
          content: "Translate to {{Lang}}: {{Text}}",
          system_prompt: "You are a {{Lang}} translator"
        })

      {:ok, %{ep: ep, prompt: prompt}}
    end

    test "ask_with_prompt happy path increments usage_count", %{ep: ep, prompt: prompt} do
      stub_response(200, success_payload("Bonjour"))

      assert {:ok, %{"choices" => _}} =
               PhoenixKitAI.ask_with_prompt(ep.uuid, prompt.uuid, %{
                 "Lang" => "French",
                 "Text" => "Hello"
               })

      reloaded = PhoenixKitAI.get_prompt(prompt.uuid)
      assert reloaded.usage_count == 1
    end

    test "ask_with_prompt does NOT increment on error", %{ep: ep, prompt: prompt} do
      stub_response(401, %{})

      assert {:error, :invalid_api_key} =
               PhoenixKitAI.ask_with_prompt(ep.uuid, prompt.uuid, %{
                 "Lang" => "French",
                 "Text" => "Hello"
               })

      reloaded = PhoenixKitAI.get_prompt(prompt.uuid)
      assert reloaded.usage_count == 0
    end

    test "ask_with_prompt rejects a disabled prompt", %{ep: ep, prompt: prompt} do
      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{enabled: false})

      assert {:error, {:prompt_error, :disabled}} =
               PhoenixKitAI.ask_with_prompt(ep.uuid, prompt.uuid, %{
                 "Lang" => "French",
                 "Text" => "Hello"
               })
    end

    test "complete_with_system_prompt happy path", %{ep: ep, prompt: prompt} do
      stub_response(200, success_payload("Bonjour"))

      assert {:ok, %{"choices" => _}} =
               PhoenixKitAI.complete_with_system_prompt(
                 ep.uuid,
                 prompt.uuid,
                 %{"Lang" => "French", "Text" => "ignored"},
                 "Hello world"
               )

      reloaded = PhoenixKitAI.get_prompt(prompt.uuid)
      assert reloaded.usage_count == 1
    end

    test "complete_with_system_prompt does NOT increment on error", %{ep: ep, prompt: prompt} do
      stub_response(429, %{})

      assert {:error, :rate_limited} =
               PhoenixKitAI.complete_with_system_prompt(
                 ep.uuid,
                 prompt.uuid,
                 %{"Lang" => "French"},
                 "Hello"
               )

      reloaded = PhoenixKitAI.get_prompt(prompt.uuid)
      assert reloaded.usage_count == 0
    end
  end

  describe "Completion.extract_content/1 + extract_usage/1 — extra branches" do
    test "extract_usage with parse_cost(non-number) returns nil cost_cents" do
      response = %{"usage" => %{"prompt_tokens" => 0, "cost" => "weird"}}
      assert %{cost_cents: nil} = Completion.extract_usage(response)
    end

    test "build_url respects endpoint.base_url with trailing slash" do
      stub_response(200, success_payload())

      ep = %Endpoint{
        uuid: Ecto.UUID.generate(),
        name: "T",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-x",
        base_url: "https://api.example.com/v1/",
        provider_settings: %{}
      }

      # Use direct call (not the public PhoenixKitAI wrapper) since
      # this fake endpoint isn't persisted.
      assert {:ok, _} = Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
    end
  end

  describe "ensures Prompt.render path with content failure surfaces as :empty_content" do
    test "validate_prompt rejects an empty-content prompt struct directly" do
      empty = %Prompt{content: "", enabled: true}
      assert {:error, {:prompt_error, :empty_content}} = PhoenixKitAI.validate_prompt(empty)
    end
  end
end
