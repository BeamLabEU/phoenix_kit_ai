defmodule PhoenixKitAI.EmbeddingConventionsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.EmbeddingConventions, as: Conventions

  @qwen_default "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "

  # model => {query input_type, document input_type, query prefix, document prefix}
  # as sent on an OpenRouter endpoint; prefixes are the text put before the input.
  @table %{
    "google/gemini-embedding-001" => {"search_query", "search_document", nil, nil},
    "google/gemini-embedding-2" =>
      {nil, nil, "task: search result | query: ", "title: none | text: "},
    "google/gemini-embedding-2-preview" =>
      {nil, nil, "task: search result | query: ", "title: none | text: "},
    "cohere/embed-5-pro" => {"search_query", "search_document", nil, nil},
    "cohere/embed-multilingual-v3.0" => {"search_query", "search_document", nil, nil},
    "mongodb/voyage-4" => {"query", "document", nil, nil},
    "mongodb/voyage-multimodal-3.5" => {"query", "document", nil, nil},
    "nvidia/nemotron-3.5-embed-8b:free" => {"query", "passage", nil, nil},
    "nvidia/llama-nemotron-embed-vl-1b-v2:free" => {"query", "passage", nil, nil},
    "qwen/qwen3-embedding-8b" => {nil, nil, @qwen_default, nil},
    "qwen/qwen3-embedding-4b" => {nil, nil, @qwen_default, nil},
    "intfloat/multilingual-e5-large-instruct" => {nil, nil, @qwen_default, nil},
    "intfloat/multilingual-e5-large" => {nil, nil, "query: ", "passage: "},
    "intfloat/e5-base-v2" => {nil, nil, "query: ", "passage: "},
    "openai/text-embedding-3-small" => {nil, nil, nil, nil},
    "mistralai/mistral-embed-2312" => {nil, nil, nil, nil},
    "baai/bge-m3" => {nil, nil, nil, nil},
    "perplexity/pplx-embed-v1-4b" => {nil, nil, nil, nil},
    "amazon/titan-embed-text-v2" => {nil, nil, nil, nil},
    "someone/unknown-embedder" => {nil, nil, nil, nil}
  }

  defp endpoint(model, provider, settings \\ %{}),
    do: %{model: model, provider: provider, provider_settings: settings}

  defp sent(model, provider, role, opts \\ []) do
    {:ok, c} = Conventions.resolve(endpoint(model, provider), [role: role] ++ opts)
    {c.input_type, Conventions.apply_template("TEXT", c.template, c.instruction)}
  end

  describe "role × model family × provider" do
    test "every combination sends what the table says, and nothing a model would refuse" do
      for {model, {q_type, d_type, q_prefix, d_prefix}} <- @table,
          provider <- ["openrouter", "openrouter:work", "openai", "mistral"],
          role <- [nil, :query, :document, "query", "document"] do
        openrouter? = provider in ["openrouter", "openrouter:work"]
        role_atom = if is_binary(role), do: String.to_existing_atom(role), else: role

        {type, prefix} =
          case role_atom do
            nil -> {nil, nil}
            :query -> {q_type, q_prefix}
            :document -> {d_type, d_prefix}
          end

        # input_type only on OpenRouter, where the values were checked;
        # the text convention belongs to the model and applies everywhere.
        expected_type = if openrouter?, do: type
        expected_text = (prefix || "") <> "TEXT"

        assert sent(model, provider, role) == {expected_type, expected_text},
               "#{model} on #{provider} as #{inspect(role)}"
      end
    end

    test "an unknown role is refused, never guessed" do
      for bad <- [:search, "passage", 1, %{}] do
        assert {:error, :invalid_embedding_role} =
                 Conventions.resolve(endpoint("mongodb/voyage-4", "openrouter"), role: bad)
      end
    end
  end

  describe "overrides" do
    test "the call's instruction fills the query template" do
      assert {nil, "Instruct: Find images\nQuery: TEXT"} =
               sent("qwen/qwen3-embedding-8b", "openrouter", :query, instruction: "Find images")
    end

    test "the call's input_type wins over the table" do
      assert {"custom", "TEXT"} =
               sent("mongodb/voyage-4", "openrouter", :query, input_type: "custom")

      assert {"custom", "TEXT"} =
               sent("openai/text-embedding-3-small", "openai", nil, input_type: "custom")
    end

    test "provider_settings[\"embedding\"] replaces the table per key, on any provider" do
      settings = %{
        "embedding" => %{
          "query_template" => "search: ",
          "document_template" => "doc: {text} :end",
          "input_type" => %{"query" => "q", "document" => ""},
          "instruction" => "unused here"
        }
      }

      ep = endpoint("openai/text-embedding-3-small", "openai", settings)

      {:ok, q} = Conventions.resolve(ep, role: :query)
      assert q.input_type == "q"
      assert Conventions.apply_template("x", q.template, q.instruction) == "search: x"

      {:ok, d} = Conventions.resolve(ep, role: :document)
      assert d.input_type == nil
      assert Conventions.apply_template("x", d.template, d.instruction) == "doc: x :end"
    end

    test "an empty template switches a table entry off; the instruction override is used" do
      settings = %{"embedding" => %{"document_template" => "", "instruction" => "Find photos"}}

      {:ok, d} =
        Conventions.resolve(endpoint("intfloat/multilingual-e5-large", "openrouter", settings),
          role: :document
        )

      assert d.template == nil

      {:ok, q} =
        Conventions.resolve(endpoint("qwen/qwen3-embedding-8b", "openrouter", settings),
          role: :query
        )

      assert Conventions.apply_template("x", q.template, q.instruction) ==
               "Instruct: Find photos\nQuery: x"
    end

    test "a malformed override is ignored" do
      for bad <- ["nope", 3, %{"input_type" => "query"}] do
        settings = %{"embedding" => bad}

        assert {:ok, %{input_type: "query"}} =
                 Conventions.resolve(endpoint("mongodb/voyage-4", "openrouter", settings),
                   role: :query
                 )
      end
    end
  end

  describe "model facts" do
    test "batch limits, token budgets and dimensions" do
      assert Conventions.max_inputs("cohere/embed-5-pro") == 96
      assert Conventions.max_inputs("openai/text-embedding-3-small") == 2_048
      assert Conventions.max_inputs("mongodb/voyage-4") == 1_000
      assert Conventions.max_inputs("someone/else") == 100
      assert Conventions.max_batch_tokens("openai/text-embedding-3-large") == 300_000
      assert Conventions.max_batch_tokens("baai/bge-m3") == nil
      refute Conventions.dimensions?("mistralai/mistral-embed-2312")
      assert Conventions.dimensions?("openai/text-embedding-3-small")
    end

    test "normalize/1" do
      assert Conventions.normalize([3.0, 4.0]) == [0.6, 0.8]
      assert Conventions.normalize([0.0, 0.0]) == [0.0, 0.0]
      assert Conventions.normalize(["a"]) == ["a"]
      assert Conventions.normalize([3, 4]) == [0.6, 0.8]
      assert Conventions.normalize([]) == []

      # never raises on an answer already paid for
      [x, y] = Conventions.normalize([1.0e308, 1.0e308])
      assert_in_delta x, :math.sqrt(0.5), 1.0e-12
      assert_in_delta y, :math.sqrt(0.5), 1.0e-12
      huge = Integer.pow(10, 400)
      assert Conventions.normalize([huge, 1]) == [huge, 1]
    end

    test "apply_template/3 fills the template in one pass" do
      template = "Instruct: {instruction}\nQuery: {text}"

      assert Conventions.apply_template("cats", template, "Find {text} here") ==
               "Instruct: Find {text} here\nQuery: cats"

      assert Conventions.apply_template("about {instruction}", template, "Find") ==
               "Instruct: Find\nQuery: about {instruction}"

      assert Conventions.apply_template("cats", "{instruction}: ", "Find {text}") ==
               "Find {text}: cats"
    end
  end
end
