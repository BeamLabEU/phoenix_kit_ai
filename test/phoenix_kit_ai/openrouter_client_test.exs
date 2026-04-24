defmodule PhoenixKitAI.OpenRouterClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.OpenRouterClient

  describe "fetch_embedding_models/2" do
    test "returns the built-in curated list" do
      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      assert is_list(models)
      assert length(models) >= 8

      ids = Enum.map(models, & &1["id"])
      assert "openai/text-embedding-3-large" in ids
      assert "cohere/embed-english-v3.0" in ids
    end

    test "appends user-contributed models from config" do
      custom = [
        %{
          "id" => "custom/model-x",
          "name" => "Custom X",
          "description" => "Test",
          "context_length" => 2048,
          "dimensions" => 256,
          "pricing" => %{"prompt" => 0, "completion" => 0}
        }
      ]

      Application.put_env(:phoenix_kit_ai, :embedding_models, custom)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :embedding_models)
      end)

      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      ids = Enum.map(models, & &1["id"])
      assert "custom/model-x" in ids
    end

    test "tolerates malformed config (non-list)" do
      Application.put_env(:phoenix_kit_ai, :embedding_models, "not a list")

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :embedding_models)
      end)

      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      assert is_list(models)
    end
  end

  describe "embedding_models_last_updated/0" do
    test "returns a date string" do
      assert is_binary(OpenRouterClient.embedding_models_last_updated())
      assert OpenRouterClient.embedding_models_last_updated() =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end
  end

  describe "fetch_embedding_models_grouped/2" do
    test "groups the list by provider prefix" do
      {:ok, grouped} = OpenRouterClient.fetch_embedding_models_grouped("sk-test")
      assert is_list(grouped)
      providers = Enum.map(grouped, fn {p, _} -> p end)
      assert "openai" in providers
      assert "cohere" in providers
    end
  end

  describe "build_headers/2" do
    test "includes the bearer token and content type" do
      headers = OpenRouterClient.build_headers("sk-test-key")
      assert {"Authorization", "Bearer sk-test-key"} in headers
      assert Enum.any?(headers, fn {k, _} -> k == "Content-Type" end)
    end

    test "adds HTTP-Referer and X-Title when provided" do
      headers =
        OpenRouterClient.build_headers("sk-test-key",
          http_referer: "https://example.com",
          x_title: "Example"
        )

      assert {"HTTP-Referer", "https://example.com"} in headers
      assert {"X-Title", "Example"} in headers
    end

    test "omits optional headers when nil" do
      headers = OpenRouterClient.build_headers("sk-test-key", http_referer: nil, x_title: nil)
      refute Enum.any?(headers, fn {k, _} -> k == "HTTP-Referer" end)
      refute Enum.any?(headers, fn {k, _} -> k == "X-Title" end)
    end
  end
end

defmodule PhoenixKitAI.OpenRouterClient.LegacyFallbackTest do
  # Hits the DB through PhoenixKit.Integrations.get_credentials/1
  # to take the fallback branch, so this group needs DataCase.
  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.OpenRouterClient

  describe "build_headers_from_endpoint/1 — legacy api_key fallback" do
    # `resolve_api_key/2` falls back to `endpoint.api_key` when the
    # provider key isn't a registered integration. PR #3 added a
    # deprecation `Logger.warning` on that path identifying the
    # endpoint by name + uuid so the noise is actionable. Pin the
    # warning's content; without this test, dropping the helper or
    # silencing the log goes unnoticed.

    test "emits a deprecation warning identifying the endpoint when the legacy api_key path is used" do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000aa",
        name: "Legacy Endpoint",
        provider: "openrouter-not-registered-#{System.unique_integer([:positive])}",
        api_key: "sk-or-v1-legacy",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
          # Headers still get built — fallback path returns the
          # legacy key, not nil.
          assert {"Authorization", "Bearer sk-or-v1-legacy"} in headers
        end)

      assert log =~ "deprecated endpoint.api_key"
      assert log =~ ~s("Legacy Endpoint")
      assert log =~ endpoint.uuid
    end

    test "does NOT warn when the legacy api_key field is empty" do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000bb",
        name: "Empty Legacy",
        provider: "openrouter-not-registered-#{System.unique_integer([:positive])}",
        api_key: "",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          OpenRouterClient.build_headers_from_endpoint(endpoint)
        end)

      refute log =~ "deprecated endpoint.api_key"
    end
  end
end
