defmodule PhoenixKitAI.Completion do
  @moduledoc """
  OpenRouter completion client for making AI API calls.

  This module handles the actual HTTP requests to OpenRouter's chat completions
  and other endpoints. It's used internally by `PhoenixKitAI` public functions.

  ## Supported Endpoints

  - `/chat/completions` - Text and vision completions
  - `/embeddings` - Text embeddings
  - `/audio/speech` / xAI's `/tts` - Text-to-speech synthesis
  - `/images/generations` - Image generation

  ## Logging conventions

  - `Logger.warning` — expected/recoverable external failures (non-2xx HTTP
    responses, transport errors, rate limits). Callers see a user-facing error.
  - `Logger.error` — unexpected internal failures (unknown error shapes,
    parse failures).
  """

  require Logger

  alias PhoenixKitAI.{
    Capabilities,
    Endpoint,
    Images,
    Limiter,
    OpenRouterClient,
    Provider,
    ProviderError
  }

  @timeout 120_000
  @retry_statuses [408, 429, 500, 502, 503, 504]
  @retry_defaults [max_attempts: 3, base_delay: 1_000, max_delay: 30_000, retry_timeouts: false]

  @doc """
  Makes a chat completion request to OpenRouter.

  ## Parameters

  - `endpoint` - The AI endpoint struct with API key and model
  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Additional options (temperature, max_tokens, etc.)

  ## Options

  - `:temperature` - Sampling temperature (0-2)
  - `:max_tokens` - Maximum tokens in response
  - `:top_p` - Nucleus sampling parameter
  - `:top_k` - Top-k sampling parameter
  - `:frequency_penalty` - Frequency penalty (-2 to 2)
  - `:presence_penalty` - Presence penalty (-2 to 2)
  - `:repetition_penalty` - Repetition penalty (0 to 2)
  - `:stop` - Stop sequences (list of strings)
  - `:seed` - Random seed for reproducibility
  - `:stream` - Enable streaming (default: false)
  - `:tools` - OpenAI function-tools (a list of `%{"type" => "function",
    "function" => %{"name" => …, "parameters" => …}}`); sent only when given
  - `:tool_choice` - `"auto"`, `"none"`, `"required"` or a function selector;
    sent only when given
  - `:parallel_tool_calls` - boolean (`false` is sent); sent only when given

  ## Tool calling

  Messages keep the tool fields the provider needs for the next round:
  `tool_calls` on `assistant` messages (whose `content` may be `nil`),
  `tool_call_id` and `name` on `tool` messages. Read the model's calls from
  the response with `extract_tool_calls/1`.

  ## Returns

  - `{:ok, response}` - Successful response with completion
  - `{:error, reason}` - Error atom or tagged tuple. See
    `PhoenixKitAI.Errors` for the full reason vocabulary and translation.

  ## Response Structure

  ```elixir
  %{
    "id" => "gen-...",
    "model" => "anthropic/claude-3-haiku",
    "choices" => [
      %{
        "message" => %{
          "role" => "assistant",
          "content" => "Hello! How can I help you today?"
        },
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{
      "prompt_tokens" => 10,
      "completion_tokens" => 15,
      "total_tokens" => 25
    }
  }
  ```
  """
  def chat_completion(endpoint, messages, opts \\ []) do
    url = build_url(endpoint, "/chat/completions")
    headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
    # A per-call `model:` stands in for the endpoint's everywhere the body
    # depends on the model (the Anthropic sampling and thinking rules too).
    model = Keyword.get(opts, :model) || endpoint.model

    body =
      %{endpoint | model: model}
      |> build_chat_body(messages, opts)
      |> maybe_add_fallback_models(endpoint, model, Keyword.get(opts, :models))
      |> maybe_include_usage(endpoint)

    start_time = System.monotonic_time(:millisecond)

    case Limiter.run(endpoint, opts, fn -> http_post(url, headers, body, opts) end) do
      {:ok, %{status_code: 200, body: response_body}} ->
        response_body |> parse_success_response(start_time) |> with_sent_params(body)

      {:ok, %{status_code: status, body: response_body}} ->
        status |> handle_error_status(response_body) |> with_sent_params(body)

      {:error, reason} when reason in [:concurrency_limit_timeout, :concurrency_queue_full] ->
        {:error, reason}

      {:error, :timeout} ->
        {:error, :request_timeout}

      {:error, reason} ->
        Logger.warning("OpenRouter completion transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp parse_success_response(response_body, start_time) do
    latency_ms = System.monotonic_time(:millisecond) - start_time

    case Jason.decode(response_body) do
      # A provider error delivered with a 200 (OpenRouter does this for an
      # upstream timeout: `{"error": {"code": 504, ...}}`) is an error, not an
      # answer. Classified like the status it names, so it is logged as a
      # failed request and never stored by the request cache, where a retry
      # would replay it.
      {:ok, %{"error" => %{"code" => code}} = response}
      when not is_map_key(response, "choices") ->
        error_in_body(code, response_body)

      {:ok, response} ->
        {:ok, Map.put(response, "latency_ms", latency_ms)}

      {:error, _} ->
        {:error, :invalid_json_response}
    end
  end

  defp error_in_body(code, body) when is_integer(code), do: handle_error_status(code, body)
  defp error_in_body(_code, _body), do: {:error, :invalid_response_format}

  @doc false
  # Public for testability. Maps an HTTP status + response body to a
  # `{:error, reason}` tuple where `reason` is an atom or tagged tuple.
  # The body decides where the providers document that the status alone
  # misleads — money sent as a 429, say (`ProviderError`) — and what it
  # said is noted for the request row.
  def handle_error_status(status, response_body) do
    error = ProviderError.parse(response_body)

    result =
      case ProviderError.class(status, error) do
        nil -> status_error(status, response_body)
        class -> {:error, class}
      end

    :ok = ProviderError.note(status, error, result)
    result
  end

  defp status_error(401, _body), do: {:error, :invalid_api_key}
  defp status_error(402, _body), do: {:error, :insufficient_credits}
  defp status_error(429, _body), do: {:error, :rate_limited}

  # OpenRouter's answer to `provider.require_parameters` when no upstream
  # provider of the model takes every parameter sent. The model itself is
  # fine; the set of parameters is not. `chat_completion/3` fills in which
  # parameters were sent.
  defp status_error(404, response_body) do
    message = extract_error_message(response_body) || ""

    if message =~ ~r/requested parameters/i do
      Logger.warning(
        "OpenRouter completion failed: 404 - no provider for the requested parameters"
      )

      {:error, {:no_provider_for_params, []}}
    else
      generic_error_status(404, response_body)
    end
  end

  defp status_error(status, response_body), do: generic_error_status(status, response_body)

  defp generic_error_status(status, response_body) do
    # Log only the parsed error message (not the raw body) to avoid
    # persisting potentially sensitive provider data to application logs.
    case extract_error_message(response_body) do
      nil ->
        Logger.warning("OpenRouter completion failed: #{status} (no parsable error body)")

      msg ->
        Logger.warning("OpenRouter completion failed: #{status} - #{msg}")
    end

    {:error, {:api_error, status}}
  end

  # The parameters a refused request carried, by name — what the error
  # reports, never their values. Only the ones an endpoint's settings put
  # there: the call's own tools and answer format are not something to
  # remove from the endpoint.
  defp with_sent_params({:error, {:no_provider_for_params, _}}, body) do
    params =
      body
      |> Map.drop(
        ~w(model messages provider stream tools tool_choice parallel_tool_calls response_format)
      )
      |> Map.keys()
      |> Enum.sort()

    {:error, {:no_provider_for_params, params}}
  end

  defp with_sent_params(result, _body), do: result

  @doc false
  # Whether chat goes to Anthropic (its OpenAI-compatible layer), which
  # takes parameters by its own rules — see `build_chat_body/3`.
  @spec anthropic?(Endpoint.t() | map()) :: boolean()
  def anthropic?(%{provider: provider} = endpoint) do
    Capabilities.catalogue_kind(base_provider(provider), Capabilities.resolved_base_url(endpoint)) ==
      :anthropic
  end

  defp base_provider(provider) when is_binary(provider), do: Endpoint.base_provider(provider)
  defp base_provider(provider), do: provider

  @doc """
  Makes an embeddings request to OpenRouter.

  ## Parameters

  - `endpoint` - The AI endpoint struct with API key and model
  - `input` - Text or list of texts to embed
  - `opts` - Additional options

  ## Options

  - `:dimensions` - Output dimensions (model-specific)

  ## Returns

  - `{:ok, response}` - Response with embeddings
  - `{:error, reason}` - Error atom or tagged tuple. See
    `PhoenixKitAI.Errors` for the full reason vocabulary and translation.
  """
  def embeddings(endpoint, input, opts \\ []) do
    url = build_url(endpoint, "/embeddings")
    headers = OpenRouterClient.build_headers_from_endpoint(endpoint)

    body =
      %{
        "model" => Keyword.get(opts, :model) || endpoint.model,
        "input" => input
      }
      |> maybe_add("dimensions", Keyword.get(opts, :dimensions))

    start_time = System.monotonic_time(:millisecond)

    case Limiter.run(endpoint, opts, fn -> http_post(url, headers, body, opts) end) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_success_response(response_body, start_time)

      {:ok, %{status_code: status, body: response_body}} ->
        handle_error_status(status, response_body)

      {:error, reason} when reason in [:concurrency_limit_timeout, :concurrency_queue_full] ->
        {:error, reason}

      {:error, :timeout} ->
        {:error, :request_timeout}

      {:error, reason} ->
        Logger.warning("OpenRouter embeddings transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Synthesizes speech from text via the provider's `/audio/speech` endpoint
  (OpenAI-compatible providers), or xAI's own `POST /v1/tts` (a completely
  different request/response shape — see `xai_text_to_speech/3`).

  This is xAI's **batch** REST endpoint — a single request, a complete
  audio file back in the response, no persistent connection. Suited to
  "generate once, cache, serve from your own storage" use cases (e.g. a
  language-learning app pre-rendering vocabulary audio). For live,
  low-latency streaming playback, use `Xai.Realtime` directly (what the
  Playground's "Streaming Voice (xAI)" panel does) — that path returns no
  cacheable file, just a stream of chunks meant for one immediate playback.

  ## Parameters

  - `endpoint` - The AI endpoint struct with API key and model
  - `text` - The text to synthesize
  - `opts` - Additional options

  ## Options

  - `:response_format` - Audio container/codec (default `"mp3"`)
  - `:voice` - Preset voice identifier (OpenRouter / OSS vLLM shape)
  - `:voice_id` - Saved/cloned voice id (Mistral hosted shape; also xAI's
    voice field — see `fetch_xai_voices/2` in `OpenRouterClient` for the
    list, e.g. `"eve"`)
  - `:instructions` - Steering text for models that support it (e.g.
    `gpt-4o-mini-tts`'s accent/tone/pacing/language control). Only sent
    to models known to support it (the `gpt-4o*-tts` family); silently
    dropped otherwise. This is a real gate, not just documentation —
    some providers (Mistral's `voxtral-*-tts`) hard-fail the whole
    request with HTTP 422 on an unrecognized `instructions` field
    rather than ignoring it, so the module must not send it blindly.
  - `:language` - **xAI only**, ignored by other providers. BCP-47 code
    (`"en"`, `"pt-BR"`, ...) or `"auto"` for automatic detection.
    Defaults to `"auto"`.
  - `:sample_rate`, `:bit_rate`, `:speed` - **xAI only**, passed through
    to its `output_format` / `speed` fields when present.
  - `:with_timestamps` - **xAI only**, ignored by other providers (neither
    Mistral's Voxtral TTS nor OpenAI's `/audio/speech` offer anything
    equivalent). When `true`, xAI returns character-level timing data
    alongside the audio (see `Returns` below) — no cost difference, per
    xAI's pricing page; adds latency for the post-synthesis alignment
    pass on xAI's side.

  Only the voice option that is present is sent; the module stays
  provider-neutral and does not assume a field name.

  ## Returns

  - `{:ok, %{audio: binary(), format: String.t(), latency_ms: integer(),
    timestamps: [%{char:, start:, end:}] | nil}}` - `timestamps` is `nil`
    unless `:with_timestamps` was passed to an xAI endpoint and the
    response actually included them; `char` is a single input character,
    `start`/`end` its position in seconds as floats. Word boundaries
    aren't provided directly — derive them by splitting on whitespace.
  - `{:error, reason}` - Error atom or tagged tuple. See
    `PhoenixKitAI.Errors` for the full reason vocabulary and translation.
  """
  def text_to_speech(endpoint, text, opts \\ []) do
    if xai_provider?(endpoint.provider) do
      xai_text_to_speech(endpoint, text, opts)
    else
      generic_text_to_speech(endpoint, text, opts)
    end
  end

  defp xai_provider?(provider) when is_binary(provider) do
    Endpoint.base_provider(provider) == "xai"
  end

  defp xai_provider?(_provider), do: false

  defp generic_text_to_speech(endpoint, text, opts) do
    url = build_url(endpoint, "/audio/speech")
    headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
    format = Keyword.get(opts, :response_format, "mp3")

    body =
      %{"model" => endpoint.model, "input" => text, "response_format" => format}
      |> maybe_add("voice", Keyword.get(opts, :voice))
      |> maybe_add("voice_id", Keyword.get(opts, :voice_id))
      |> maybe_add(
        "instructions",
        instructions_for(endpoint.model, Keyword.get(opts, :instructions))
      )

    start_time = System.monotonic_time(:millisecond)

    case Limiter.run(endpoint, opts, fn -> http_post(url, headers, body, opts) end) do
      {:ok, %{status_code: 200, body: response_body}} ->
        decode_audio(response_body, format, start_time)

      {:ok, %{status_code: status, body: response_body}} ->
        handle_error_status(status, response_body)

      {:error, reason} when reason in [:concurrency_limit_timeout, :concurrency_queue_full] ->
        {:error, reason}

      {:error, :timeout} ->
        {:error, :request_timeout}

      {:error, reason} ->
        Logger.warning("TTS transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  # Synthesizes speech via xAI's synchronous POST /v1/tts — a single
  # request, a complete audio file back, no WebSocket. Not the same
  # endpoint Xai.Realtime.connect_tts/1 streams from, and not a variant
  # of generic_text_to_speech/2 — text/voice_id/language fields
  # (language required by xAI, defaulted to "auto" here) and a nested
  # output_format request body, matching neither the OpenAI-compatible
  # request shape. The response, despite xAI's own docs describing a
  # `{"audio": <base64>, "content_type", "duration"}` envelope, comes
  # back on the live API as the raw audio bytes directly (confirmed
  # against a real endpoint) — see `decode_xai_audio/3`.
  defp xai_text_to_speech(endpoint, text, opts) do
    base = endpoint.base_url || Endpoint.default_base_url("xai")
    url = "#{String.trim_trailing(base, "/")}/tts"
    headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
    format = Keyword.get(opts, :response_format, "mp3")

    body =
      %{"text" => text, "language" => Keyword.get(opts, :language, "auto")}
      |> maybe_add("voice_id", Keyword.get(opts, :voice_id) || Keyword.get(opts, :voice))
      |> maybe_add("output_format", xai_output_format(format, opts))
      |> maybe_add("speed", Keyword.get(opts, :speed))
      |> maybe_add("with_timestamps", Keyword.get(opts, :with_timestamps))

    start_time = System.monotonic_time(:millisecond)

    case Limiter.run(endpoint, opts, fn -> http_post(url, headers, body, opts) end) do
      {:ok, %{status_code: 200, body: response_body}} ->
        decode_xai_audio(response_body, format, start_time)

      {:ok, %{status_code: status, body: response_body}} ->
        handle_error_status(status, response_body)

      {:error, reason} when reason in [:concurrency_limit_timeout, :concurrency_queue_full] ->
        {:error, reason}

      {:error, :timeout} ->
        {:error, :request_timeout}

      {:error, reason} ->
        Logger.warning("xAI TTS transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp xai_output_format(codec, opts) do
    %{}
    |> maybe_add("codec", codec)
    |> maybe_add("sample_rate", Keyword.get(opts, :sample_rate))
    |> maybe_add("bit_rate", Keyword.get(opts, :bit_rate))
  end

  # xAI's docs describe `{"audio": <base64>, "content_type", "duration"}`,
  # but the live API returns the raw audio bytes directly (verified against
  # a real endpoint: status 200, body starting with an MP3 frame-sync byte,
  # not JSON) — *unless* `with_timestamps: true` was requested, in which case
  # it genuinely does return that JSON envelope (now also carrying
  # "audio_timestamps"), since there'd be nowhere else to put the timing data.
  # Fall back to raw-binary only when the body fails to parse as JSON at all —
  # unlike `decode_audio/3`'s broader "any non-matching JSON shape" fallback,
  # this stays narrow on purpose: a body that *is* valid JSON but missing/null
  # `"audio"` is a real error response, not an audio file, and must still
  # surface as `:invalid_audio_response` rather than being handed back as
  # bogus "audio" bytes (the JSON text itself).
  defp decode_xai_audio(response_body, format, start_time) do
    latency_ms = System.monotonic_time(:millisecond) - start_time

    {audio, timestamps} =
      case Jason.decode(response_body) do
        {:ok, %{"audio" => b64} = json} when is_binary(b64) ->
          bytes =
            case Base.decode64(b64) do
              {:ok, bytes} -> bytes
              :error -> nil
            end

          {bytes, parse_xai_timestamps(json["audio_timestamps"])}

        {:ok, _other_json} ->
          {nil, nil}

        {:error, _} ->
          # Not JSON at all → assume raw binary audio body (never has
          # timestamps — that shape only exists when with_timestamps forced
          # the JSON envelope in the first place).
          {response_body, nil}
      end

    case audio do
      bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
        {:ok, %{audio: bytes, format: format, latency_ms: latency_ms, timestamps: timestamps}}

      _ ->
        {:error, :invalid_audio_response}
    end
  end

  # "graph_chars"/"graph_times" are parallel arrays (every input character, in
  # order, paired with a [start, end] in seconds) — zipped once here into a flat
  # list of maps so every caller doesn't have to redo it. `nil` when
  # with_timestamps wasn't requested (no "audio_timestamps" key at all) or the
  # response doesn't match the documented shape.
  defp parse_xai_timestamps(%{"graph_chars" => chars, "graph_times" => times})
       when is_list(chars) and is_list(times) and length(chars) == length(times) do
    Enum.zip(chars, times)
    |> Enum.map(fn
      {char, [start_t, end_t]} -> %{char: char, start: start_t, end: end_t}
      {char, _other} -> %{char: char, start: nil, end: nil}
    end)
  end

  defp parse_xai_timestamps(_), do: nil

  # Gate `instructions` on the model, not the provider: OpenAI's own
  # `tts-1` / `tts-1-hd` predate steering and don't accept the field
  # either, so a provider-level allowlist would still send it to those.
  # Default to "unsupported" for anything else — sending the field to a
  # model that rejects it is a hard 422 (Mistral's `voxtral-*-tts`),
  # while dropping it for a model that would have accepted it just loses
  # a pronunciation/tone hint. The safer failure mode wins.
  defp instructions_for(model, instructions)
       when is_binary(instructions) and instructions != "" do
    if supports_instructions?(model) do
      instructions
    else
      Logger.debug(
        "TTS instructions dropped: model #{inspect(model)} is not known to support steering"
      )

      nil
    end
  end

  defp instructions_for(_model, _instructions), do: nil

  # OpenAI publishes dated snapshots of this family too (e.g.
  # `gpt-4o-mini-tts-2025-12-15`) — the trailing `-YYYY-MM-DD` is optional so a
  # pinned snapshot still matches, not just the bare model name.
  defp supports_instructions?(model) when is_binary(model) do
    model
    |> String.split("/")
    |> List.last()
    |> then(&Regex.match?(~r/^gpt-4o.*-tts(-\d{4}-\d{2}-\d{2})?$/, &1))
  end

  defp supports_instructions?(_model), do: false

  # The provider may return either base64 JSON (`{"audio_data": "..."}`,
  # Mistral hosted) or a raw binary audio body (OpenRouter / OSS vLLM).
  # `http_post/3` re-encodes a decoded JSON map back to a string and
  # passes a binary body through `to_string/1` unchanged, so try the
  # JSON-with-base64 shape first and fall back to raw bytes.
  defp decode_audio(response_body, format, start_time) do
    latency_ms = System.monotonic_time(:millisecond) - start_time

    audio =
      case Jason.decode(response_body) do
        {:ok, %{"audio_data" => b64}} when is_binary(b64) ->
          case Base.decode64(b64) do
            {:ok, bytes} -> bytes
            :error -> nil
          end

        _ ->
          # Not JSON (or no audio_data) → assume raw binary audio body.
          response_body
      end

    case audio do
      bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
        # Neither Mistral's nor OpenAI's /audio/speech has any equivalent to xAI's
        # with_timestamps — always nil here, never omitted, so a caller can safely
        # read result.timestamps regardless of which provider answered.
        {:ok, %{audio: bytes, format: format, latency_ms: latency_ms, timestamps: nil}}

      _ ->
        {:error, :invalid_audio_response}
    end
  end

  @doc """
  Generates image(s) from a text prompt via the provider's
  `POST /images/generations` endpoint.

  Unlike TTS, this one genuinely is the same path and response envelope
  across OpenAI, OpenRouter, and xAI — `{"data": [{"url" | "b64_json",
  ...}]}` — so a single implementation covers all three; only the
  optional request fields differ per provider/model family.

  ## Options

  - `:n` - Number of images to generate (default 1; provider-limited —
    e.g. DALL-E 3 only supports 1)
  - `:response_format` - `"url"` or `"b64_json"` (DALL-E 2/3 only — GPT
    image models always return `b64_json` regardless; xAI honors it)
  - `:size` - Pixel dimensions, e.g. `"1024x1024"` (OpenAI / DALL-E / GPT
    image models)
  - `:quality` - `"standard"`/`"hd"` (DALL-E 3) or `"low"`/`"medium"`/`"high"`
    (GPT image models)
  - `:style` - `"vivid"`/`"natural"` (DALL-E 3 only)
  - `:background`, `:output_format` - GPT image models only
  - `:aspect_ratio` - e.g. `"16:9"` (**xAI only**)
  - `:resolution` - `"1k"` or `"2k"` (**xAI only**)

  Only options the caller passes are sent — the module stays
  provider-neutral and does not assume which fields a given model
  supports.

  ## Returns

  - `{:ok, %{images: [%{url: String.t() | nil, data: binary() | nil}], latency_ms: integer()}}` —
    `data` is the decoded bytes when the provider returned `b64_json`;
    `url` is the provider's URL when it returned one instead (DALL-E's
    default, valid ~60 minutes). Never both nil for a successfully
    decoded entry.
  - `{:error, reason}` - Error atom or tagged tuple. See
    `PhoenixKitAI.Errors` for the full reason vocabulary and translation.
  """
  @spec generate_image(Endpoint.t(), String.t(), keyword()) ::
          {:ok, Provider.image_result()} | {:error, term()}
  def generate_image(endpoint, prompt, opts \\ []) do
    adapter = Provider.for_endpoint(endpoint)
    options = Images.options(endpoint, opts)

    with {:ok, result} <- adapter.image_generate(endpoint, prompt, options),
         {:ok, result} <- Images.fetch_outputs(result, opts) do
      {:ok, Map.put_new(result, :model, options[:model] || endpoint.model)}
    end
  end

  @doc """
  Edits or restyles one or more input images according to `prompt`,
  through the endpoint's `PhoenixKitAI.Provider` adapter:

    * OpenRouter — `POST /images` with `input_references` (the unified
      Images API; `transport: :chat` keeps the chat-completions path)
    * xAI — `POST /images/edits` as JSON
    * OpenAI — `POST /images/edits` as multipart
    * anything else — `POST /chat/completions` with `image_url` parts

  `images` is a non-empty list of raw bytes, `%{data:, content_type:}`
  maps, `%{url:}` maps or bare `data:` / `http(s):` strings
  (`PhoenixKitAI.Images.normalize_inputs/1`). Bytes are inlined; never
  hand a provider a permanent URL it could cache. The image to change
  goes first, references after it.

  `opts` are the canonical options of `PhoenixKitAI.Images` —
  `:aspect_ratio`, `:resolution`, `:size`, `:quality`, `:background`,
  `:output_format`, `:output_compression`, `:n`, `:seed` — plus `:model`,
  `:transport`, `:provider_options`, and the legacy `:image_config`
  passthrough for the chat path. They are sent as given; use
  `PhoenixKitAI.Images.process/4` to have them fitted to the model.

  Returns `{:ok, %{images: [%{data, url, content_type}], text, usage,
  latency_ms, model}}`; a prose-only answer is
  `{:error, {:no_image_in_response, text}}`.
  """
  @spec edit_image(Endpoint.t(), String.t(), [PhoenixKitAI.Images.input()], keyword()) ::
          {:ok, Provider.image_result()} | {:error, term()}
  def edit_image(endpoint, prompt, images, opts \\ [])

  def edit_image(_endpoint, _prompt, [], _opts), do: {:error, :empty_input}

  def edit_image(endpoint, prompt, images, opts) when is_binary(prompt) and is_list(images) do
    adapter = Provider.for_endpoint(endpoint)
    options = Images.options(endpoint, opts)

    with {:ok, refs} <- Images.normalize_inputs(images, opts),
         {:ok, options} <- Images.normalize_mask(options, opts[:mask], opts),
         {:ok, result} <- adapter.image_edit(endpoint, prompt, refs, options),
         {:ok, result} <- Images.fetch_outputs(result, opts) do
      {:ok, Map.put_new(result, :model, options[:model] || endpoint.model)}
    end
  end

  @doc false
  # Public for tests. Splits a data URL into bytes + MIME type; passes an
  # http(s) URL through with no bytes.
  def decode_image_url("data:" <> rest) do
    with [meta, payload] <- String.split(rest, ",", parts: 2),
         {:ok, bytes} <- decode_data_payload(meta, payload) do
      content_type = meta |> String.split(";") |> List.first()
      %{data: bytes, url: nil, content_type: if(content_type == "", do: nil, else: content_type)}
    else
      _ -> %{data: nil, url: nil, content_type: nil}
    end
  end

  def decode_image_url(url) when is_binary(url), do: %{data: nil, url: url, content_type: nil}

  defp decode_data_payload(meta, payload) do
    if String.contains?(meta, ";base64"),
      do: Base.decode64(payload, ignore: :whitespace),
      else: {:ok, URI.decode(payload)}
  end

  @doc """
  Extracts the text content from a chat completion response.
  """
  def extract_content(response) do
    case response do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
        {:ok, content}

      # Some providers leave `content` out of a tool-calling answer.
      %{"choices" => [%{"message" => %{"tool_calls" => [_ | _]}} | _]} ->
        {:ok, nil}

      %{"choices" => []} ->
        {:error, :no_choices_in_response}

      _ ->
        {:error, :invalid_response_format}
    end
  end

  @doc """
  Extracts the tool calls the model asked for from a chat completion response
  (`choices[0].message.tool_calls`), as the provider sent them:

      [%{"id" => "call_1", "type" => "function",
         "function" => %{"name" => "get_order", "arguments" => "{\\"number\\":\\"A-1\\"}"}}]

  `arguments` stays the JSON string the model wrote; decoding it is the
  caller's job. Returns `[]` when the model called nothing or the response
  has no such shape.
  """
  @spec extract_tool_calls(term()) :: [map()]
  def extract_tool_calls(%{
        "choices" => [%{"message" => %{"tool_calls" => [_ | _] = calls}} | _]
      }),
      do: calls

  def extract_tool_calls(_response), do: []

  @doc """
  Extracts the reasoning / chain-of-thought from a chat completion response,
  for reasoning models (DeepSeek-R1, Mistral Magistral, OpenAI o-series, etc.).

  Different providers put the chain-of-thought in different fields:
  - OpenRouter (and most providers it proxies): `message.reasoning`
  - DeepSeek native API: `message.reasoning_content`
  - Some providers may use `message.thinking`

  Returns the first non-empty string found, or `nil` if no reasoning is
  present (i.e. for non-reasoning models or when the operator opted out
  of returning reasoning via `reasoning_exclude: true`).

  ## `reasoning_exclude: true` and buggy providers

  The endpoint's `reasoning_exclude` flag controls the REQUEST payload —
  it tells the provider not to send reasoning back. A correctly-behaving
  provider then returns a response without any of the three reasoning
  fields and `extract_reasoning/1` returns `nil`.

  A buggy provider (or one that doesn't honour the flag) might still
  include reasoning. We deliberately extract it anyway rather than
  gating the response-side capture on `reasoning_exclude` — the
  reasoning in `metadata.response_reasoning` then doubles as a
  breadcrumb that lets operators correlate "request asked for no
  reasoning but provider sent it anyway" against a specific provider
  + model + request id (PR #6 review finding #9). PII / data-retention
  concerns are covered by the `capture_request_content?/0`
  application-config gate — when content capture is off, the
  `response_reasoning` metadata is dropped too.

  If you specifically want "discard reasoning when `reasoning_exclude:
  true` regardless of what the provider sent", that's a separate
  faithfulness-mode opt the caller would have to set on top of this
  helper. The helper itself stays transparent.
  """
  @spec extract_reasoning(map()) :: String.t() | nil
  def extract_reasoning(response) do
    case response do
      %{"choices" => [%{"message" => message} | _]} when is_map(message) ->
        first_present_string(message, ["reasoning", "reasoning_content", "thinking"])

      _ ->
        nil
    end
  end

  defp first_present_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  @doc """
  Extracts usage information from a response.

  Returns a map with token counts and cost (if available from OpenRouter).
  `cost` is what the provider reported, in US dollars, as a `Decimal` — a
  JSON float read through its shortest decimal form, so `3.0e-5` is exactly
  `0.00003` and a short embedding at $0.00000004 keeps its cost. Not rounded
  here: `PhoenixKitAI.CallCost` rounds a call's cost once.
  """
  def extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cost: parse_cost(usage["cost"] || usage["total_cost"])
    }
  end

  def extract_usage(_response) do
    %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, cost: nil}
  end

  # A cost the provider sent: a number (or a decimal string), never negative.
  defp parse_cost(cost) when is_number(cost) or is_binary(cost) do
    case PhoenixKitAI.Money.to_decimal(cost) do
      {:ok, decimal} -> if Decimal.negative?(decimal), do: nil, else: decimal
      :error -> nil
    end
  end

  defp parse_cost(_), do: nil

  @doc false
  # A message as it goes over the wire and into the usage log, string keys
  # either way. `role` and `content` always; the tool fields only where the
  # protocol has them and only when present, so a message without them
  # encodes exactly as it always did: `tool_calls` on `assistant`,
  # `tool_call_id` and `name` on `tool`. `content` may be nil (an assistant
  # message that only calls tools).
  def normalize_message(msg) do
    role = to_string(msg[:role] || msg["role"])

    %{"role" => role, "content" => msg[:content] || msg["content"]}
    |> put_tool_fields(role, msg)
  end

  defp put_tool_fields(message, "assistant", msg),
    do: maybe_add(message, "tool_calls", msg[:tool_calls] || msg["tool_calls"])

  defp put_tool_fields(message, "tool", msg) do
    message
    |> maybe_add("tool_call_id", msg[:tool_call_id] || msg["tool_call_id"])
    |> maybe_add("name", msg[:name] || msg["name"])
  end

  defp put_tool_fields(message, _role, _msg), do: message

  # Private functions

  defp build_chat_body(endpoint, messages, opts) do
    normalized_messages = Enum.map(messages, &normalize_message/1)

    %{
      "model" => endpoint.model,
      "messages" => normalized_messages
    }
    |> maybe_add("temperature", Keyword.get(opts, :temperature))
    |> maybe_add("max_tokens", Keyword.get(opts, :max_tokens))
    |> maybe_add("top_p", Keyword.get(opts, :top_p))
    |> maybe_add("top_k", Keyword.get(opts, :top_k))
    |> maybe_add("frequency_penalty", Keyword.get(opts, :frequency_penalty))
    |> maybe_add("presence_penalty", Keyword.get(opts, :presence_penalty))
    |> maybe_add("repetition_penalty", Keyword.get(opts, :repetition_penalty))
    |> maybe_add("stop", Keyword.get(opts, :stop))
    |> maybe_add("seed", Keyword.get(opts, :seed))
    |> maybe_add("stream", Keyword.get(opts, :stream))
    |> maybe_add("response_format", Keyword.get(opts, :response_format))
    |> maybe_add("tools", Keyword.get(opts, :tools))
    |> maybe_add("tool_choice", Keyword.get(opts, :tool_choice))
    |> maybe_add("parallel_tool_calls", Keyword.get(opts, :parallel_tool_calls))
    |> maybe_add_reasoning(opts)
    |> maybe_require_parameters(opts)
    |> provider_rules(endpoint)
  end

  # Set by the call-time guard for a call with a hard requirement on
  # OpenRouter: route only to upstream providers that take every parameter.
  defp maybe_require_parameters(body, opts) do
    if Keyword.get(opts, :require_parameters) == true,
      do: Map.put(body, "provider", %{"require_parameters" => true}),
      else: body
  end

  # Anthropic's OpenAI-compatible layer: never `temperature` and `top_p`
  # together (a 400 on its own; `temperature` is kept), and none of
  # `temperature`, `top_p`, `top_k` to a model from Claude Opus 4.7 on,
  # which refuses each even when the caller set it (`anthropic_sampling?/1`); no penalties and no `seed`
  # (ignored there); the OpenRouter-shaped `reasoning` object, which that
  # layer silently ignores, becomes its `thinking` field.
  defp provider_rules(body, endpoint) do
    if anthropic?(endpoint) do
      body
      |> Map.drop(["frequency_penalty", "presence_penalty", "repetition_penalty", "seed"])
      |> anthropic_sampling(endpoint.model)
      |> anthropic_thinking(endpoint)
    else
      body
    end
  end

  defp anthropic_sampling(body, model) do
    cond do
      not anthropic_sampling?(model) -> Map.drop(body, ["temperature", "top_p", "top_k"])
      Map.has_key?(body, "temperature") -> Map.delete(body, "top_p")
      true -> body
    end
  end

  # The first Claude that refuses `temperature`, `top_p` and `top_k` (a 400, "… is
  # deprecated for this model"); checked against live models in
  # BeamLabEU/phoenix_kit_ai#42.
  @anthropic_no_sampling_since {4, 7}

  @doc false
  # Whether an Anthropic model takes sampling (`temperature` / `top_p`, one
  # of them, and `top_k`):
  # a model older than Claude Opus 4.7. Its catalogue entry does not say, so
  # the model id decides; an id this cannot read is taken for a newer model.
  @spec anthropic_sampling?(String.t() | nil) :: boolean()
  def anthropic_sampling?(model_id) do
    case anthropic_version(model_id) do
      nil -> false
      version -> version < @anthropic_no_sampling_since
    end
  end

  # `claude-opus-4-5-20251101`, `claude-opus-5`, `claude-fable-5-1`, and the
  # older `claude-3-5-sonnet-20241022` naming.
  defp anthropic_version(id) when is_binary(id) do
    id = id |> String.split("/") |> List.last()

    case Regex.run(~r/^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?:-(?:\d{8}|latest))?$/, id) ||
           Regex.run(~r/^claude-(\d+)(?:-(\d{1,2}))?-[a-z]+/, id) do
      [_, major] -> {String.to_integer(major), 0}
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      nil -> nil
    end
  end

  defp anthropic_version(_id), do: nil

  # Each `thinking` form is sent only to a model whose catalogue entry says
  # it accepts it — a form it does not take is a 400. Otherwise no `thinking`
  # field is sent at all, which leaves the model's default: Claude 5 models
  # think, earlier ones do not.
  #
  #   * `enabled: false` → `{"type": "disabled"}` (`thinking_disabled: :yes`),
  #     else `{"type": "between_tools"}` (`thinking_between_tools: :yes`, the
  #     way Claude Sonnet 5.5 is told not to think); a model that takes
  #     neither (Claude Opus 5.5) keeps thinking;
  #   * a token budget → `{"type": "enabled", "budget_tokens": n}`
  #     (`thinking_enabled: :yes`).
  #
  # Adaptive thinking and its effort are not sent: the compatibility layer
  # answers `{"type": "adaptive"}` with a 400 ("not available via the
  # OpenAI compatibility endpoint") and ignores `reasoning_effort` and
  # `output_config`. `enabled: true` or an effort alone is the model's
  # default. (Ported from BeamLabEU/phoenix_kit_ai#47, 8e8c65e.)
  defp anthropic_thinking(%{"reasoning" => reasoning} = body, endpoint) do
    caps = Capabilities.for_endpoint(endpoint)

    thinking =
      if reasoning["enabled"] != false and
           budget_not_below_max?(reasoning["max_tokens"], body["max_tokens"], caps),
         do: nil,
         else: thinking_form(reasoning, caps)

    body
    |> Map.delete("reasoning")
    |> maybe_add("thinking", thinking)
  end

  defp anthropic_thinking(body, _endpoint), do: body

  @doc false
  # Whether a call's thinking budget would go out as `budget_tokens` while
  # not below its `max_tokens` — a 400 on a budget-only model, so no
  # `thinking` is sent. The verbs note it on the usage row.
  @spec thinking_budget_skipped?(Endpoint.t(), keyword()) :: boolean()
  def thinking_budget_skipped?(endpoint, opts) do
    opts[:reasoning_enabled] != false and anthropic?(endpoint) and
      budget_not_below_max?(
        opts[:reasoning_max_tokens],
        opts[:max_tokens],
        Capabilities.for_endpoint(endpoint)
      )
  end

  defp budget_not_below_max?(budget, max_tokens, caps) do
    is_integer(budget) and is_integer(max_tokens) and budget >= max_tokens and
      thinking_flag(caps, :thinking_enabled) == :yes
  end

  defp thinking_form(%{"enabled" => false}, caps) do
    cond do
      thinking_flag(caps, :thinking_disabled) == :yes -> %{"type" => "disabled"}
      thinking_flag(caps, :thinking_between_tools) == :yes -> %{"type" => "between_tools"}
      true -> nil
    end
  end

  defp thinking_form(%{"max_tokens" => budget}, caps) when is_integer(budget) do
    if thinking_flag(caps, :thinking_enabled) == :yes,
      do: %{"type" => "enabled", "budget_tokens" => budget}
  end

  defp thinking_form(_reasoning, _caps), do: nil

  defp thinking_flag(%Capabilities{} = caps, flag), do: Map.fetch!(caps, flag)
  defp thinking_flag(_caps, _flag), do: :unknown

  # Build reasoning object for OpenRouter API
  # See: https://openrouter.ai/docs/guides/best-practices/reasoning-tokens
  defp maybe_add_reasoning(body, opts) do
    reasoning_enabled = Keyword.get(opts, :reasoning_enabled)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning_max_tokens = Keyword.get(opts, :reasoning_max_tokens)
    reasoning_exclude = Keyword.get(opts, :reasoning_exclude)

    # Build reasoning object only if any reasoning option is set
    reasoning =
      %{}
      |> maybe_add("enabled", reasoning_enabled)
      |> maybe_add("effort", reasoning_effort)
      |> maybe_add("max_tokens", reasoning_max_tokens)
      |> maybe_add("exclude", reasoning_exclude)

    if map_size(reasoning) > 0 do
      Map.put(body, "reasoning", reasoning)
    else
      body
    end
  end

  # OpenRouter model routing: `models: [...]` lets OpenRouter fall back to the next
  # model when one is down, rate-limited or refuses (https://openrouter.ai/docs —
  # "Model routing"). The call's model stays first. Other providers have no such
  # parameter, so `models:` is not sent to them.
  defp maybe_add_fallback_models(body, endpoint, model, [_ | _] = models) do
    if Endpoint.openrouter?(endpoint),
      do: Map.put(body, "models", Enum.uniq([model | models])),
      else: body
  end

  defp maybe_add_fallback_models(body, _endpoint, _model, _), do: body

  # OpenRouter reports the call's cost in `usage.cost` when asked
  # (`usage: {include: true}`) — without it chat rows were logged with no cost.
  defp maybe_include_usage(body, endpoint) do
    if Endpoint.openrouter?(endpoint),
      do: Map.put(body, "usage", %{"include" => true}),
      else: body
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  # One provider POST, plus retries when the call (or the app env `:retry`) asks for
  # them. `opts`: `timeout:` (ms, default the app env `:timeout` or 120 s) and
  # `retry:` — `true` for the defaults, a keyword list to tune them, `false` / unset
  # for none (the default, so a caller with its own retry logic is unaffected):
  #
  #   * `max_attempts` (3, the first try included), `base_delay` (1000 ms, doubled
  #     each attempt, ±20 % jitter), `max_delay` (30 s);
  #   * retried: HTTP 408, 429, 500, 502, 503, 504 and transport errors other than a
  #     timeout — never a 429 that is about money (`ProviderError`);
  #     `retry_timeouts: true` retries a timeout too (the provider may have
  #     done — and billed — the work a timed-out call never saw);
  #   * a `Retry-After` header (seconds) is honoured up to `max_delay`.
  #
  # Each retry emits `[:phoenix_kit_ai, :request, :retry]` and an info log line with
  # the status and attempt only — never the URL's query, a header or the body.
  defp http_post(url, headers, body, opts) do
    post_with_retry(url, Map.new(headers), body, opts, retry_policy(opts), 1)
  end

  defp retry_policy(opts) do
    case Keyword.get(opts, :retry, Application.get_env(:phoenix_kit_ai, :retry, false)) do
      true -> @retry_defaults
      policy when is_list(policy) -> Keyword.merge(@retry_defaults, policy)
      _ -> nil
    end
  end

  defp post_with_retry(url, headers, body, opts, policy, attempt) do
    result = post_once(url, headers, body, opts)

    if policy && attempt < policy[:max_attempts] && retryable?(result, policy) do
      delay = retry_delay(policy, attempt, retry_after(result))

      :telemetry.execute(
        [:phoenix_kit_ai, :request, :retry],
        %{attempt: attempt, delay_ms: delay},
        %{
          status: retry_status(result)
        }
      )

      Logger.info(
        "[PhoenixKitAI] retrying a provider call after #{retry_status(result)} " <>
          "(attempt #{attempt + 1} of #{policy[:max_attempts]}) in #{delay} ms"
      )

      Process.sleep(delay)
      post_with_retry(url, headers, body, opts, policy, attempt + 1)
    else
      strip_retry_after(result)
    end
  end

  # Money sent as a 429 (`ProviderError.class/2`: an exhausted quota or
  # balance) is never worth a retry: the answer would not change.
  defp retryable?({:ok, %{status_code: status, body: body}}, _policy) do
    status in @retry_statuses and
      ProviderError.class(status, ProviderError.parse(body)) != :insufficient_credits
  end

  defp retryable?({:error, :timeout}, policy), do: policy[:retry_timeouts] == true
  defp retryable?({:error, _transport}, _policy), do: true

  defp retry_status({:ok, %{status_code: status}}), do: "HTTP #{status}"
  defp retry_status({:error, :timeout}), do: "a timeout"
  defp retry_status({:error, _}), do: "a connection error"

  defp retry_after({:ok, %{retry_after: seconds}}) when is_integer(seconds), do: seconds
  defp retry_after(_), do: nil

  defp strip_retry_after({:ok, response}), do: {:ok, Map.delete(response, :retry_after)}
  defp strip_retry_after(other), do: other

  @doc false
  # Public for testing: the pause before retry number `attempt` (1-based).
  def retry_delay(policy, attempt, retry_after_s) do
    exp = policy[:base_delay] * Integer.pow(2, attempt - 1)
    jittered = round(exp * (0.8 + :rand.uniform() * 0.4))
    wait = if retry_after_s, do: max(jittered, retry_after_s * 1000), else: jittered
    min(wait, policy[:max_delay])
  end

  defp post_once(url, headers_map, body, opts) do
    timeout =
      Keyword.get(opts, :timeout) || Application.get_env(:phoenix_kit_ai, :timeout, @timeout)

    # Redirects are not followed: the endpoint's base URL passed the SSRF
    # guard when it was saved, and a 30x would let that public host send
    # the request to an internal one. No supported provider answers its
    # API with a redirect.
    base_opts = [
      json: body,
      headers: headers_map,
      redirect: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout]
    ]

    # `:req_options` is empty in production. Tests opt in via
    # `Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, Stub})`.
    req_opts = base_opts ++ Application.get_env(:phoenix_kit_ai, :req_options, [])

    :ok = ProviderError.clear()

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: response_body} = response} ->
        if status not in 200..299, do: ProviderError.put_retry_after(response)

        # Req automatically decodes JSON, so encode it back to string for consistency
        body_string =
          if is_map(response_body) or is_list(response_body) do
            Jason.encode!(response_body)
          else
            to_string(response_body)
          end

        {:ok, %{status_code: status, body: body_string, retry_after: retry_after_s(response)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("HTTP POST transport error: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("HTTP POST failed with unexpected error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # `Retry-After` in whole seconds, rounded up (`Req.Response.get_retry_after/1`
  # reads both the seconds and the HTTP-date form), or nil — also for a value
  # it cannot read, which it raises on.
  defp retry_after_s(%Req.Response{} = response) do
    case Req.Response.get_retry_after(response) do
      ms when is_integer(ms) and ms >= 0 -> div(ms + 999, 1000)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  # Public for testability. Parses an OpenRouter error body and returns
  # the human-readable message, or nil if the shape is unrecognised.
  def extract_error_message(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _ -> nil
    end
  end

  @doc false
  # The endpoint's base URL plus `path`; adapters build every request
  # with it. Raises when neither the row nor its provider has a base URL.
  def url(endpoint, path), do: build_url(endpoint, path)

  defp build_url(endpoint, path) do
    # Falls back to the provider's canonical default base url when the
    # endpoint row has none — covers legacy rows persisted before the
    # changeset gained `maybe_set_default_base_url`. Hardcoding
    # OpenRouter's URL here would silently misroute Mistral / DeepSeek
    # traffic.
    base =
      cond do
        is_binary(endpoint.base_url) and endpoint.base_url != "" -> endpoint.base_url
        is_binary(endpoint.provider) -> Endpoint.default_base_url(endpoint.provider)
        true -> nil
      end

    case base do
      nil ->
        raise ArgumentError,
              "endpoint #{inspect(endpoint.uuid)} has no base_url and " <>
                "provider #{inspect(endpoint.provider)} has no default — " <>
                "edit the endpoint to set a base_url"

      base ->
        "#{String.trim_trailing(base, "/")}#{path}"
    end
  end
end
