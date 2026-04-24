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
