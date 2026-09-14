defmodule PhoenixKitAI.Providers.HTTP do
  @moduledoc false
  # The one HTTP door for provider adapters. Same `:req_options` hook as
  # `PhoenixKitAI.Completion`, so tests stub every adapter with one
  # `Req.Test` plug; transport errors come back in the module's error
  # vocabulary.

  require Logger

  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Providers.OpenAICompatible

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

  @doc """
  A non-200 status mapped through the shared error vocabulary. A 4xx
  whose message reads as a safety refusal becomes `{:content_policy,
  message}`, so pipelines can stop retrying instead of looping on a
  generic `{:api_error, 400}`.
  """
  @spec error(non_neg_integer(), term()) :: {:error, term()}
  def error(status, body) do
    text = body_string(body)

    with true <- status in [400, 403, 422],
         message when is_binary(message) <- Completion.extract_error_message(text),
         true <-
           Regex.match?(
             ~r/safety|content[ _-]?policy|moderat|blocked|prohibited|violat/i,
             message
           ) do
      {:error, {:content_policy, message}}
    else
      _ -> Completion.handle_error_status(status, text)
    end
  end

  @max_image_bytes 25_000_000

  @doc "The largest image (input or fetched output) the module handles, in bytes."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes,
    do: Application.get_env(:phoenix_kit_ai, :max_image_bytes, @max_image_bytes)

  @doc """
  Whether an http(s) URL may be fetched on the caller's behalf: http or
  https, a host that is not loopback, link-local, RFC 1918 or `.local`
  — unless `:allow_internal_endpoint_urls` is set, the same switch the
  endpoint base-URL guard honours.
  """
  @spec safe_url?(String.t()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        Application.get_env(:phoenix_kit_ai, :allow_internal_endpoint_urls, false) or
          not internal_host?(host)

      _ ->
        false
    end
  end

  def safe_url?(_url), do: false

  defp internal_host?(host) do
    host = String.downcase(host)

    cond do
      host in ["localhost", "0.0.0.0", "::1"] -> true
      String.ends_with?(host, ".local") or String.ends_with?(host, ".internal") -> true
      true -> private_ip?(host)
    end
  end

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_address?(address)
      {:error, _} -> false
    end
  end

  # IPv4: loopback, RFC 1918, link-local. IPv6: loopback, unique-local, link-local.
  defp private_address?({a, b, _, _}),
    do:
      a in [10, 127] or {a, b} == {169, 254} or {a, b} == {192, 168} or (a == 172 and b in 16..31)

  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}), do: a in [0xFC00, 0xFD00, 0xFE80]

  @doc """
  Downloads an image the module was handed a URL for (a caller's input
  on providers that need bytes, or a provider's output URL), bounded by
  `max_image_bytes/0`, two redirects, 60 s. Returns the bytes and the
  sniffed content type.
  """
  @spec fetch_image(String.t(), keyword()) ::
          {:ok, binary(), String.t() | nil} | {:error, term()}
  def fetch_image(url, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, max_image_bytes())

    if safe_url?(url) do
      req_opts =
        [decode_body: false, max_redirects: 2, receive_timeout: 60_000] ++
          Application.get_env(:phoenix_kit_ai, :req_options, [])

      case Req.get(url, req_opts) do
        {:ok, %Req.Response{status: 200, body: bytes}}
        when is_binary(bytes) and byte_size(bytes) > max ->
          {:error, {:image_too_large, byte_size(bytes), max}}

        {:ok, %Req.Response{status: 200, body: bytes}} when is_binary(bytes) and bytes != "" ->
          {:ok, bytes, OpenAICompatible.sniff(bytes)}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:fetch_failed, url, status}}

        {:error, reason} ->
          {:error, {:fetch_failed, url, reason}}
      end
    else
      {:error, {:unsafe_url, url}}
    end
  end
end
