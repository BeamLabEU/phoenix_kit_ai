defmodule PhoenixKitAI.OpenRouterClient do
  @moduledoc """
  OpenRouter API client for PhoenixKit AI system.

  Provides functions for interacting with the OpenRouter API, including:
  - API key validation
  - Model discovery (fetching available models)
  - Building request headers

  ## OpenRouter API Reference

  - Base URL: https://openrouter.ai/api/v1
  - Authentication: Bearer token in Authorization header
  - Optional headers: HTTP-Referer, X-Title (for rankings)

  ## Usage Examples

      # Validate an API key
      {:ok, %{credits: _}} = PhoenixKitAI.OpenRouterClient.validate_api_key("sk-or-v1-...")

      # Fetch available models
      {:ok, models} = PhoenixKitAI.OpenRouterClient.fetch_models("sk-or-v1-...")
  """

  alias PhoenixKitAI.AIModel

  require Logger

  @base_url "https://openrouter.ai/api/v1"
  @timeout 30_000

  # OpenRouter's /models endpoint does not return embedding models, so we ship
  # a curated list. This table is manually maintained — bump the date when
  # refreshing, and users can append more via config:
  #
  #     config :phoenix_kit_ai, embedding_models: [
  #       %{"id" => "custom/model", "name" => "Custom", ...}
  #     ]
  @embedding_models_last_updated "2026-03-24"

  @doc """
  Validates an OpenRouter API key by making a request to the /models endpoint.

  Returns `{:ok, %{valid: true}}` on success, `{:error, reason}` on failure.
  """
  def validate_api_key(api_key) when is_binary(api_key) do
    # Use /models endpoint for validation as it's more reliable
    url = "#{@base_url}/models"
    headers = build_headers(api_key)

    Logger.debug("Validating API key via #{url}")

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} when is_list(data) ->
            Logger.debug("API key valid - found #{length(data)} models")
            {:ok, %{valid: true, models_count: length(data)}}

          {:ok, _data} ->
            {:ok, %{valid: true}}

          {:error, _} ->
            {:error, :invalid_json_response}
        end

      {:ok, %{status_code: 401}} ->
        Logger.warning("OpenRouter 401 response during API key validation")
        {:error, :invalid_api_key}

      {:ok, %{status_code: 403}} ->
        Logger.warning("OpenRouter 403 response during API key validation")
        {:error, :api_key_forbidden}

      {:ok, %{status_code: status}} ->
        Logger.warning("OpenRouter API key validation failed: #{status}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.warning("OpenRouter API key validation transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Fetches available models from OpenRouter.

  Returns `{:ok, models}` where models is a list of model objects,
  or `{:error, reason}` on failure.

  ## Options
  - `:model_type` - Filter by model type: `:text`, `:vision`, `:image_gen`, `:all` (default: `:all`)
  - `:http_referer` - Site URL for rankings
  - `:x_title` - Site title for rankings

  ## Model Object Structure

  Each model has:
  - `id` - Model identifier (e.g., "anthropic/claude-3-opus")
  - `name` - Display name
  - `description` - Model description
  - `pricing` - Pricing information (prompt/completion costs)
  - `context_length` - Maximum context window
  - `architecture` - Model architecture details
  """
  def fetch_models(api_key, opts \\ []) do
    url = "#{@base_url}/models"
    headers = build_headers(api_key, opts)
    model_type = Keyword.get(opts, :model_type, :all)

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => models}} when is_list(models) ->
            {:ok, normalize_models(models, model_type)}

          {:ok, _} ->
            {:error, :invalid_response_format}

          {:error, _} ->
            {:error, :invalid_json_response}
        end

      {:ok, %{status_code: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status_code: status}} ->
        Logger.warning("OpenRouter models fetch failed: #{status}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.warning("OpenRouter models fetch transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Fetches models and groups them by provider.

  ## Options
  - `:model_type` - Filter by model type: `:text`, `:vision`, `:image_gen`, `:all` (default: `:text`)

  Returns a map where keys are provider names and values are lists of models.
  """
  def fetch_models_grouped(api_key, opts \\ []) do
    # Default to :text for backward compatibility
    opts = Keyword.put_new(opts, :model_type, :text)

    with {:ok, models} <- fetch_models(api_key, opts) do
      grouped =
        models
        |> Enum.group_by(&provider_from_model/1)
        |> Enum.sort_by(fn {provider, _} -> provider end)

      {:ok, grouped}
    end
  end

  @doc """
  Fetches models by type and groups them by provider.

  ## Model Types
  - `:text` - Text/chat completion models (text->text)
  - `:vision` - Vision/multimodal models (text+image->text)
  - `:image_gen` - Image generation models (text+image->text+image)
  - `:all` - All models without filtering

  ## Examples

      {:ok, grouped} = fetch_models_by_type(api_key, :vision)
  """
  def fetch_models_by_type(api_key, model_type, opts \\ [])
      when model_type in [:text, :vision, :image_gen, :all] do
    opts = Keyword.put(opts, :model_type, model_type)
    fetch_models_grouped(api_key, opts)
  end

  @doc """
  Fetches embedding models from OpenRouter.

  Note: Embedding models are not returned by `/models`, so this function
  returns a curated list maintained in source (last refreshed
  `#{@embedding_models_last_updated}`) merged with any user-contributed
  entries from `config :phoenix_kit_ai, :embedding_models`.

  Returns `{:ok, models}` with a list of known embedding models.
  """
  def fetch_embedding_models(_api_key, _opts \\ []) do
    {:ok, builtin_embedding_models() ++ user_embedding_models()}
  end

  @doc """
  Returns the date the built-in embedding model list was last refreshed.
  """
  def embedding_models_last_updated, do: @embedding_models_last_updated

  defp user_embedding_models do
    case Application.get_env(:phoenix_kit_ai, :embedding_models, []) do
      list when is_list(list) ->
        list

      other ->
        Logger.warning(
          "[PhoenixKitAI] :embedding_models config must be a list, got #{inspect(other)} — ignoring"
        )

        []
    end
  end

  defp builtin_embedding_models do
    # OpenRouter embedding models - these are not returned by /models endpoint
    # They must be used via POST /api/v1/embeddings
    [
      %{
        "id" => "openai/text-embedding-3-large",
        "name" => "Text Embedding 3 Large",
        "description" => "OpenAI's most capable embedding model",
        "context_length" => 8191,
        "dimensions" => 3072,
        "pricing" => %{"prompt" => 0.00000013, "completion" => 0}
      },
      %{
        "id" => "openai/text-embedding-3-small",
        "name" => "Text Embedding 3 Small",
        "description" => "OpenAI's efficient embedding model",
        "context_length" => 8191,
        "dimensions" => 1536,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      },
      %{
        "id" => "openai/text-embedding-ada-002",
        "name" => "Text Embedding Ada 002",
        "description" => "OpenAI's legacy embedding model",
        "context_length" => 8191,
        "dimensions" => 1536,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "cohere/embed-english-v3.0",
        "name" => "Embed English v3.0",
        "description" => "Cohere's English embedding model",
        "context_length" => 512,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "cohere/embed-multilingual-v3.0",
        "name" => "Embed Multilingual v3.0",
        "description" => "Cohere's multilingual embedding model",
        "context_length" => 512,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-3",
        "name" => "Voyage 3",
        "description" => "Voyage AI's general-purpose embedding model",
        "context_length" => 32_000,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.00000006, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-3-lite",
        "name" => "Voyage 3 Lite",
        "description" => "Voyage AI's lightweight embedding model",
        "context_length" => 32_000,
        "dimensions" => 512,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-code-3",
        "name" => "Voyage Code 3",
        "description" => "Voyage AI's code-optimized embedding model",
        "context_length" => 32_000,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.00000006, "completion" => 0}
      },
      %{
        "id" => "qwen/qwen3-embedding-8b",
        "name" => "Qwen3 Embedding 8B",
        "description" => "Qwen's 8B parameter embedding model",
        "context_length" => 8192,
        "dimensions" => 4096,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      }
    ]
  end

  @doc """
  Fetches embedding models grouped by provider.
  """
  def fetch_embedding_models_grouped(api_key, opts \\ []) do
    {:ok, models} = fetch_embedding_models(api_key, opts)

    grouped =
      models
      |> Enum.group_by(fn model ->
        case String.split(model["id"], "/") do
          [provider | _] -> provider
          _ -> "other"
        end
      end)
      |> Enum.sort_by(fn {provider, _} -> provider end)

    {:ok, grouped}
  end

  @doc """
  Builds HTTP headers for OpenRouter API requests.

  ## Options
  - `:http_referer` - Site URL for rankings
  - `:x_title` - Site title for rankings
  - `:include_usage` - Include detailed usage/cost info (default: true for completions)
  """
  def build_headers(api_key, opts \\ [])

  def build_headers(nil, _opts) do
    require Logger

    Logger.error(
      "[OpenRouterClient] build_headers called with nil API key — no integration configured?"
    )

    [{"Content-Type", "application/json"}]
  end

  def build_headers(api_key, opts) do
    base_headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    # Request extra data from OpenRouter including cost information
    # X-Include-Usage: true returns detailed usage including cost
    include_usage = Keyword.get(opts, :include_usage, true)

    optional_headers =
      []
      |> maybe_add_header("HTTP-Referer", Keyword.get(opts, :http_referer))
      |> maybe_add_header("X-Title", Keyword.get(opts, :x_title))
      |> maybe_add_header("X-Include-Usage", if(include_usage, do: "true", else: nil))

    base_headers ++ optional_headers
  end

  @doc """
  Builds headers from an Account struct's settings.
  """
  def build_headers_from_account(%{api_key: api_key, settings: settings}) do
    opts =
      []
      |> maybe_add_opt(:http_referer, settings["http_referer"])
      |> maybe_add_opt(:x_title, settings["x_title"])

    build_headers(api_key, opts)
  end

  @doc """
  Builds headers from an Endpoint struct's provider_settings.

  Resolves the API key from `PhoenixKit.Integrations` using the endpoint's
  provider field, falling back to the endpoint's own api_key if present (legacy).
  """
  def build_headers_from_endpoint(%{provider: provider, provider_settings: settings} = endpoint) do
    settings = settings || %{}

    api_key = resolve_api_key(provider, endpoint)

    opts =
      []
      |> maybe_add_opt(:http_referer, settings["http_referer"])
      |> maybe_add_opt(:x_title, settings["x_title"])

    build_headers(api_key, opts)
  end

  defp resolve_api_key(provider, endpoint) do
    # provider is the endpoint's provider field, e.g. "openrouter" or "openrouter:my-key"
    case PhoenixKit.Integrations.get_credentials(provider) do
      {:ok, %{"api_key" => key}} when is_binary(key) and key != "" ->
        key

      _ ->
        warn_legacy_api_key(endpoint)
        endpoint.api_key
    end
  end

  # Warn at most once per endpoint per VM. The legacy fallback path runs
  # on every chat completion, and a per-request warning floods logs for
  # endpoints that haven't migrated to Integrations yet. `:persistent_term`
  # gives us O(1) check + write and survives across processes.
  defp warn_legacy_api_key(%{uuid: uuid, name: name, api_key: key})
       when is_binary(key) and key != "" do
    key_term = {__MODULE__, :legacy_warned, uuid}

    case :persistent_term.get(key_term, :unwarned) do
      :warned ->
        :ok

      :unwarned ->
        :persistent_term.put(key_term, :warned)

        Logger.warning(
          "[PhoenixKitAI] endpoint #{inspect(name)} (#{uuid}) is using the " <>
            "deprecated endpoint.api_key field. Migrate it to a " <>
            "PhoenixKit.Integrations connection; the api_key column will be " <>
            "removed in a future major version."
        )
    end
  end

  defp warn_legacy_api_key(_), do: :ok

  @doc """
  Returns the base URL for OpenRouter API.
  """
  def base_url, do: @base_url

  @doc """
  Formats a model for display in a select dropdown.

  Returns `{label, value}` tuple.
  """
  def model_option(%AIModel{} = model) do
    label =
      if model.name && model.name != "" do
        provider = extract_provider(model.id)
        "#{model.name} (#{provider})"
      else
        model.id || "Unknown"
      end

    {label, model.id || ""}
  end

  def model_option(model) when is_map(model) do
    label =
      case model do
        %{"name" => name, "id" => id} when name != "" ->
          provider = extract_provider(id)
          "#{name} (#{provider})"

        %{"id" => id} ->
          id

        _ ->
          "Unknown"
      end

    value = model["id"] || ""

    {label, value}
  end

  @doc """
  Extracts the provider name from a model ID.

  ## Examples

      iex> extract_provider("anthropic/claude-3-opus")
      "Anthropic"

      iex> extract_provider("openai/gpt-4")
      "OpenAI"
  """
  def extract_provider(model_id) when is_binary(model_id) do
    case String.split(model_id, "/") do
      [provider | _] -> humanize_provider(provider)
      _ -> "Unknown"
    end
  end

  def extract_provider(_), do: "Unknown"

  @doc """
  Extracts the model name without provider prefix.
  """
  def extract_model_name(model_id) when is_binary(model_id) do
    case String.split(model_id, "/") do
      [_provider, name | _] -> name
      [name] -> name
      _ -> model_id
    end
  end

  def extract_model_name(_), do: "Unknown"

  # Private functions

  defp http_get(url, headers) do
    # Convert headers list to map format for Req
    headers_map = Map.new(headers)

    base_opts = [
      headers: headers_map,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout]
    ]

    # `:req_options` is empty in production. Tests opt in via
    # `Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, Stub})`
    # to route through `Req.Test` stubs without external HTTP traffic.
    opts = base_opts ++ Application.get_env(:phoenix_kit_ai, :req_options, [])

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        # Req automatically decodes JSON, so encode it back to string for consistency
        body_string =
          if is_map(body) or is_list(body) do
            Jason.encode!(body)
          else
            to_string(body)
          end

        {:ok, %{status_code: status, body: body_string}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_models(models, model_type) do
    models
    |> Enum.filter(&model_matches_type?(&1, model_type))
    |> Enum.map(fn model ->
      top_provider = model["top_provider"] || %{}

      %AIModel{
        id: model["id"],
        name: model["name"] || extract_model_name(model["id"]),
        description: model["description"],
        context_length: model["context_length"],
        max_completion_tokens: top_provider["max_completion_tokens"],
        supported_parameters: model["supported_parameters"] || [],
        pricing: normalize_pricing(model["pricing"]),
        architecture: model["architecture"] || %{},
        top_provider: top_provider
      }
    end)
  end

  # Filter models by type based on architecture.modality
  # OpenRouter models have architecture.modality indicating input->output types:
  # - "text->text" = pure text chat/completion
  # - "text+image->text" = multimodal input, text output (vision models)
  # - "text->text+image" = pure text-to-image generation
  # - "text+image->text+image" = multimodal with image generation (can edit images)

  defp model_matches_type?(_model, :all), do: true

  defp model_matches_type?(model, :text) do
    get_modality(model) == "text->text"
  end

  defp model_matches_type?(model, :vision) do
    get_modality(model) == "text+image->text"
  end

  defp model_matches_type?(model, :image_gen) do
    modality = get_modality(model)
    # Include both pure text-to-image and multimodal image generation
    modality == "text->text+image" or modality == "text+image->text+image"
  end

  defp get_modality(model) do
    architecture = model["architecture"] || %{}
    architecture["modality"] || ""
  end

  defp provider_from_model(model) do
    case String.split(model.id, "/") do
      [provider | _] -> provider
      _ -> "other"
    end
  end

  @doc """
  Fetches details for a specific model by ID.

  Returns `{:ok, model}` or `{:error, reason}`.
  """
  def fetch_model(api_key, model_id, opts \\ []) do
    with {:ok, models} <- fetch_models(api_key, opts),
         model when not is_nil(model) <- Enum.find(models, fn m -> m.id == model_id end) do
      {:ok, model}
    else
      nil -> {:error, :model_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a model supports a specific parameter.

  ## Examples

      iex> model_supports_parameter?(model, "temperature")
      true

      iex> model_supports_parameter?(model, "tools")
      false
  """
  def model_supports_parameter?(%AIModel{} = model, param) do
    param in model.supported_parameters
  end

  def model_supports_parameter?(model, param) when is_map(model) do
    supported = model["supported_parameters"] || []
    param in supported
  end

  @doc """
  Gets the effective max tokens for a model.

  Returns the model's max_completion_tokens if available,
  otherwise falls back to a percentage of context_length.
  """
  def get_model_max_tokens(%AIModel{} = model) do
    cond do
      model.max_completion_tokens ->
        model.max_completion_tokens

      model.context_length ->
        div(model.context_length, 4)

      true ->
        4096
    end
  end

  def get_model_max_tokens(model) when is_map(model) do
    cond do
      model["max_completion_tokens"] ->
        model["max_completion_tokens"]

      model["context_length"] ->
        div(model["context_length"], 4)

      true ->
        4096
    end
  end

  defp normalize_pricing(nil), do: %{"prompt" => 0, "completion" => 0}

  defp normalize_pricing(pricing) when is_map(pricing) do
    %{
      "prompt" => parse_price(pricing["prompt"]),
      "completion" => parse_price(pricing["completion"])
    }
  end

  defp parse_price(nil), do: 0
  defp parse_price(price) when is_number(price), do: price

  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {float, _} -> float
      :error -> 0
    end
  end

  defp parse_price(_), do: 0

  @doc """
  Converts a provider slug to a human-friendly name.

  OpenRouter model IDs use slugs like "arcee-ai/model-name". This function
  converts the slug portion to a human-readable provider name.

  ## Examples

      iex> humanize_provider("openai")
      "OpenAI"

      iex> humanize_provider("meta-llama")
      "Meta Llama"

      iex> humanize_provider("arcee-ai")
      "Arcee AI"
  """
  def humanize_provider("openai"), do: "OpenAI"
  def humanize_provider("anthropic"), do: "Anthropic"
  def humanize_provider("google"), do: "Google"
  def humanize_provider("meta-llama"), do: "Meta Llama"
  def humanize_provider("mistralai"), do: "Mistral AI"
  def humanize_provider("cohere"), do: "Cohere"
  def humanize_provider("deepseek"), do: "DeepSeek"
  def humanize_provider("x-ai"), do: "xAI"
  def humanize_provider("nvidia"), do: "NVIDIA"
  def humanize_provider("microsoft"), do: "Microsoft"
  def humanize_provider("amazon"), do: "Amazon"
  def humanize_provider("alibaba"), do: "Alibaba"
  def humanize_provider("baidu"), do: "Baidu"
  def humanize_provider("tencent"), do: "Tencent"
  def humanize_provider("ibm-granite"), do: "IBM Granite"
  def humanize_provider("ai21"), do: "AI21 Labs"
  def humanize_provider("perplexity"), do: "Perplexity"
  def humanize_provider("inflection"), do: "Inflection"
  def humanize_provider("qwen"), do: "Qwen"
  def humanize_provider("nousresearch"), do: "Nous Research"
  def humanize_provider("arcee-ai"), do: "Arcee AI"
  def humanize_provider("aion-labs"), do: "Aion Labs"
  def humanize_provider("allenai"), do: "Allen AI"
  def humanize_provider("eleutherai"), do: "EleutherAI"
  def humanize_provider("cognitivecomputations"), do: "Cognitive Computations"
  def humanize_provider("thedrummer"), do: "TheDrummer"
  def humanize_provider("neversleep"), do: "NeverSleep"
  def humanize_provider("anthracite-org"), do: "Anthracite"
  def humanize_provider("arliai"), do: "ArliAI"
  def humanize_provider("mancer"), do: "Mancer"
  def humanize_provider("openrouter"), do: "OpenRouter"
  def humanize_provider("minimax"), do: "MiniMax"
  def humanize_provider("moonshotai"), do: "Moonshot AI"
  def humanize_provider("deepcogito"), do: "DeepCogito"
  def humanize_provider("liquid"), do: "Liquid"
  def humanize_provider("essentialai"), do: "Essential AI"
  def humanize_provider("tngtech"), do: "TNG Tech"
  def humanize_provider("kwaipilot"), do: "KwaiPilot"
  def humanize_provider("z-ai"), do: "Z-AI"
  def humanize_provider("nex-agi"), do: "Nex AGI"
  def humanize_provider("prime-intellect"), do: "Prime Intellect"

  def humanize_provider(provider) when is_binary(provider) do
    provider
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize_provider(_), do: "Unknown"

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, _name, ""), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
