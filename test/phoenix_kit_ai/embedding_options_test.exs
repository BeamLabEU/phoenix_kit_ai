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

  describe "pass-through" do
    test "input_type, encoding_format and user are sent; base64 vectors come back as floats" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      test = self()
      encoded = Base.encode64(<<3.0::float-32-little, 4.0::float-32-little>>)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_body, Jason.decode!(raw)})
        Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => encoded}]})
      end)

      assert {:ok, %{"data" => [%{"embedding" => [3.0, 4.0]}], "space" => space}} =
               PhoenixKitAI.embed(ep.uuid, "x",
                 input_type: "search_document",
                 encoding_format: "base64",
                 user: "visitor-7"
               )

      assert space == "openai/text-embedding-3-small:2"

      assert_received {:request_body,
                       %{
                         "input_type" => "search_document",
                         "encoding_format" => "base64",
                         "user" => "visitor-7"
                       }}
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

  describe "provider preferences" do
    test "embed/3 sends the call's preferences over the endpoint's on OpenRouter" do
      ep =
        endpoint(
          model: "qwen/qwen3-embedding-8b",
          provider_settings: %{
            "provider_preferences" => %{"order" => ["nebius"], "allow_fallbacks" => true}
          }
        )

      stub_embeddings()

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "x")
      assert_received {:request_body, %{"provider" => %{"order" => ["nebius"]}}}

      assert {:ok, _} =
               PhoenixKitAI.embed(ep.uuid, "x",
                 provider: %{order: [:deepinfra], allow_fallbacks: false, bad: {:tuple}}
               )

      assert_received {:request_body, %{"provider" => provider}}
      assert provider == %{"order" => ["deepinfra"], "allow_fallbacks" => false}
    end

    test "provider_preferences/2 across providers and the guard's require_parameters" do
      base = %Endpoint{
        provider: "openrouter",
        provider_settings: %{"provider_preferences" => %{"sort" => "throughput"}}
      }

      call = [provider: [sort: "price", quantizations: ["fp8"], ignore: ["x"]]]

      for {endpoint_provider, require?, expected} <- [
            {"openrouter", false,
             %{"sort" => "price", "quantizations" => ["fp8"], "ignore" => ["x"]}},
            {"openrouter", true,
             %{
               "sort" => "price",
               "quantizations" => ["fp8"],
               "ignore" => ["x"],
               "require_parameters" => true
             }},
            {"openrouter:work", false,
             %{"sort" => "price", "quantizations" => ["fp8"], "ignore" => ["x"]}},
            {"openai", false, %{}},
            {"openai", true, %{"require_parameters" => true}}
          ] do
        opts = if require?, do: [require_parameters: true] ++ call, else: call

        assert Completion.provider_preferences(%{base | provider: endpoint_provider}, opts) ==
                 expected,
               "#{endpoint_provider} require=#{require?}"
      end

      # the guard's flag wins over a caller's false
      assert %{"require_parameters" => true} =
               Completion.provider_preferences(base,
                 require_parameters: true,
                 provider: %{require_parameters: false}
               )

      # not a map: ignored, never raised
      assert Completion.provider_preferences(base, provider: "fastest") == %{
               "sort" => "throughput"
             }

      assert Completion.provider_preferences(base, provider: [1, 2]) == %{"sort" => "throughput"}
    end

    test "complete/3 sends provider: on OpenRouter" do
      ep = endpoint(model: "deepseek/deepseek-v3.2")
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      end)

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}],
                 provider: %{sort: "price", quantizations: ["fp8", "bf16"], ignore: ["Chutes"]}
               )

      assert_received {:request_body, %{"provider" => provider}}

      assert provider == %{
               "sort" => "price",
               "quantizations" => ["fp8", "bf16"],
               "ignore" => ["Chutes"]
             }
    end
  end
end
