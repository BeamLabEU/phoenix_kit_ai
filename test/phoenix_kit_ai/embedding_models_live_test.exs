defmodule PhoenixKitAI.EmbeddingModelsLiveTest do
  @moduledoc """
  `OpenRouterClient.fetch_embedding_models/2` reading OpenRouter's
  `GET /embeddings/models`, its cache and its fallback to the curated list.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.OpenRouterClient

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    Application.put_env(:phoenix_kit_ai, :embedding_models_live, true)
    OpenRouterClient.clear_embedding_models_cache()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.put_env(:phoenix_kit_ai, :embedding_models_live, false)
      OpenRouterClient.clear_embedding_models_cache()
    end)

    :ok
  end

  defp stub_listing(status, body) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:listing, conn.request_path})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  @listing %{
    "data" => [
      %{
        "id" => "cohere/embed-5-fast",
        "name" => "Cohere: Embed 5 Fast",
        "context_length" => 128_000,
        "architecture" => %{"input_modalities" => ["text", "image"]},
        "pricing" => %{"prompt" => "0.00000008", "completion" => "0"}
      },
      %{"id" => "openai/text-embedding-3-small", "name" => "OpenAI: Small"},
      %{"name" => "no id, dropped"}
    ]
  }

  test "reads the live list, fills known dimensions and caches it" do
    stub_listing(200, @listing)

    assert {:ok, [fast, small]} = OpenRouterClient.fetch_embedding_models("sk-x")
    assert_received {:listing, "/api/v1/embeddings/models"}

    assert fast["id"] == "cohere/embed-5-fast"
    assert fast["input_modalities"] == ["text", "image"]
    assert fast["pricing"] == %{"prompt" => "0.00000008", "completion" => "0"}
    assert fast["dimensions"] == 2048
    assert small["dimensions"] == 1536
    assert small["input_modalities"] == ["text"]

    # cached: no second request
    assert {:ok, [_, _]} = OpenRouterClient.fetch_embedding_models("sk-x")
    refute_received {:listing, _}

    # refresh: asks again
    assert {:ok, [_, _]} = OpenRouterClient.fetch_embedding_models("sk-x", refresh: true)
    assert_received {:listing, _}
  end

  test "falls back to the curated list when the listing fails, and keeps the last good list" do
    stub_listing(500, %{})
    assert {:ok, models} = OpenRouterClient.fetch_embedding_models(nil)
    assert "mongodb/voyage-4" in Enum.map(models, & &1["id"])

    stub_listing(200, @listing)
    assert {:ok, [_, _]} = OpenRouterClient.fetch_embedding_models("sk-x", refresh: true)

    stub_listing(200, %{"data" => "nope"})

    assert {:ok, [%{"id" => "cohere/embed-5-fast"}, _]} =
             OpenRouterClient.fetch_embedding_models("sk-x", refresh: true)

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    OpenRouterClient.clear_embedding_models_cache()
    assert {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-x")
    assert length(models) > 10
  end

  test "a field of the wrong type is taken from the curated entry" do
    stub_listing(200, %{
      "data" => [
        %{
          "id" => "cohere/embed-5-fast",
          "name" => 42,
          "description" => ["x"],
          "context_length" => "8191",
          "pricing" => "free",
          "architecture" => "text"
        },
        %{"id" => "someone/new", "architecture" => %{"input_modalities" => [1, 2]}}
      ]
    })

    assert {:ok, [fast, new]} = OpenRouterClient.fetch_embedding_models("sk-x")
    assert fast["name"] == "Embed 5 Fast"
    assert fast["context_length"] == 128_000
    assert fast["pricing"] == %{"prompt" => 0.00000008, "completion" => 0}
    assert fast["input_modalities"] == ["text", "image"]
    assert is_binary(fast["description"])
    assert new["name"] == "someone/new"
    assert new["input_modalities"] == ["text"]
  end

  test "a listing that raises or exits is not asked again for a minute" do
    test = self()

    Req.Test.stub(__MODULE__, fn _conn ->
      send(test, :asked)
      raise "boom"
    end)

    assert {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-x")
    assert "mongodb/voyage-4" in Enum.map(models, & &1["id"])
    assert_received :asked

    assert {:ok, _} = OpenRouterClient.fetch_embedding_models("sk-x")
    refute_received :asked

    OpenRouterClient.clear_embedding_models_cache()

    Req.Test.stub(__MODULE__, fn _conn ->
      send(test, :asked)
      exit(:pool_down)
    end)

    assert {:ok, _} = OpenRouterClient.fetch_embedding_models("sk-x")
    assert_received :asked
    assert {:ok, _} = OpenRouterClient.fetch_embedding_models("sk-x")
    refute_received :asked
  end

  test "live: false and the app env skip the request" do
    stub_listing(200, @listing)

    assert {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-x", live: false)
    assert length(models) > 10
    refute_received {:listing, _}

    Application.put_env(:phoenix_kit_ai, :embedding_models_live, false)
    assert {:ok, _} = OpenRouterClient.fetch_embedding_models("sk-x")
    refute_received {:listing, _}
  end
end
