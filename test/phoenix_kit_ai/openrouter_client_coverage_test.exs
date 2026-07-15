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

    test ":tts filter accepts models with `tts` in the id/name" do
      stub_response(200, %{
        "data" => [
          # Mistral hosted shape: no modality, identified by id.
          %{"id" => "voxtral-mini-tts-2603"},
          # OpenRouter shape: tts model with a modality that isn't text->text.
          %{"id" => "mistralai/Voxtral-4B-TTS", "name" => "Voxtral 4B TTS"},
          %{"id" => "anthropic/claude-3-haiku", "architecture" => %{"modality" => "text->text"}}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :tts)
      ids = Enum.map(models, & &1.id) |> Enum.sort()
      assert ids == ["mistralai/Voxtral-4B-TTS", "voxtral-mini-tts-2603"]
    end

    test ":text filter excludes TTS models even when they carry no modality" do
      # A no-modality model normally matches :text (Mistral chat models),
      # but a TTS model must not leak into the chat picker.
      stub_response(200, %{
        "data" => [
          %{"id" => "mistral-large-latest"},
          %{"id" => "voxtral-mini-tts-2603"}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :text)
      assert Enum.map(models, & &1.id) == ["mistral-large-latest"]
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

    test ":text filter accepts models with no architecture (Mistral / DeepSeek shape)" do
      # Mistral and DeepSeek's /v1/models responses don't return an
      # `architecture` field at all — the strict `modality == "text->text"`
      # match would drop every one of their models. The fetcher's
      # `model_matches_type?` was loosened to treat missing modality as
      # text-by-default; this test pins that.
      stub_response(200, %{
        "data" => [
          %{"id" => "mistral-large-latest", "object" => "model"},
          %{"id" => "deepseek-chat", "object" => "model"}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :text)
      ids = Enum.map(models, & &1.id) |> Enum.sort()
      assert ids == ["deepseek-chat", "mistral-large-latest"]
    end

    test ":vision filter still rejects models with no architecture" do
      # Loosening `:text` to accept missing-modality models doesn't
      # cascade to other filter types — `:vision` requires an explicit
      # `text+image->text` modality.
      stub_response(200, %{
        "data" => [
          %{"id" => "mistral-large-latest", "object" => "model"},
          %{"id" => "v/m", "architecture" => %{"modality" => "text+image->text"}}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :vision)
      assert Enum.map(models, & &1.id) == ["v/m"]
    end

    test ":text filter excludes xAI's grok-imagine-* image/video models" do
      # xAI's `/v1/models` has no `architecture` field on ANY model
      # (chat or media-gen alike), so `grok-imagine-image`/`-video` would
      # otherwise slip into the chat picker via the no-modality
      # "assume text" fallback. `image_price` (image models) and the
      # `-image`/`-video` id substring (video models, which carry no
      # pricing fields at all) both need to be excluded.
      stub_response(200, %{
        "data" => [
          %{"id" => "grok-4.3", "object" => "model", "prompt_text_token_price" => 12_500},
          %{"id" => "grok-imagine-image", "object" => "model", "image_price" => 200_000_000},
          %{"id" => "grok-imagine-video", "object" => "model"}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :text)
      assert Enum.map(models, & &1.id) == ["grok-4.3"]
    end

    test ":image_gen surfaces xAI's grok-imagine-image (no modality field to match on)" do
      # Same no-modality gap as the :text exclusion above, but for
      # inclusion instead: grok-imagine-image genuinely is an image-gen
      # model, so it must show up here — grok-imagine-video must not
      # (no dedicated :video_gen type exists yet), and the regular chat
      # model must not either.
      stub_response(200, %{
        "data" => [
          %{"id" => "grok-4.3", "object" => "model", "prompt_text_token_price" => 12_500},
          %{"id" => "grok-imagine-image", "object" => "model", "image_price" => 200_000_000},
          %{"id" => "grok-imagine-image-quality", "object" => "model"},
          %{"id" => "grok-imagine-video", "object" => "model"}
        ]
      })

      {:ok, models} = OpenRouterClient.fetch_models("sk-x", model_type: :image_gen)

      assert Enum.map(models, & &1.id) |> Enum.sort() == [
               "grok-imagine-image",
               "grok-imagine-image-quality"
             ]
    end

    test "normalizes xAI's flat token-price fields to dollars-per-token" do
      # xAI reports `prompt_text_token_price` / `completion_text_token_price`
      # in USD cents per 100,000,000 tokens instead of OpenRouter's nested
      # `pricing` map — without a conversion every xAI model showed $0.00/M.
      stub_response(200, %{
        "data" => [
          %{
            "id" => "grok-4.3",
            "object" => "model",
            "prompt_text_token_price" => 12_500,
            "completion_text_token_price" => 25_000
          }
        ]
      })

      {:ok, [model]} = OpenRouterClient.fetch_models("sk-x", model_type: :text)
      assert_in_delta model.pricing["prompt"], 0.00000125, 1.0e-12
      assert_in_delta model.pricing["completion"], 0.0000025, 1.0e-12
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

    test ":fallback_provider groups slash-less IDs under the given key (Mistral/DeepSeek)" do
      # Mistral (`mistral-large-latest`) and DeepSeek (`deepseek-chat`)
      # model IDs are flat strings — the OpenRouter `provider/model`
      # split returns the whole id as the provider. Without
      # `:fallback_provider`, each model would land in its own one-off
      # group (the picker would render dozens of single-model groups).
      # With it, all of a provider's models cluster under one entry.
      stub_response(200, %{
        "data" => [
          %{"id" => "mistral-large-latest", "object" => "model"},
          %{"id" => "mistral-small-latest", "object" => "model"},
          %{"id" => "codestral-latest", "object" => "model"}
        ]
      })

      {:ok, grouped} =
        OpenRouterClient.fetch_models_grouped("sk-x",
          model_type: :all,
          fallback_provider: "mistral"
        )

      assert [{"mistral", models}] = grouped
      assert length(models) == 3
    end

    test ":base_url overrides the default OpenRouter URL" do
      # Without this opt the model fetcher hardcodes
      # `https://openrouter.ai/api/v1/models` regardless of which
      # provider's endpoint the operator is configuring. Pass
      # `:base_url` to hit Mistral / DeepSeek / any other
      # OpenAI-compatible /models endpoint.
      stub_response(200, %{
        "data" => [
          %{"id" => "deepseek-chat", "object" => "model"}
        ]
      })

      {:ok, grouped} =
        OpenRouterClient.fetch_models_grouped("sk-x",
          model_type: :all,
          base_url: "https://api.deepseek.com/v1",
          fallback_provider: "deepseek"
        )

      assert [{"deepseek", [model]}] = grouped
      assert model.id == "deepseek-chat"
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

  describe "fetch_voices/2" do
    # Shape mirrors a live Mistral GET /v1/audio/voices response.
    defp voices_payload do
      %{
        "items" => [
          %{
            "slug" => "en_paul_neutral",
            "name" => "Paul - Neutral",
            "languages" => ["en_us"],
            "gender" => "male",
            "tags" => ["relaxed", "neutral"]
          },
          %{
            "slug" => "gb_jane_sarcasm",
            "name" => "Jane - Sarcasm",
            "languages" => ["en_gb"],
            "gender" => "female",
            "tags" => ["dry"]
          }
        ],
        "total" => 2
      }
    end

    test "200 returns a normalized voice list (slug/name/language/gender)" do
      stub_response(200, voices_payload())

      assert {:ok, voices} =
               OpenRouterClient.fetch_voices("sk-x", base_url: "https://api.mistral.ai/v1")

      assert [
               %{
                 slug: "en_paul_neutral",
                 name: "Paul - Neutral",
                 language: "en_us",
                 gender: "male"
               },
               %{
                 slug: "gb_jane_sarcasm",
                 name: "Jane - Sarcasm",
                 language: "en_gb",
                 gender: "female"
               }
             ] = voices
    end

    test "drops items without a slug" do
      stub_response(200, %{"items" => [%{"name" => "no slug"}, %{"slug" => "ok"}]})
      assert {:ok, [%{slug: "ok"}]} = OpenRouterClient.fetch_voices("sk-x")
    end

    test "200 without items key returns :invalid_response_format" do
      stub_response(200, %{"foo" => "bar"})
      assert {:error, :invalid_response_format} = OpenRouterClient.fetch_voices("sk-x")
    end

    test "200 with non-JSON body returns :invalid_json_response" do
      stub_raw(200, "<html>")
      assert {:error, :invalid_json_response} = OpenRouterClient.fetch_voices("sk-x")
    end

    test "401 returns :invalid_api_key" do
      stub_response(401, %{})
      assert {:error, :invalid_api_key} = OpenRouterClient.fetch_voices("sk-x")
    end

    test "404 (provider has no voices endpoint) returns {:api_error, 404}" do
      stub_response(404, %{})
      assert {:error, {:api_error, 404}} = OpenRouterClient.fetch_voices("sk-x")
    end

    test "transport error returns {:connection_error, reason}" do
      stub_transport_error(:nxdomain)
      assert {:error, {:connection_error, :nxdomain}} = OpenRouterClient.fetch_voices("sk-x")
    end
  end

  describe "fetch_xai_voices/2" do
    # Shape mirrors a live xAI GET /v1/tts/voices response — a different
    # envelope key ("voices", not "items") and per-voice fields
    # (voice_id/name/language) than fetch_voices/2's Mistral shape.
    defp xai_voices_payload do
      %{
        "voices" => [
          %{"voice_id" => "ara", "name" => "Ara", "language" => "en"},
          %{"voice_id" => "eve", "name" => "Eve", "language" => "en"}
        ]
      }
    end

    test "200 returns a normalized voice list (voice_id/name/language)" do
      stub_response(200, xai_voices_payload())

      assert {:ok, voices} =
               OpenRouterClient.fetch_xai_voices("sk-x", base_url: "https://api.x.ai/v1")

      assert [
               %{voice_id: "ara", name: "Ara", language: "en"},
               %{voice_id: "eve", name: "Eve", language: "en"}
             ] = voices
    end

    test "drops entries without a voice_id" do
      stub_response(200, %{"voices" => [%{"name" => "no id"}, %{"voice_id" => "ok"}]})
      assert {:ok, [%{voice_id: "ok"}]} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "falls back to voice_id when name is missing" do
      stub_response(200, %{"voices" => [%{"voice_id" => "ara"}]})
      assert {:ok, [%{voice_id: "ara", name: "ara"}]} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "200 without voices key returns :invalid_response_format" do
      stub_response(200, %{"foo" => "bar"})
      assert {:error, :invalid_response_format} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "200 with non-JSON body returns :invalid_json_response" do
      stub_raw(200, "<html>")
      assert {:error, :invalid_json_response} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "401 returns :invalid_api_key" do
      stub_response(401, %{})
      assert {:error, :invalid_api_key} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "500 returns {:api_error, 500}" do
      stub_response(500, %{})
      assert {:error, {:api_error, 500}} = OpenRouterClient.fetch_xai_voices("sk-x")
    end

    test "transport error returns {:connection_error, reason}" do
      stub_transport_error(:nxdomain)
      assert {:error, {:connection_error, :nxdomain}} = OpenRouterClient.fetch_xai_voices("sk-x")
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

  describe "maybe_add_header / maybe_add_opt empty-string branches" do
    test "build_headers with empty http_referer + x_title omits both headers" do
      # Pin `maybe_add_header(headers, _name, "") -> headers` (no-op).
      headers = OpenRouterClient.build_headers("sk-test", http_referer: "", x_title: "")

      assert {"Authorization", "Bearer sk-test"} in headers
      refute Enum.any?(headers, fn {name, _} -> name == "HTTP-Referer" end)
      refute Enum.any?(headers, fn {name, _} -> name == "X-Title" end)
    end

    test "build_headers_from_account with empty settings strings omits both headers" do
      # Pin `maybe_add_opt(opts, _key, "") -> opts` (no-op).
      account = %{
        api_key: "sk-test",
        settings: %{"http_referer" => "", "x_title" => ""}
      }

      headers = OpenRouterClient.build_headers_from_account(account)

      refute Enum.any?(headers, fn {name, _} -> name == "HTTP-Referer" end)
      refute Enum.any?(headers, fn {name, _} -> name == "X-Title" end)
    end
  end

  describe "parse_price — partial pricing map (one key missing)" do
    test "model with prompt-price only triggers parse_price(nil) for completion" do
      # Pin `parse_price(nil)` clause via a model whose pricing map
      # has only `prompt` set; `pricing["completion"]` returns nil.
      stub_response(200, %{
        "data" => [
          %{
            "id" => "partial-pricing/test",
            "context_length" => 1000,
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            },
            "pricing" => %{"prompt" => "0.001"}
            # Missing "completion" key intentionally — exercises parse_price(nil).
          }
        ]
      })

      assert {:ok, [model]} = OpenRouterClient.fetch_models("sk-test")
      assert model.id == "partial-pricing/test"
      assert model.pricing["completion"] == 0
    end
  end

  describe "warn_legacy_api_key/1 — :persistent_term throttle (one-shot)" do
    test "second call for the same endpoint UUID is a silent no-op" do
      # Pin the throttle: a fresh endpoint UUID warns once, the
      # second call hits `:persistent_term.get/2` → `:warned` → `:ok`.
      # Without the throttle, every chat completion would re-flood the
      # log for legacy api_key endpoints. We drive the warning via the
      # public `build_headers_from_endpoint/1` which calls
      # `resolve_api_key` → `warn_legacy_api_key`.
      uuid = Ecto.UUID.generate()

      endpoint = %PhoenixKitAI.Endpoint{
        uuid: uuid,
        name: "Legacy",
        provider: "openrouter:nonexistent",
        provider_settings: %{},
        api_key: "sk-legacy"
      }

      first =
        capture_log(fn ->
          OpenRouterClient.warn_legacy_api_key(endpoint)
        end)

      second =
        capture_log(fn ->
          OpenRouterClient.warn_legacy_api_key(endpoint)
        end)

      # First call logs; second is silent (the throttle fired).
      assert first =~ "deprecated endpoint.api_key"

      refute second =~ "deprecated endpoint.api_key",
             "expected second call to be a silent no-op via :persistent_term"
    end
  end

  describe "extract_provider — non-string ids fall through to \"Unknown\"" do
    test "non-binary id returns \"Unknown\"" do
      # Catch-all clause for non-string ids (data that slipped past the
      # public API — malformed JSON, etc.).
      assert OpenRouterClient.extract_provider(nil) == "Unknown"
      assert OpenRouterClient.extract_provider(123) == "Unknown"
    end
  end

  describe "extract_model_name — non-binary fall-through" do
    test "non-binary id returns \"Unknown\"" do
      # `_ -> "Unknown"` clause when the id isn't a binary.
      assert OpenRouterClient.extract_model_name(nil) == "Unknown"
      assert OpenRouterClient.extract_model_name(123) == "Unknown"
    end
  end

  describe "humanize_provider — unknown slug fallback" do
    test "non-binary input returns \"Unknown\"" do
      assert OpenRouterClient.humanize_provider(nil) == "Unknown"
      assert OpenRouterClient.humanize_provider(:not_a_string) == "Unknown"
    end
  end

  describe "parse_price — pricing-shape edges via fetch_models" do
    test "models with non-number pricing strings, missing prices, and bare-id slugs all parse" do
      stub_response(200, %{
        "data" => [
          # No prices at all.
          %{
            "id" => "no-prefix-id",
            "context_length" => 1000,
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            }
          },
          # Pricing as a non-numeric string (parse_price falls through
          # to `:error -> 0`).
          %{
            "id" => "broken-prices/test",
            "context_length" => 1000,
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            },
            "pricing" => %{"prompt" => "not-a-number", "completion" => "also-bad"}
          },
          # Pricing as an integer (number-clause matches directly).
          %{
            "id" => "int-prices/test",
            "context_length" => 1000,
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            },
            "pricing" => %{"prompt" => 5, "completion" => 10}
          },
          # Pricing as an unrecognised shape (parse_price `_ -> 0`).
          %{
            "id" => "weird-prices/test",
            "context_length" => 1000,
            "architecture" => %{
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            },
            "pricing" => %{"prompt" => %{nested: "map"}, "completion" => [1, 2]}
          }
        ]
      })

      assert {:ok, models} = OpenRouterClient.fetch_models("sk-test")

      # All four models survived — none crashed on weird pricing shapes.
      ids = Enum.map(models, & &1.id)
      assert "no-prefix-id" in ids
      assert "broken-prices/test" in ids
      assert "int-prices/test" in ids
      assert "weird-prices/test" in ids
    end
  end
end
