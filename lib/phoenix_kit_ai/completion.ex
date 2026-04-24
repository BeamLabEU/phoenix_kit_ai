defmodule PhoenixKitAI.Completion do
  @moduledoc """
  OpenRouter completion client for making AI API calls.

  This module handles the actual HTTP requests to OpenRouter's chat completions
  and other endpoints. It's used internally by `PhoenixKitAI` public functions.

  ## Supported Endpoints

  - `/chat/completions` - Text and vision completions
  - `/embeddings` - Text embeddings
  - `/images/generations` - Image generation (planned)

  ## Logging conventions

  - `Logger.warning` — expected/recoverable external failures (non-2xx HTTP
    responses, transport errors, rate limits). Callers see a user-facing error.
  - `Logger.error` — unexpected internal failures (unknown error shapes,
    parse failures).
  """

  require Logger

  alias PhoenixKitAI.OpenRouterClient

  @base_url "https://openrouter.ai/api/v1"
  @timeout 120_000

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
    body = build_chat_body(endpoint.model, messages, opts)
    start_time = System.monotonic_time(:millisecond)

    case http_post(url, headers, body) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_success_response(response_body, start_time)

      {:ok, %{status_code: status, body: response_body}} ->
        handle_error_status(status, response_body)

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
      {:ok, response} -> {:ok, Map.put(response, "latency_ms", latency_ms)}
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  @doc false
  # Public for testability. Maps an HTTP status + response body to a
  # `{:error, reason}` tuple where `reason` is an atom or tagged tuple.
  def handle_error_status(401, _body), do: {:error, :invalid_api_key}
  def handle_error_status(402, _body), do: {:error, :insufficient_credits}
  def handle_error_status(429, _body), do: {:error, :rate_limited}

  def handle_error_status(status, response_body) do
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
        "model" => endpoint.model,
        "input" => input
      }
      |> maybe_add("dimensions", Keyword.get(opts, :dimensions))

    start_time = System.monotonic_time(:millisecond)

    case http_post(url, headers, body) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_success_response(response_body, start_time)

      {:ok, %{status_code: status, body: response_body}} ->
        handle_error_status(status, response_body)

      {:error, :timeout} ->
        {:error, :request_timeout}

      {:error, reason} ->
        Logger.warning("OpenRouter embeddings transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Extracts the text content from a chat completion response.
  """
  def extract_content(response) do
    case response do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
        {:ok, content}

      %{"choices" => []} ->
        {:error, :no_choices_in_response}

      _ ->
        {:error, :invalid_response_format}
    end
  end

  @doc """
  Extracts usage information from a response.

  Returns a map with token counts and cost (if available from OpenRouter).
  Cost is stored in nanodollars (1/1,000,000 of a dollar) to preserve precision
  for cheap API calls. Stored in the cost_cents field for backward compatibility.
  """
  def extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cost_cents: parse_cost(usage["cost"] || usage["total_cost"])
    }
  end

  def extract_usage(_response) do
    %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, cost_cents: nil}
  end

  # Store in nanodollars (1/1000000 of a dollar) for precision
  # e.g., $0.00003 becomes 30 nanodollars
  defp parse_cost(cost) when is_number(cost), do: round(cost * 1_000_000)
  defp parse_cost(_), do: nil

  # Private functions

  defp build_chat_body(model, messages, opts) do
    # Normalize messages to ensure string keys
    normalized_messages =
      Enum.map(messages, fn msg ->
        %{
          "role" => to_string(msg[:role] || msg["role"]),
          "content" => msg[:content] || msg["content"]
        }
      end)

    %{
      "model" => model,
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
    |> maybe_add_reasoning(opts)
  end

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

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp http_post(url, headers, body) do
    # Convert headers list to map format for Req
    headers_map = Map.new(headers)

    case Req.post(url,
           json: body,
           headers: headers_map,
           receive_timeout: @timeout,
           connect_options: [timeout: @timeout]
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        # Req automatically decodes JSON, so encode it back to string for consistency
        body_string =
          if is_map(response_body) or is_list(response_body) do
            Jason.encode!(response_body)
          else
            to_string(response_body)
          end

        {:ok, %{status_code: status, body: body_string}}

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

  defp build_url(endpoint, path) do
    base = endpoint.base_url || @base_url
    # Remove trailing slash from base if present
    base = String.trim_trailing(base, "/")
    "#{base}#{path}"
  end
end
