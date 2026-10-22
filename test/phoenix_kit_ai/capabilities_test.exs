defmodule PhoenixKitAI.CapabilitiesTest do
  @moduledoc """
  What a catalogue row says a model can do (OpenRouter's `/models`,
  Anthropic's native `/v1/models`), which catalogue an endpoint reads, and
  how a capability declared on the endpoint combines with the catalogue.
  No process and no database here — see `CapabilitiesServerTest`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Endpoint

  describe "from_openrouter/1" do
    test "image among the input modalities is vision; a text-only input is not" do
      assert %Capabilities{vision: :yes} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{
                   "input_modalities" => ["text", "image", "video", "file", "audio"],
                   "output_modalities" => ["text"]
                 }
               })

      assert %Capabilities{vision: :no} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{
                   "input_modalities" => ["text"],
                   "output_modalities" => ["text"]
                 }
               })
    end

    test "without input_modalities the left side of modality decides" do
      assert %Capabilities{vision: :yes} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{"modality" => "text+image->text"}
               })

      assert %Capabilities{vision: :no} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{"modality" => "text->text+image"}
               })
    end

    test "a row that says nothing about its input is unknown, not text-only" do
      assert %Capabilities{vision: :unknown} = Capabilities.from_openrouter(%{"id" => "x"})
    end

    test "tools, structured outputs and response format map to tools, json_schema and json" do
      caps =
        Capabilities.from_openrouter(%{
          "supported_parameters" => [
            "tools",
            "tool_choice",
            "response_format",
            "structured_outputs"
          ]
        })

      assert %Capabilities{tools: :yes, json_schema: :yes, json: :yes} = caps
    end

    test "response_format without structured_outputs is JSON only" do
      assert %Capabilities{tools: :no, json_schema: :no, json: :yes} =
               Capabilities.from_openrouter(%{
                 "supported_parameters" => ["temperature", "response_format"]
               })
    end

    test "neither parameter: no JSON at all; no parameter list: unknown" do
      assert %Capabilities{json_schema: :no, json: :no} =
               Capabilities.from_openrouter(%{"supported_parameters" => ["temperature"]})

      assert %Capabilities{tools: :unknown, json_schema: :unknown, json: :unknown} =
               Capabilities.from_openrouter(%{})
    end

    test "context length and source; reads a normalised AIModel the same way" do
      model = %AIModel{
        id: "google/gemini-flash-latest",
        context_length: 1_048_576,
        supported_parameters: ["tools", "structured_outputs"],
        architecture: %{"input_modalities" => ["text", "image"]}
      }

      assert %Capabilities{
               vision: :yes,
               tools: :yes,
               json_schema: :yes,
               json: :yes,
               context_length: 1_048_576,
               source: :catalogue,
               lifecycle: nil
             } = Capabilities.from_openrouter(model)
    end
  end

  describe "from_anthropic/1" do
    defp anthropic_row(overrides) do
      Map.merge(
        %{
          "id" => "claude-opus-5-5",
          "type" => "model",
          "display_name" => "Claude Opus 5.5",
          "max_input_tokens" => 1_000_000,
          "max_tokens" => 128_000,
          "lifecycle" => "active",
          "capabilities" => %{
            "image_input" => %{"supported" => true},
            "structured_outputs" => %{"supported" => true}
          }
        },
        overrides
      )
    end

    test "image input is vision; tools always; the compatibility layer has no JSON schema" do
      assert %Capabilities{
               vision: :yes,
               tools: :yes,
               json_schema: :no,
               json: :yes,
               context_length: 1_000_000,
               lifecycle: :active,
               source: :catalogue
             } = Capabilities.from_anthropic(anthropic_row(%{}))
    end

    test "image input not supported is no vision" do
      row = anthropic_row(%{"capabilities" => %{"image_input" => %{"supported" => false}}})
      assert %Capabilities{vision: :no} = Capabilities.from_anthropic(row)
    end

    test "capabilities null leaves vision unknown" do
      assert %Capabilities{vision: :unknown, tools: :yes, json_schema: :no} =
               Capabilities.from_anthropic(anthropic_row(%{"capabilities" => nil}))
    end

    test "lifecycle deprecated and retired; anything else is nil" do
      assert %Capabilities{lifecycle: :deprecated} =
               Capabilities.from_anthropic(anthropic_row(%{"lifecycle" => "deprecated"}))

      assert %Capabilities{lifecycle: :retired} =
               Capabilities.from_anthropic(anthropic_row(%{"lifecycle" => "retired"}))

      assert %Capabilities{lifecycle: nil} =
               Capabilities.from_anthropic(anthropic_row(%{"lifecycle" => "sunset"}))
    end
  end

  describe "fields for the request rules" do
    test "OpenRouter keeps the parameter list; none given stays nil" do
      assert %Capabilities{supported_parameters: ["tools", "top_k"]} =
               Capabilities.from_openrouter(%{"supported_parameters" => ["tools", "top_k"]})

      assert %Capabilities{supported_parameters: nil} = Capabilities.from_openrouter(%{})
    end

    test "Anthropic says whether thinking can be turned off" do
      takes = %{"thinking" => %{"types" => %{"disabled" => %{"supported" => true}}}}
      refuses = %{"thinking" => %{"types" => %{"disabled" => %{"supported" => false}}}}
      silent = %{"thinking" => %{"types" => %{"adaptive" => %{"supported" => true}}}}

      assert %Capabilities{thinking_disabled: :yes} =
               Capabilities.from_anthropic(%{"capabilities" => takes})

      assert %Capabilities{thinking_disabled: :no} =
               Capabilities.from_anthropic(%{"capabilities" => refuses})

      assert %Capabilities{thinking_disabled: :unknown} =
               Capabilities.from_anthropic(%{"capabilities" => silent})

      assert %Capabilities{thinking_disabled: :unknown} =
               Capabilities.from_anthropic(%{"capabilities" => nil})
    end
  end

  describe "catalogue_kind/2" do
    test "by the provider key or by the host of the base URL" do
      assert Capabilities.catalogue_kind("openrouter", nil) == :openrouter
      assert Capabilities.catalogue_kind(nil, "https://openrouter.ai/api/v1") == :openrouter
      assert Capabilities.catalogue_kind("anthropic", nil) == :anthropic
      assert Capabilities.catalogue_kind("custom", "https://api.anthropic.com/v1/") == :anthropic
    end

    test "every other provider has no catalogue" do
      assert Capabilities.catalogue_kind("mistral", "https://api.mistral.ai/v1") == nil
      assert Capabilities.catalogue_kind("deepseek", "https://api.deepseek.com") == nil
      assert Capabilities.catalogue_kind(nil, nil) == nil
    end
  end

  describe "resolved_base_url/1" do
    test "an empty base URL resolves to the provider's default, without a trailing slash" do
      assert Capabilities.resolved_base_url(%Endpoint{provider: "openrouter", base_url: nil}) ==
               "https://openrouter.ai/api/v1"

      assert Capabilities.resolved_base_url(%Endpoint{provider: "openrouter", base_url: ""}) ==
               "https://openrouter.ai/api/v1"

      assert Capabilities.resolved_base_url(%Endpoint{
               provider: "openrouter",
               base_url: " https://openrouter.ai/api/v1/ "
             }) == "https://openrouter.ai/api/v1"
    end

    test "anthropic resolves even when the registry has no such provider" do
      assert Capabilities.resolved_base_url(%Endpoint{provider: "anthropic", base_url: nil}) ==
               "https://api.anthropic.com/v1"
    end

    test "a provider with no default and no base URL resolves to nil" do
      assert Capabilities.resolved_base_url(%Endpoint{
               provider: "no-such-provider",
               base_url: nil
             }) ==
               nil
    end
  end

  describe "declared/1, merge/2 and conflicts/2" do
    defp endpoint(model, declaration) do
      %Endpoint{
        provider: "mistral",
        model: model,
        provider_settings: %{"capabilities" => declaration}
      }
    end

    test "a declaration counts for the model it names only" do
      declaration = %{"model" => "pixtral-large", "vision" => "yes", "tools" => "unknown"}

      assert Capabilities.declared(endpoint("pixtral-large", declaration)) == %{vision: :yes}
      assert Capabilities.declared(endpoint("mistral-large", declaration)) == %{}
      assert Capabilities.declared(%Endpoint{model: "x", provider_settings: %{}}) == %{}
      assert Capabilities.declared(%Endpoint{model: "x", provider_settings: nil}) == %{}
    end

    test "with no catalogue the declaration is the answer" do
      assert %Capabilities{vision: :yes, tools: :unknown, source: :declared} =
               Capabilities.merge(:unknown, %{vision: :yes})

      assert Capabilities.merge(:unknown, %{}) == :unknown
    end

    test "the catalogue wins where it knows; the declaration fills what it does not" do
      catalogue = %Capabilities{vision: :no, tools: :unknown, json_schema: :yes, json: :yes}

      merged = Capabilities.merge(catalogue, %{vision: :yes, tools: :yes})

      assert %Capabilities{vision: :no, tools: :yes, json_schema: :yes, source: :declared} =
               merged

      assert Capabilities.merge(catalogue, %{}) == catalogue
    end

    test "catalogue no and declared yes is a conflict" do
      catalogue = %Capabilities{vision: :no, tools: :yes, json_schema: :unknown}

      assert Capabilities.conflicts(catalogue, %{vision: :yes, tools: :yes, json_schema: :yes}) ==
               [:vision]

      assert Capabilities.conflicts(:unknown, %{vision: :yes}) == []
    end
  end

  describe "reads without the process" do
    test "lookup is unknown when the cache is not running" do
      assert Capabilities.lookup("https://nowhere.test/v1", "m") == :unknown
    end
  end
end
