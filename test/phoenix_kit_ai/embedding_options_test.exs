defmodule PhoenixKitAI.EmbeddingOptionsTest do
  @moduledoc """
  The options of embedding calls (and the helpers around them) end to end,
  through the real verbs, against `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.{Completion, Endpoint, Request}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp endpoint(attrs) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Embeddings #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "openai/text-embedding-3-small",
            api_key: "sk-or-v1-test-key",
            dimensions: nil
          },
          Map.new(attrs)
        )
      )

    endpoint
  end

  # Answers every embeddings call with one vector per input (`vector` for
  # each, or [n, 0] numbering them) and sends the body to the test.
  defp stub_embeddings(opts \\ []) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test, {:request_body, body})
      count = if is_list(body["input"]), do: length(body["input"]), else: 1

      data =
        for i <- 0..(count - 1) do
          %{"index" => i, "embedding" => Keyword.get(opts, :vector, [i * 1.0, 0.0])}
        end

      Req.Test.json(conn, %{
        "model" => body["model"],
        "data" => data,
        "usage" => %{
          "prompt_tokens" => 10 * count,
          "total_tokens" => 10 * count,
          "cost" => 0.0001
        }
      })
    end)
  end

  defp bodies do
    receive do
      {:request_body, body} -> [body | bodies()]
    after
      0 -> []
    end
  end

  describe "dimensions" do
    test "the row records the dimensions sent, the call's over the endpoint's" do
      ep = endpoint(model: "openai/text-embedding-3-small", dimensions: 1536)
      stub_embeddings()

      assert {:ok, %{"request_uuid" => uuid}} = PhoenixKitAI.embed(ep.uuid, "x", dimensions: 256)
      assert_received {:request_body, %{"dimensions" => 256}}
      assert TestRepo.get!(Request, uuid).metadata["dimensions"] == 256

      assert {:ok, %{"request_uuid" => uuid}} = PhoenixKitAI.embed(ep.uuid, "y")
      assert_received {:request_body, %{"dimensions" => 1536}}
      assert TestRepo.get!(Request, uuid).metadata["dimensions"] == 1536
    end
  end
end
