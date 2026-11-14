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

  describe "role:" do
    test "sends the model's input_type per role and records it" do
      ep = endpoint(model: "mongodb/voyage-4")
      stub_embeddings()

      assert {:ok, query} = PhoenixKitAI.embed(ep.uuid, "red sofa", role: :query)
      assert_received {:request_body, %{"input" => "red sofa", "input_type" => "query"}}

      assert query["convention"] == %{
               "role" => "query",
               "input_type" => "query",
               "template" => nil
             }

      row = TestRepo.get!(Request, query["request_uuid"])
      assert row.metadata["role"] == "query"
      assert row.metadata["input_type"] == "query"

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, ["a", "b"], role: :document)
      assert_received {:request_body, %{"input" => ["a", "b"], "input_type" => "document"}}
    end

    test "puts the instruction before a Qwen query, never before a document" do
      ep = endpoint(model: "qwen/qwen3-embedding-8b")
      stub_embeddings()

      assert {:ok, _} =
               PhoenixKitAI.embed(ep.uuid, ["horses on a beach"],
                 role: :query,
                 instruction: "Given an image search query, retrieve descriptions of images"
               )

      assert_received {:request_body,
                       %{
                         "input" => [
                           "Instruct: Given an image search query, retrieve descriptions of images\nQuery: horses on a beach"
                         ]
                       } = body}

      refute Map.has_key?(body, "input_type")

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "a description", role: :document)
      assert_received {:request_body, %{"input" => "a description"}}
    end

    test "prefixes only the texts of a list with images" do
      ep = endpoint(model: "google/gemini-embedding-2")
      stub_embeddings()
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, [{:image, jpeg}, "a cat"], role: :document)

      assert_received {:request_body, %{"input" => [image, text]} = body}
      refute Map.has_key?(body, "input_type")
      assert %{"content" => [%{"type" => "image_url"}]} = image
      assert %{"content" => [%{"type" => "text", "text" => "title: none | text: a cat"}]} = text
    end

    test "without a role nothing changes" do
      ep = endpoint(model: "mongodb/voyage-4")
      stub_embeddings()

      assert {:ok, response} = PhoenixKitAI.embed(ep.uuid, "plain")
      assert_received {:request_body, body}
      assert body == %{"model" => "mongodb/voyage-4", "input" => "plain"}
      refute Map.has_key?(response, "convention")
    end

    test "an invalid role is refused before any request" do
      ep = endpoint(model: "mongodb/voyage-4")
      stub_embeddings()

      assert {:error, :invalid_embedding_role} = PhoenixKitAI.embed(ep.uuid, "x", role: :search)
      refute_received {:request_body, _}
      assert PhoenixKitAI.Errors.message(:invalid_embedding_role) =~ "query or document"
    end

    test "query and document embeddings of one text never share a cache entry" do
      for model <- [
            "mongodb/voyage-4",
            "qwen/qwen3-embedding-8b",
            "openai/text-embedding-3-small"
          ] do
        ep = endpoint(model: model)
        stub_embeddings()

        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "same text", role: :query, cache: true)
        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "same text", role: :document, cache: true)
        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "same text", cache: true)
        # a second query is the cached one
        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "same text", role: :query, cache: true)

        assert length(bodies()) == 3, model

        # with a caller's own key too
        key = [key: "doc-#{model}"]
        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "k", role: :query, cache: key)
        assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "k", role: :document, cache: key)
        assert length(bodies()) == 2, model
      end
    end
  end

  describe "pass-through and normalisation" do
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

      assert {:ok, %{"data" => [%{"embedding" => [0.6, 0.8]}]}} =
               PhoenixKitAI.embed(ep.uuid, "x", encoding_format: "base64", normalize: true)
    end

    test "a base64 vector that does not decode whole is an error, never a short vector or a string" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      nan = <<0, 0, 192, 127>>
      inf = <<0, 0, 128, 127>>

      for encoded <- [
            Base.encode64(<<1.0::float-32-little>> <> nan <> <<2.0::float-32-little>>),
            Base.encode64(<<1.0::float-32-little>> <> inf),
            Base.encode64(<<1, 2, 3>>),
            "not base64!"
          ] do
        Req.Test.stub(__MODULE__, fn conn ->
          Req.Test.json(conn, %{
            "data" => [
              %{"index" => 0, "embedding" => Base.encode64(<<5.0::float-32-little>>)},
              %{"index" => 1, "embedding" => encoded}
            ]
          })
        end)

        assert {:error, :invalid_response_format} =
                 PhoenixKitAI.embed(ep.uuid, ["a", "b"], encoding_format: "base64", cache: false)
      end
    end

    test "normalize: true returns unit vectors; off by default" do
      ep = endpoint(model: "perplexity/pplx-embed-v1-4b")
      stub_embeddings(vector: [6.0, 8.0])

      assert {:ok, %{"data" => [%{"embedding" => [6.0, 8.0]}]}} = PhoenixKitAI.embed(ep.uuid, "x")

      assert {:ok, %{"data" => [%{"embedding" => [0.6, 0.8]}], "request_uuid" => uuid}} =
               PhoenixKitAI.embed(ep.uuid, "x", normalize: true)

      assert TestRepo.get!(Request, uuid).metadata["normalized"] == true
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

    test "a caller cache key keeps vectors of different dimensions apart" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      stub_embeddings()
      key = [cache: [key: "photo:1"]]

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "x", [dimensions: 256] ++ key)
      assert_received {:request_body, %{"dimensions" => 256}}

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "x", [dimensions: 512] ++ key)
      assert_received {:request_body, %{"dimensions" => 512}}

      # the same size again is a hit, and so is a call that names no size
      # under a key it was cached without
      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "x", [dimensions: 256] ++ key)
      refute_received {:request_body, _}

      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "y", cache: [key: "photo:2"])
      assert_received {:request_body, _}
      assert {:ok, _} = PhoenixKitAI.embed(ep.uuid, "y", cache: [key: "photo:2"])
      refute_received {:request_body, _}
    end

    test "mistral-embed never gets dimensions (it answers 422)" do
      ep = endpoint(model: "mistralai/mistral-embed-2312", dimensions: 512)
      stub_embeddings()

      assert {:ok, %{"request_uuid" => uuid}} = PhoenixKitAI.embed(ep.uuid, "x")
      assert_received {:request_body, body}
      refute Map.has_key?(body, "dimensions")
      assert TestRepo.get!(Request, uuid).metadata["dimensions"] == nil
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

  describe "embed_many/3" do
    test "splits by batch_size and merges in order with summed usage and cost" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      stub_embeddings()
      inputs = for i <- 1..5, do: "text #{i}"

      assert {:ok, response} = PhoenixKitAI.embed_many(ep.uuid, inputs, batch_size: 2)

      assert [["text 1", "text 2"], ["text 3", "text 4"], ["text 5"]] =
               bodies() |> Enum.map(& &1["input"])

      assert Enum.map(response["data"], & &1["index"]) == [0, 1, 2, 3, 4]
      # each part numbers its own vectors 0.., so the merged order is visible
      assert Enum.map(response["data"], &hd(&1["embedding"])) == [0.0, 1.0, 0.0, 1.0, 0.0]
      assert response["usage"] == %{"prompt_tokens" => 50, "total_tokens" => 50}
      assert response["batches"] == 3
      assert length(response["request_uuids"]) == 3
      assert Decimal.equal?(response["cost"], Decimal.new("0.0003"))
      assert response["space"] == "openai/text-embedding-3-small:2"
    end

    test "uses the model's limit (Cohere: 96 per request) and passes the role on" do
      ep = endpoint(model: "cohere/embed-5-pro")
      stub_embeddings()

      assert {:ok, %{"data" => data, "convention" => %{"role" => "document"}}} =
               PhoenixKitAI.embed_many(ep.uuid, Enum.map(1..100, &"t#{&1}"),
                 role: :document,
                 max_concurrency: 2
               )

      sent = bodies()
      assert Enum.map(sent, &length(&1["input"])) |> Enum.sort() == [4, 96]
      assert Enum.all?(sent, &(&1["input_type"] == "search_document"))
      assert length(data) == 100
      assert Enum.map(data, & &1["index"]) == Enum.to_list(0..99)
    end

    test "a part that answers fewer vectors keeps each vector paired with its input" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      test = self()

      # the first part answers only its second input's vector (index 1)
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        input = Jason.decode!(raw)["input"]
        send(test, {:request_body, input})

        data =
          case input do
            ["a", "b"] -> [%{"index" => 1, "embedding" => [2.0]}]
            ["c"] -> [%{"index" => 0, "embedding" => [3.0]}]
          end

        Req.Test.json(conn, %{"data" => data})
      end)

      assert {:ok, %{"data" => data}} =
               PhoenixKitAI.embed_many(ep.uuid, ["a", "b", "c"], batch_size: 2)

      assert Enum.map(data, &{&1["index"], &1["embedding"]}) == [{1, [2.0]}, {2, [3.0]}]
    end

    test "a token budget splits long texts" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      stub_embeddings()
      long = String.duplicate("a", 300)

      assert {:ok, %{"batches" => 3}} =
               PhoenixKitAI.embed_many(ep.uuid, [long, long, long], max_batch_tokens: 150)
    end

    test "returns the first failing part's error" do
      ep = endpoint(model: "openai/text-embedding-3-small")
      Req.Test.stub(__MODULE__, &Req.Test.json(Plug.Conn.put_status(&1, 503), %{}))

      assert {:error, {:api_error, 503}} =
               PhoenixKitAI.embed_many(ep.uuid, ["a", "b", "c"], batch_size: 1)

      assert {:error, :empty_input} = PhoenixKitAI.embed_many(ep.uuid, [])
    end
  end

  describe "translate_query/3" do
    defp stub_chat(answer) do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => answer}}],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
        })
      end)
    end

    test "translates a non-ASCII query, caches it, and skips plain ASCII" do
      ep = endpoint(model: "google/gemini-3.8-flash")
      stub_chat("\"sleeping cat\"\n")

      assert PhoenixKitAI.translate_query(ep.uuid, " спящая кошка ") == "sleeping cat"
      assert_received {:request_body, %{"messages" => [system, %{"content" => "спящая кошка"}]}}
      assert system["content"] =~ "into English"

      assert PhoenixKitAI.translate_query(ep.uuid, " спящая кошка ") == "sleeping cat"
      refute_received {:request_body, _}

      assert PhoenixKitAI.translate_query(ep.uuid, "sleeping cat") == "sleeping cat"
      refute_received {:request_body, _}

      assert PhoenixKitAI.translate_query(ep.uuid, "magav kass", skip_ascii: false) ==
               "sleeping cat"

      assert_received {:request_body, _}

      assert PhoenixKitAI.translate_query(ep.uuid, "sleeping cat", to: "Estonian") ==
               "sleeping cat"

      assert_received {:request_body, %{"messages" => [%{"content" => estonian} | _]}}
      assert estonian =~ "into Estonian"
    end

    test "returns the query unchanged on any failure" do
      ep = endpoint(model: "google/gemini-3.8-flash")
      Req.Test.stub(__MODULE__, &Req.Test.json(Plug.Conn.put_status(&1, 500), %{}))

      assert PhoenixKitAI.translate_query(ep.uuid, "кошка") == "кошка"
      assert PhoenixKitAI.translate_query(Ecto.UUID.generate(), "кошка") == "кошка"
      assert PhoenixKitAI.translate_query(nil, "кошка") == "кошка"
      assert PhoenixKitAI.translate_query(ep.uuid, nil) == nil
      assert PhoenixKitAI.translate_query(ep.uuid, "   ") == "   "

      stub_chat("")
      assert PhoenixKitAI.translate_query(ep.uuid, "собака", cache: false) == "собака"

      stub_chat(String.duplicate("word ", 200))
      assert PhoenixKitAI.translate_query(ep.uuid, "собака", cache: false) == "собака"

      # the length guard measures the query that was sent, not its padding
      padded = String.duplicate(" ", 1_000) <> "собака"
      assert PhoenixKitAI.translate_query(ep.uuid, padded, cache: false) == padded
    end

    test "strips the quotes a model wraps a translation in" do
      ep = endpoint(model: "google/gemini-3.8-flash")

      for answer <- [~s("dog"), "«dog»", "“dog”", "„dog“", "'dog'", ~s( "“dog”" )] do
        stub_chat(answer)
        assert PhoenixKitAI.translate_query(ep.uuid, "собака", cache: false) == "dog"
      end

      # an apostrophe at one end is part of the words
      for answer <- ["'tis cats", "dogs’ toys", "\"quoted\" word"] do
        stub_chat(answer)
        assert PhoenixKitAI.translate_query(ep.uuid, "собаки", cache: false) == answer
      end
    end
  end
end
