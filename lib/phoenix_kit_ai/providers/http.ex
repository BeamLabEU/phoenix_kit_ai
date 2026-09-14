defmodule PhoenixKitAI.Providers.HTTP do
  @moduledoc false
  # The one HTTP door for provider adapters. Same `:req_options` hook as
  # `PhoenixKitAI.Completion`, so tests stub every adapter with one
  # `Req.Test` plug; transport errors come back in the module's error
  # vocabulary.

  require Logger

  alias PhoenixKitAI.Completion

  @timeout 120_000

  @type response :: %{status: non_neg_integer(), body: term()}

  @spec post_json(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def post_json(url, headers, body, opts \\ []),
    do: request(:post, url, [json: body, headers: Map.new(headers)], opts)

  @spec post_multipart(String.t(), [{String.t(), String.t()}], list(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def post_multipart(url, headers, form, opts \\ []),
    do: request(:post, url, [form_multipart: form, headers: Map.new(headers)], opts)

  @spec get_json(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, response()} | {:error, term()}
  def get_json(url, headers, opts \\ []),
    do: request(:get, url, [headers: Map.new(headers)], opts)

  defp request(method, url, req_opts, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    all =
      [method: method, url: url] ++
        req_opts ++
        [receive_timeout: timeout, connect_options: [timeout: timeout]] ++
        Application.get_env(:phoenix_kit_ai, :req_options, [])

    case Req.request(all) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :request_timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("[PhoenixKitAI] #{method} #{url} transport error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}

      {:error, reason} ->
        Logger.error("[PhoenixKitAI] #{method} #{url} failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc "The response body as JSON text (Req decodes JSON bodies for us)."
  @spec body_string(term()) :: String.t()
  def body_string(body) when is_map(body) or is_list(body), do: Jason.encode!(body)
  def body_string(body), do: to_string(body)

  @doc "The response body as a map, decoding when Req left it as text."
  @spec body_map(term()) :: {:ok, map()} | {:error, :invalid_json_response}
  def body_map(body) when is_map(body), do: {:ok, body}

  def body_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json_response}
    end
  end

  def body_map(_body), do: {:error, :invalid_json_response}

  @doc "A non-200 status mapped through the shared error vocabulary."
  @spec error(non_neg_integer(), term()) :: {:error, term()}
  def error(status, body), do: Completion.handle_error_status(status, body_string(body))
end
