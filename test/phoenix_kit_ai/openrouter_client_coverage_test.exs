defmodule PhoenixKitAI.OpenRouterClientCoverageTest do
  @moduledoc """
  Coverage push for `OpenRouterClient`.

  Uses `Req.Test` plug stubs (built into Req — no external dep) to
  exercise every branch of `validate_api_key/1`, `fetch_models/2`,
  `fetch_model/3`, and the various group/format/humanise helpers
  that the existing test file does not cover. Plug routing is opted
  in via `Application.put_env(:phoenix_kit_ai, :req_options, plug: ...)`
  inside the test setup; production code path is unchanged.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.{AIModel, OpenRouterClient}

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.OpenRouterClientCoverageTest},
      retry: false
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

  describe "validate_api_key/1" do
    test "200 with model list returns count" do
      stub_response(200, %{"data" => [%{"id" => "a"}, %{"id" => "b"}]})

      assert {:ok, %{valid: true, models_count: 2}} =
               OpenRouterClient.validate_api_key("sk-x")
    end

    test "200 with non-list data still returns :ok" do
      stub_response(200, %{"data" => "weird"})

      assert {:ok, %{valid: true}} = OpenRouterClient.validate_api_key("sk-x")
    end

    test "200 with non-JSON body returns :invalid_json_response" do
      stub_raw(200, "<html>not json</html>")

      assert {:error, :invalid_json_response} = OpenRouterClient.validate_api_key("sk-x")
    end

    test "401 returns :invalid_api_key" do
      log =
        capture_log(fn ->
          stub_response(401, %{"error" => "no"})
          assert {:error, :invalid_api_key} = OpenRouterClient.validate_api_key("sk-x")
        end)

      assert log =~ "401"
    end

    test "403 returns :api_key_forbidden" do
      stub_response(403, %{})
      assert {:error, :api_key_forbidden} = OpenRouterClient.validate_api_key("sk-x")
    end

    test "non-2xx status returns {:api_error, status}" do
      stub_response(503, %{})
      assert {:error, {:api_error, 503}} = OpenRouterClient.validate_api_key("sk-x")
    end

    test "transport error returns {:connection_error, reason}" do
      stub_transport_error(:nxdomain)

      assert {:error, {:connection_error, :nxdomain}} =
               OpenRouterClient.validate_api_key("sk-x")
    end
  end

  describe "fetch_models/2" do
    test "200 with data returns normalized models" do
      stub_response(200, %{
        "data" => [
          %{
            "id" => "anthropic/claude-3-haiku",
            "name" => "Claude 3 Haiku",
            "context_length" => 200_000,
            "architecture" => %{"modality" => "text->text"},
            "supported_parameters" => ["temperature"],
            "pricing" => %{"prompt" => "0.0001", "completion" => "0.0005"}
          }
        ]
      })

      assert {:ok, [%AIModel{id: "anthropic/claude-3-haiku"}]} =
               OpenRouterClient.fetch_models("sk-x")
    end

    test ":text filter excludes non-text->text modality" do
      stub_response(200, %{
        "data" => [
          %{"id" => "v/m", "architecture" => %{"modality" => "text+image->text"}},
          %{"id" => "t/m", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :text)
      assert Enum.map(models, & &1.id) == ["t/m"]
    end

    test ":vision filter accepts text+image->text" do
      stub_response(200, %{
        "data" => [
          %{"id" => "v/m", "architecture" => %{"modality" => "text+image->text"}},
          %{"id" => "t/m", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :vision)
      assert Enum.map(models, & &1.id) == ["v/m"]
    end

    test ":image_gen filter accepts text->text+image and text+image->text+image" do
      stub_response(200, %{
        "data" => [
          %{"id" => "img1", "architecture" => %{"modality" => "text->text+image"}},
          %{"id" => "img2", "architecture" => %{"modality" => "text+image->text+image"}},
          %{"id" => "txt", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :image_gen)
      ids = Enum.map(models, & &1.id) |> Enum.sort()
      assert ids == ["img1", "img2"]
    end

    test "200 with non-list data returns :invalid_response_format" do
      stub_response(200, %{"data" => "weird"})
      assert {:error, :invalid_response_format} = OpenRouterClient.fetch_models("sk-x")
    end

    test "200 with non-JSON returns :invalid_json_response" do
      stub_raw(200, "<html>")
      assert {:error, :invalid_json_response} = OpenRouterClient.fetch_models("sk-x")
    end

    test "401 returns :invalid_api_key" do
      stub_response(401, %{})
      assert {:error, :invalid_api_key} = OpenRouterClient.fetch_models("sk-x")
    end

    test "non-2xx status returns {:api_error, status}" do
      capture_log(fn ->
        stub_response(500, %{})
        assert {:error, {:api_error, 500}} = OpenRouterClient.fetch_models("sk-x")
      end)
    end

    test "transport error returns {:connection_error, reason}" do
      capture_log(fn ->
        stub_transport_error(:timeout)
        assert {:error, {:connection_error, :timeout}} = OpenRouterClient.fetch_models("sk-x")
      end)
    end
  end

  describe "fetch_models_grouped + fetch_models_by_type" do
    test "groups by provider prefix" do
      stub_response(200, %{
        "data" => [
          %{"id" => "anthropic/a", "architecture" => %{"modality" => "text->text"}},
          %{"id" => "anthropic/b", "architecture" => %{"modality" => "text->text"}},
          %{"id" => "openai/c", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      {:ok, grouped} = OpenRouterClient.fetch_models_grouped("sk-x")
      providers = Enum.map(grouped, fn {p, _} -> p end)
      assert "anthropic" in providers
      assert "openai" in providers
    end

    test "fetch_models_by_type/3 routes through fetch_models_grouped" do
      stub_response(200, %{
        "data" => [
          %{"id" => "v/img", "architecture" => %{"modality" => "text+image->text"}}
        ]
      })

      {:ok, grouped} = OpenRouterClient.fetch_models_by_type("sk-x", :vision)
      assert is_list(grouped)
    end

    test "fetch_models_grouped returns the underlying error" do
      stub_response(401, %{})
      assert {:error, :invalid_api_key} = OpenRouterClient.fetch_models_grouped("sk-x")
    end
  end

  describe "fetch_model/3" do
    test "finds the model when present" do
      stub_response(200, %{
        "data" => [
          %{"id" => "a/b", "architecture" => %{"modality" => "text->text"}},
          %{"id" => "x/y", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      assert {:ok, %AIModel{id: "x/y"}} = OpenRouterClient.fetch_model("sk-x", "x/y")
    end

    test "returns :model_not_found when missing" do
      stub_response(200, %{"data" => []})
      assert {:error, :model_not_found} = OpenRouterClient.fetch_model("sk-x", "missing/m")
    end

    test "propagates the underlying error" do
      stub_response(401, %{})
      assert {:error, :invalid_api_key} = OpenRouterClient.fetch_model("sk-x", "a/b")
    end
  end

  describe "humanize_provider / extract_provider / extract_model_name" do
    test "humanize_provider — covers explicit clauses + dash-split fallback" do
      assert OpenRouterClient.humanize_provider("openai") == "OpenAI"
      assert OpenRouterClient.humanize_provider("anthropic") == "Anthropic"
      assert OpenRouterClient.humanize_provider("meta-llama") == "Meta Llama"
      assert OpenRouterClient.humanize_provider("arcee-ai") == "Arcee AI"
      assert OpenRouterClient.humanize_provider("unknown-name") == "Unknown Name"
      assert OpenRouterClient.humanize_provider(nil) == "Unknown"
    end

    test "humanize_provider — every named slug returns its branded label" do
      # Exercises each explicit clause so the dispatch isn't silently
      # broken by an accidental alias-rename or duplicate slug.
      cases = [
        {"google", "Google"},
        {"mistralai", "Mistral AI"},
        {"cohere", "Cohere"},
        {"deepseek", "DeepSeek"},
        {"x-ai", "xAI"},
        {"nvidia", "NVIDIA"},
        {"microsoft", "Microsoft"},
        {"amazon", "Amazon"},
        {"alibaba", "Alibaba"},
        {"baidu", "Baidu"},
        {"tencent", "Tencent"},
        {"ibm-granite", "IBM Granite"},
        {"ai21", "AI21 Labs"},
        {"perplexity", "Perplexity"},
        {"inflection", "Inflection"},
        {"qwen", "Qwen"},
        {"nousresearch", "Nous Research"},
        {"aion-labs", "Aion Labs"},
        {"allenai", "Allen AI"},
        {"eleutherai", "EleutherAI"},
        {"cognitivecomputations", "Cognitive Computations"},
        {"thedrummer", "TheDrummer"},
        {"neversleep", "NeverSleep"},
        {"anthracite-org", "Anthracite"},
        {"arliai", "ArliAI"},
        {"mancer", "Mancer"},
        {"openrouter", "OpenRouter"},
        {"minimax", "MiniMax"},
        {"moonshotai", "Moonshot AI"},
        {"deepcogito", "DeepCogito"},
        {"liquid", "Liquid"},
        {"essentialai", "Essential AI"},
        {"tngtech", "TNG Tech"},
        {"kwaipilot", "KwaiPilot"},
        {"z-ai", "Z-AI"},
        {"nex-agi", "Nex AGI"},
        {"prime-intellect", "Prime Intellect"}
      ]

      for {slug, label} <- cases do
        assert OpenRouterClient.humanize_provider(slug) == label,
               "humanize_provider(#{inspect(slug)}) expected #{inspect(label)}"
      end
    end

    test "extract_provider — provider/model + bare (humanizes) + non-binary" do
      assert OpenRouterClient.extract_provider("anthropic/claude-3-opus") == "Anthropic"
      # Bare strings are humanized as a single-word provider.
      assert OpenRouterClient.extract_provider("bare") == "Bare"
      assert OpenRouterClient.extract_provider(nil) == "Unknown"
    end

    test "extract_model_name — provider/model + bare + non-binary" do
      assert OpenRouterClient.extract_model_name("anthropic/claude-3-opus") == "claude-3-opus"
      assert OpenRouterClient.extract_model_name("bare") == "bare"
      assert OpenRouterClient.extract_model_name(nil) == "Unknown"
    end
  end

  describe "model_option / get_model_max_tokens / model_supports_parameter?" do
    test "model_option/1 — AIModel struct + map shapes" do
      m = %AIModel{id: "openai/gpt-4", name: "GPT-4", supported_parameters: []}
      {label, value} = OpenRouterClient.model_option(m)
      assert label =~ "GPT-4"
      assert value == "openai/gpt-4"
    end

    test "model_option/1 — AIModel without name falls back to id" do
      m = %AIModel{id: "x/y", name: nil, supported_parameters: []}
      assert {"x/y", "x/y"} = OpenRouterClient.model_option(m)
    end

    test "model_option/1 — map with name + map with id only + missing both" do
      assert {"GPT-4 (OpenAI)", "openai/gpt-4"} =
               OpenRouterClient.model_option(%{"id" => "openai/gpt-4", "name" => "GPT-4"})

      assert {"x/y", "x/y"} = OpenRouterClient.model_option(%{"id" => "x/y"})
      assert {"Unknown", ""} = OpenRouterClient.model_option(%{})
    end

    test "get_model_max_tokens — explicit + context-length fallback + ultimate fallback" do
      assert OpenRouterClient.get_model_max_tokens(%AIModel{
               id: "x",
               max_completion_tokens: 8192
             }) == 8192

      assert OpenRouterClient.get_model_max_tokens(%AIModel{
               id: "x",
               max_completion_tokens: nil,
               context_length: 16_384
             }) == 4096

      assert OpenRouterClient.get_model_max_tokens(%AIModel{
               id: "x",
               max_completion_tokens: nil,
               context_length: nil
             }) == 4096
    end

    test "get_model_max_tokens — map shape" do
      assert OpenRouterClient.get_model_max_tokens(%{"max_completion_tokens" => 1024}) == 1024
      assert OpenRouterClient.get_model_max_tokens(%{"context_length" => 8000}) == 2000
      assert OpenRouterClient.get_model_max_tokens(%{}) == 4096
    end

    test "model_supports_parameter? — struct + map" do
      m = %AIModel{id: "x", supported_parameters: ["temperature"]}
      assert OpenRouterClient.model_supports_parameter?(m, "temperature")
      refute OpenRouterClient.model_supports_parameter?(m, "tools")

      assert OpenRouterClient.model_supports_parameter?(
               %{"supported_parameters" => ["temperature"]},
               "temperature"
             )

      refute OpenRouterClient.model_supports_parameter?(%{}, "temperature")
    end
  end

  describe "build_headers — include_usage flag" do
    test "include_usage=true adds X-Include-Usage" do
      headers = OpenRouterClient.build_headers("sk-x", include_usage: true)
      assert {"X-Include-Usage", "true"} in headers
    end

    test "include_usage=false omits X-Include-Usage" do
      headers = OpenRouterClient.build_headers("sk-x", include_usage: false)
      refute Enum.any?(headers, fn {k, _} -> k == "X-Include-Usage" end)
    end

    test "build_headers nil api key emits a Logger.error and returns content-type only" do
      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers(nil)
          assert headers == [{"Content-Type", "application/json"}]
        end)

      assert log =~ "build_headers called with nil"
    end
  end

  describe "build_headers_from_account" do
    test "passes settings into build_headers/2" do
      headers =
        OpenRouterClient.build_headers_from_account(%{
          api_key: "sk-acc",
          settings: %{"http_referer" => "https://x", "x_title" => "Y"}
        })

      assert {"HTTP-Referer", "https://x"} in headers
      assert {"X-Title", "Y"} in headers
    end
  end

  describe "fetch_embedding_models_grouped" do
    test "groups embedding models when called with a non-prefixed id" do
      Application.put_env(:phoenix_kit_ai, :embedding_models, [
        %{
          "id" => "bare-id",
          "name" => "Bare",
          "context_length" => 100,
          "dimensions" => 100,
          "pricing" => %{"prompt" => 0, "completion" => 0}
        }
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :embedding_models) end)

      {:ok, grouped} = OpenRouterClient.fetch_embedding_models_grouped("sk-x")
      providers = Enum.map(grouped, fn {p, _} -> p end)
      # Bare id with no slash falls into "bare-id" group (whole string)
      assert Enum.any?(providers, fn p -> p == "bare-id" end)
    end
  end

  describe "base_url/0" do
    test "returns the OpenRouter constant" do
      assert OpenRouterClient.base_url() == "https://openrouter.ai/api/v1"
    end
  end

  describe "extract_model_name + extract_provider — multi-slash IDs" do
    test "extract_model_name with provider/model/extra returns middle slug" do
      assert OpenRouterClient.extract_model_name("a/b/c") == "b"
    end

    test "extract_model_name with empty string returns the empty string" do
      # The empty string is a binary, so the binary-clause matches and
      # `String.split("", "/")` returns `[""]`, hitting the bare-name
      # fallback.
      assert OpenRouterClient.extract_model_name("") == ""
    end
  end

  describe "fetch_embedding_models — non-list config tolerated" do
    test "non-list :embedding_models config is treated as []" do
      Application.put_env(:phoenix_kit_ai, :embedding_models, "not a list")
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :embedding_models) end)

      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-x")
      # Only built-ins survive; user-contributed list is rejected.
      assert is_list(models)
      assert length(models) >= 8
    end
  end
end
