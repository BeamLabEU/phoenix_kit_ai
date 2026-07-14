defmodule PhoenixKitAI.OpenRouterClient do
  import Ecto.Query, only: [from: 2]

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

  alias PhoenixKit.Utils.Values
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Endpoint

  require Logger

  @base_url "https://openrouter.ai/api/v1"
  # 15s is generous for `/models` and `/auth/key` — both are
  # lightweight metadata endpoints that respond in <5s on a healthy
  # connection. The previous 30s left operators staring at a spinner
  # for a full half-minute when something was wedged. Chat completions
  # have their own 120s budget in `Completion.chat_completion/3`;
  # this constant only governs validate + model-list traffic.
  @timeout 15_000

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
    url = "#{Keyword.get(opts, :base_url, @base_url)}/models"
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
  - `:model_type` - Filter by model type: `:text`, `:vision`, `:image_gen`, `:tts`, `:all` (default: `:text`)

  Returns a map where keys are provider names and values are lists of models.
  """
  def fetch_models_grouped(api_key, opts \\ []) do
    # Default to :text for backward compatibility
    opts = Keyword.put_new(opts, :model_type, :text)
    fallback_provider = Keyword.get(opts, :fallback_provider)

    with {:ok, models} <- fetch_models(api_key, opts) do
      grouped =
        models
        |> Enum.group_by(&provider_from_model(&1, fallback_provider))
        |> Enum.sort_by(fn {provider, _} -> provider end)

      {:ok, grouped}
    end
  end

  @doc """
  Fetches models by type and groups them by provider.

  ## Model Types
  - `:text` - Text/chat completion models (text->text), excluding TTS
  - `:vision` - Vision/multimodal models (text+image->text)
  - `:image_gen` - Image generation models (text+image->text+image)
  - `:tts` - Text-to-speech models (matched by `tts` in the id/name)
  - `:all` - All models without filtering

  ## Examples

      {:ok, grouped} = fetch_models_by_type(api_key, :vision)
  """
  def fetch_models_by_type(api_key, model_type, opts \\ [])
      when model_type in [:text, :vision, :image_gen, :tts, :all] do
    opts = Keyword.put(opts, :model_type, model_type)
    fetch_models_grouped(api_key, opts)
  end

  @doc """
  Fetches available TTS voices from a Mistral-compatible `/audio/voices`
  endpoint.

  This is **Mistral-specific** — other providers (OpenRouter, DeepSeek)
  don't expose `/audio/voices` and will return a non-200, in which case
  the caller should fall back to a free-text voice field. Mistral returns
  the full catalogue (~30 presets) well within a single `limit=100` page,
  so no pagination loop is needed.

  Returns `{:ok, [%{slug, name, language, gender, tags}]}` (the `slug` is
  what `/audio/speech` accepts as its `voice`) or `{:error, reason}`.

  ## Options
  - `:base_url` - Provider base URL (defaults to OpenRouter's, which has
    no voices endpoint — pass the endpoint's Mistral base_url).
  """
  def fetch_voices(api_key, opts \\ []) do
    base = Keyword.get(opts, :base_url, @base_url)
    url = "#{String.trim_trailing(base, "/")}/audio/voices?limit=100&offset=0"
    headers = build_headers(api_key, opts)

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"items" => items}} when is_list(items) ->
            {:ok, normalize_voices(items)}

          {:ok, _} ->
            {:error, :invalid_response_format}

          {:error, _} ->
            {:error, :invalid_json_response}
        end

      {:ok, %{status_code: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status_code: status}} ->
        Logger.warning("Voices fetch failed: #{status}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.warning("Voices fetch transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp normalize_voices(items) do
    items
    |> Enum.map(fn voice ->
      %{
        slug: voice["slug"],
        name: voice["name"] || voice["slug"],
        language: voice["languages"] |> List.wrap() |> List.first(),
        gender: voice["gender"],
        tags: voice["tags"] || []
      }
    end)
    |> Enum.filter(&is_binary(&1.slug))
  end

  @doc """
  Fetches available voices from xAI's `GET /v1/tts/voices` — used by the
  streaming voice panel (`PhoenixKitAI.Web.Playground`), not the
  request/response `/audio/speech` path `fetch_voices/2` serves.

  A different shape from `fetch_voices/2` entirely — a different path
  (`/tts/voices`, not `/audio/voices`), a `"voices"` envelope key (not
  `"items"`), and per-voice fields (`voice_id`/`name`/`language`) with no
  Mistral-style gender/tags/mood grouping — so it isn't a variant of that
  function, it's xAI's own endpoint with its own shape. Includes any
  custom/cloned voices on the account alongside the 5 built-ins
  (ara/eve/leo/rex/sal), which is exactly why this fetches live instead of
  hardcoding the built-in list.

  Returns `{:ok, [%{voice_id, name, language}]}` or `{:error, reason}`.

  ## Options
  - `:base_url` - Defaults to xAI's base_url (`https://api.x.ai/v1`).
  """
  def fetch_xai_voices(api_key, opts \\ []) do
    base = Keyword.get(opts, :base_url) || Endpoint.default_base_url("xai")
    url = "#{String.trim_trailing(base, "/")}/tts/voices"
    headers = build_headers(api_key, opts)

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"voices" => voices}} when is_list(voices) ->
            {:ok, normalize_xai_voices(voices)}

          {:ok, _} ->
            {:error, :invalid_response_format}

          {:error, _} ->
            {:error, :invalid_json_response}
        end

      {:ok, %{status_code: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status_code: status}} ->
        Logger.warning("xAI voices fetch failed: #{status}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.warning("xAI voices fetch transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp normalize_xai_voices(voices) do
    voices
    |> Enum.map(fn voice ->
      %{
        voice_id: voice["voice_id"],
        name: voice["name"] || voice["voice_id"],
        language: voice["language"]
      }
    end)
    |> Enum.filter(&is_binary(&1.voice_id))
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

  Resolves the API key by uuid lookup against `PhoenixKit.Integrations`,
  falling back to the legacy `endpoint.api_key` column when the
  integration row is missing or has no key.

  HTTP-Referer and X-Title fall back to PhoenixKit.Settings (`site_url`
  and `project_title`) when the endpoint's `provider_settings` don't
  carry a non-blank override — the endpoint form treats those settings
  as the source of defaults, and the per-endpoint fields as overrides.
  """
  def build_headers_from_endpoint(%{provider_settings: settings} = endpoint) do
    settings = settings || %{}

    api_key = resolve_api_key(endpoint)

    http_referer =
      Values.blank_to_nil(settings["http_referer"]) ||
        Values.blank_to_nil(PhoenixKit.Settings.get_setting_cached("site_url"))

    x_title =
      Values.blank_to_nil(settings["x_title"]) ||
        Values.blank_to_nil(PhoenixKit.Settings.get_setting_cached("project_title"))

    opts =
      []
      |> maybe_add_opt(:http_referer, http_referer)
      |> maybe_add_opt(:x_title, x_title)

    build_headers(api_key, opts)
  end

  @doc false
  # Public so non-REST callers (e.g. PhoenixKitAI.Realtime.Session, which
  # talks to xAI over WebSocket instead of through this module's REST
  # helpers) can resolve the same API key without duplicating the
  # integration_uuid / legacy-provider / endpoint.api_key fallback chain.
  def resolve_api_key(endpoint) do
    # Prefer the explicit `integration_uuid` reference. Fall back to the
    # legacy `provider` field (which carried a uuid before the dedicated
    # column existed) for any endpoint that wasn't reached by V107's
    # backfill. Final fallback is the deprecated `endpoint.api_key`
    # column with a per-endpoint warning log.
    case maybe_get_credentials(endpoint.integration_uuid) do
      {:ok, %{"api_key" => key}} when is_binary(key) and key != "" ->
        key

      _ ->
        resolve_via_legacy_provider(endpoint)
    end
  end

  defp resolve_via_legacy_provider(endpoint) do
    case maybe_get_credentials(endpoint.provider) do
      {:ok, %{"api_key" => key}} = result when is_binary(key) and key != "" ->
        # Legacy path resolved — promote the resolved uuid to
        # `endpoint.integration_uuid` so future requests take the
        # clean uuid path. Best-effort; failure here doesn't block
        # the request.
        maybe_promote_legacy_provider(endpoint, result)
        key

      _ ->
        warn_legacy_api_key(endpoint)
        endpoint.api_key
    end
  end

  defp maybe_get_credentials(nil), do: {:error, :not_configured}
  defp maybe_get_credentials(""), do: {:error, :not_configured}

  defp maybe_get_credentials(key) when is_binary(key) do
    PhoenixKit.Integrations.get_credentials(key)
  end

  # Lazy on-read promotion: when integration_uuid is nil but the
  # legacy `provider` resolves to credentials, write the resolved
  # uuid back to the endpoint so the next call takes the direct path.
  # Safe to fail silently — the request that triggered this still
  # got its api_key from the legacy path.
  defp maybe_promote_legacy_provider(%{integration_uuid: nil} = endpoint, _resolved) do
    integration_uuid = lookup_uuid_for_provider(endpoint.provider)

    if is_binary(integration_uuid) do
      try do
        repo = PhoenixKit.RepoHelper.repo()

        {count, _} =
          from(e in PhoenixKitAI.Endpoint,
            where: e.uuid == ^endpoint.uuid and is_nil(e.integration_uuid)
          )
          |> repo.update_all(
            set: [
              integration_uuid: integration_uuid,
              updated_at: DateTime.utc_now()
            ]
          )

        if count > 0 do
          log_lazy_promotion(endpoint, integration_uuid)
        end
      rescue
        e ->
          # Lazy promotion is best-effort — the request that triggered
          # this already got its api_key from the legacy fallback path,
          # so we don't want a write failure here to cascade into a
          # request-path crash. Log with grep-able context (endpoint
          # uuid + exception type) so operators can correlate stuck
          # promotions with infra issues. Don't include
          # `Exception.message/1` raw — some exception structs embed
          # query bindings that could leak provider/api_key context.
          #
          # Rate-limited via `:persistent_term` so a stuck endpoint
          # (e.g. read-only replica routing failures) doesn't flood
          # the logs with one warning per chat completion. One warning
          # per endpoint per VM lifetime is enough to surface the
          # underlying infra issue.
          warn_promotion_failed_once(endpoint.uuid, e.__struct__)
          :ok
      catch
        :exit, reason ->
          # Sandbox-owner exit at test boundaries falls here. Same
          # justification as the rescue above — don't crash the
          # request, but leave a breadcrumb.
          Logger.debug(fn ->
            "[OpenRouterClient] lazy promotion exited: " <>
              "endpoint_uuid=#{endpoint.uuid}, reason=#{inspect(reason)}"
          end)

          :ok
      end
    end

    :ok
  end

  defp maybe_promote_legacy_provider(_endpoint, _resolved), do: :ok

  defp lookup_uuid_for_provider(provider) when is_binary(provider) do
    # Delegates to core's dual-input primitive. Previously this helper
    # carried its own regex + dispatch + provider:name split; the same
    # pair existed verbatim on `PhoenixKitAI.resolve_provider_to_uuid/1`.
    # Centralising into `Integrations.resolve_to_uuid/1` removes the
    # duplication and eliminates the "fourth provider tempts a third
    # copy-paste" risk.
    case PhoenixKit.Integrations.resolve_to_uuid(provider) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp lookup_uuid_for_provider(_), do: nil

  defp log_lazy_promotion(endpoint, integration_uuid) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "integration.legacy_migrated",
        module: "ai",
        mode: "auto",
        resource_type: "endpoint",
        resource_uuid: endpoint.uuid,
        metadata: %{
          "migration_kind" => "reference_migrated",
          "source" => "lazy_on_read",
          "integration_uuid" => integration_uuid,
          "actor_role" => "system"
        }
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  # Warn at most once per endpoint per VM. The legacy fallback path runs
  # on every chat completion, and a per-request warning floods logs for
  # endpoints that haven't migrated to Integrations yet. `:persistent_term`
  # gives us O(1) check + write and survives across processes.
  @doc false
  def warn_legacy_api_key(%{uuid: uuid, name: name, api_key: key})
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

  def warn_legacy_api_key(_), do: :ok

  # One warning per endpoint per VM for lazy-promotion write failures.
  # Same mechanism as `warn_legacy_api_key/1` — `:persistent_term`
  # gives O(1) check + write, survives across processes. Operators
  # see one warning when promotion first fails for an endpoint and
  # can investigate; the request hot path stays quiet on subsequent
  # calls even if the underlying infra issue persists.
  defp warn_promotion_failed_once(uuid, exception_struct) do
    key_term = {__MODULE__, :promotion_failed, uuid}

    case :persistent_term.get(key_term, :unwarned) do
      :warned ->
        :ok

      :unwarned ->
        :persistent_term.put(key_term, :warned)

        Logger.warning(fn ->
          "[OpenRouterClient] lazy promotion of integration_uuid failed: " <>
            "endpoint_uuid=#{uuid}, " <>
            "exception=#{inspect(exception_struct)}"
        end)
    end
  end

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
        pricing: normalize_pricing(model),
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
    # A TTS model would otherwise slip into the chat list — Mistral's
    # Voxtral TTS models carry no modality and would match the "" branch
    # below — so exclude them explicitly to keep the chat picker clean.
    not tts_model?(model) and
      case get_modality(model) do
        # OpenRouter: explicit "text->text" modality
        "text->text" -> true
        # No modality field at all (Mistral, DeepSeek — OpenAI-compatible
        # /models endpoints don't return architecture metadata). Treat as
        # text by default since callers asking for `:text` against an
        # endpoint that doesn't expose modality just want "show all the
        # chat models the API listed" — except xAI's `/models` mixes
        # chat models into the same no-modality response as its
        # `grok-imagine-*` image/video generation models, so those need
        # explicit exclusion here.
        "" -> not generative_media_model?(model)
        _ -> false
      end
  end

  defp model_matches_type?(model, :vision) do
    get_modality(model) == "text+image->text"
  end

  defp model_matches_type?(model, :image_gen) do
    modality = get_modality(model)
    # Include both pure text-to-image and multimodal image generation
    modality == "text->text+image" or modality == "text+image->text+image"
  end

  # Neither Mistral's nor OpenRouter's `/models` exposes a reliable
  # audio/TTS modality flag, so classify by the model id/name instead:
  # Mistral's TTS models are `voxtral-*-tts-*`, and the convention of
  # putting "tts" in the identifier is consistent across providers.
  # (Speech-to-text / transcription models — `*-transcribe-*` — are NOT
  # matched here; they have no dedicated type yet and stay out of the
  # TTS picker.)
  defp model_matches_type?(model, :tts), do: tts_model?(model)

  defp tts_model?(model) do
    "#{model["id"]} #{model["name"]}"
    |> String.downcase()
    |> String.contains?("tts")
  end

  # xAI's `/models` response has no `architecture.modality` field on any
  # model, so `grok-imagine-image`/`grok-imagine-video` (and their
  # `-quality`/`-1.5` variants) would otherwise fall through to the
  # no-modality "assume text" branch above. `image_price` only appears on
  # image-gen entries; the id substring check catches the video-gen
  # entries, which carry no pricing fields at all.
  defp generative_media_model?(model) do
    Map.has_key?(model, "image_price") or media_gen_id?(model["id"])
  end

  defp media_gen_id?(id) when is_binary(id) do
    downcased = String.downcase(id)
    String.contains?(downcased, "-image") or String.contains?(downcased, "-video")
  end

  defp media_gen_id?(_), do: false

  defp get_modality(model) do
    architecture = model["architecture"] || %{}
    architecture["modality"] || ""
  end

  defp provider_from_model(model, fallback_provider) do
    case String.split(model.id, "/", parts: 2) do
      # OpenRouter shape: "anthropic/claude-3-opus" → "anthropic"
      [provider, _name] -> provider
      # Mistral / DeepSeek shape: "mistral-large-latest" with no slash.
      # Group everything under the endpoint's provider key so the form's
      # provider picker has one entry containing all the models. Falls
      # back to "other" only when no fallback was passed.
      [_no_slash] -> fallback_provider || "other"
      _ -> fallback_provider || "other"
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

  # OpenRouter (and Mistral/DeepSeek, which mirror its shape) nest pricing
  # under a `pricing` map of dollars-per-token.
  defp normalize_pricing(%{"pricing" => pricing}) when is_map(pricing) do
    %{
      "prompt" => parse_price(pricing["prompt"]),
      "completion" => parse_price(pricing["completion"])
    }
  end

  # xAI's `/models` has no `pricing` map — it reports flat
  # `prompt_text_token_price` / `completion_text_token_price` fields in
  # USD cents per 100,000,000 tokens (confirmed against `image_price`,
  # which resolves to clean per-image cent amounts under the same
  # divisor). Convert to the same dollars-per-token shape as the
  # OpenRouter branch above so downstream formatting doesn't need to
  # know which provider a model came from.
  defp normalize_pricing(%{"prompt_text_token_price" => _} = model) do
    %{
      "prompt" => flat_token_price_to_dollars(model["prompt_text_token_price"]),
      "completion" => flat_token_price_to_dollars(model["completion_text_token_price"])
    }
  end

  defp normalize_pricing(_model), do: %{"prompt" => 0, "completion" => 0}

  defp flat_token_price_to_dollars(value) when is_number(value), do: value / 10_000_000_000
  defp flat_token_price_to_dollars(_), do: 0

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
