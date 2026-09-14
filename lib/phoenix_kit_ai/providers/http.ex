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
        [receive_timeout: timeout, connect_options: [timeout: min(timeout, 10_000)]] ++
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
  https, and a host that neither is nor resolves to a loopback,
  link-local, RFC 1918, CGNAT, unique-local, reserved or multicast
  address (IPv6 forms that embed an IPv4 address — mapped, compatible,
  NAT64, 6to4 — are judged by that address), nor ends in `.local` /
  `.internal`. Hostnames are resolved
  here so a public name pointing at an internal address is refused too.
  `:allow_internal_image_urls` lifts the policy (tests, air-gapped
  installs); it is deliberately separate from the endpoint base-URL
  switch, because a caller's image URL is not an operator's setting.
  """
  @spec safe_url?(String.t()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        Application.get_env(:phoenix_kit_ai, :allow_internal_image_urls, false) or
          not internal_host?(host)

      _ ->
        false
    end
  end

  def safe_url?(_url), do: false

  defp internal_host?(host) do
    host = host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")

    cond do
      host in ["localhost", "0.0.0.0"] -> true
      String.ends_with?(host, ".local") or String.ends_with?(host, ".internal") -> true
      true -> Enum.any?(addresses(host), &private_address?/1)
    end
  end

  # A literal address is itself; a name is every address it resolves to
  # right now. This is a best-effort check — a host that changes its
  # answer between this lookup and the connection (DNS rebinding) is out
  # of its reach; production installs should also firewall egress.
  defp addresses(host) do
    chars = String.to_charlist(host)

    case :inet.parse_address(chars) do
      {:ok, address} -> [address]
      {:error, _} -> resolve(chars)
    end
  end

  defp resolve(chars) do
    # A name that does not resolve yields [] — not internal; there is
    # nothing to connect to, and the fetch fails on its own.
    Enum.flat_map([:inet, :inet6], fn family ->
      case :inet.getaddrs(chars, family) do
        {:ok, list} -> list
        {:error, _} -> []
      end
    end)
  end

  # IPv4: "this" network, 10/8, loopback, and multicast plus everything
  # reserved above it (224.0.0.0 and up); the narrower blocks below.
  defp private_address?({a, b, c, _}),
    do: a in [0, 10, 127] or a >= 224 or reserved_v4_block?(a, b, c)

  # IPv6 forms that carry an IPv4 address are judged by that address:
  # IPv4-mapped (::ffff:a.b.c.d), IPv4-translated (::ffff:0:a.b.c.d),
  # IPv4-compatible (::a.b.c.d, which covers :: and ::1 as well), NAT64's
  # well-known prefix (64:ff9b::/96) and 6to4 (2002:aabb:ccdd::/48).
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private_address?(ipv4(hi, lo))
  defp private_address?({0, 0, 0, 0, 0xFFFF, 0, hi, lo}), do: private_address?(ipv4(hi, lo))
  defp private_address?({0, 0, 0, 0, 0, 0, hi, lo}), do: private_address?(ipv4(hi, lo))
  defp private_address?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: private_address?(ipv4(hi, lo))
  defp private_address?({0x2002, hi, lo, _, _, _, _, _}), do: private_address?(ipv4(hi, lo))
  # Local-use NAT64 (64:ff9b:1::/48) translates to whatever the site routes.
  defp private_address?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  # fc00::/7 (unique local), fe80::/10 (link local), ff00::/8 (multicast)
  defp private_address?({a, _, _, _, _, _, _, _}),
    do: a in 0xFC00..0xFDFF or a in 0xFE80..0xFEBF or a >= 0xFF00

  # Link-local, RFC 1918 (192.168/16, 172.16/12), CGNAT (100.64/10),
  # benchmarking (198.18/15) and IETF protocol assignments (192.0.0/24).
  defp reserved_v4_block?(169, 254, _c), do: true
  defp reserved_v4_block?(192, 168, _c), do: true
  defp reserved_v4_block?(172, b, _c) when b in 16..31, do: true
  defp reserved_v4_block?(100, b, _c) when b in 64..127, do: true
  defp reserved_v4_block?(198, b, _c) when b in 18..19, do: true
  defp reserved_v4_block?(192, 0, 0), do: true
  defp reserved_v4_block?(_a, _b, _c), do: false

  defp ipv4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  @doc """
  Downloads an image the module was handed a URL for (a caller's input
  on providers that need bytes, or a provider's output URL). Every hop is
  checked with `safe_url?/1` — redirects are followed by hand, two at
  most, so a public URL cannot bounce to an internal one — the body is
  streamed and abandoned the moment it passes `max_image_bytes/0`, and
  the connection has a 10 s connect / 60 s receive budget. Returns the
  bytes and the sniffed content type.
  """
  @spec fetch_image(String.t(), keyword()) ::
          {:ok, binary(), String.t() | nil} | {:error, term()}
  def fetch_image(url, opts \\ []), do: fetch_image(url, opts, 2)

  defp fetch_image(url, opts, hops_left) do
    max = Keyword.get(opts, :max_bytes, max_image_bytes())

    if safe_url?(url) do
      req_opts =
        [
          redirect: false,
          receive_timeout: 60_000,
          connect_options: [timeout: 10_000],
          into: bounded_collector(max)
        ] ++ Application.get_env(:phoenix_kit_ai, :req_options, [])

      case Req.get(url, req_opts) do
        {:ok, %Req.Response{status: 200, body: bytes}} when is_binary(bytes) and bytes != "" ->
          {:ok, bytes, OpenAICompatible.sniff(bytes)}

        {:ok, %Req.Response{status: 200, body: {:too_large, seen}}} ->
          {:error, {:image_too_large, seen, max}}

        {:ok, %Req.Response{status: status} = response}
        when status in [301, 302, 303, 307, 308] ->
          follow_redirect(url, response, opts, hops_left)

        {:ok, %Req.Response{status: status}} ->
          {:error, {:fetch_failed, url, status}}

        {:error, reason} ->
          {:error, {:fetch_failed, url, reason}}
      end
    else
      {:error, {:unsafe_url, url}}
    end
  end

  defp follow_redirect(_url, _response, _opts, 0),
    do: {:error, {:fetch_failed, :too_many_redirects}}

  defp follow_redirect(url, response, opts, hops_left) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        url |> URI.merge(location) |> URI.to_string() |> fetch_image(opts, hops_left - 1)

      [] ->
        {:error, {:fetch_failed, url, :redirect_without_location}}
    end
  end

  # Streams the body into the response, halting once it outgrows `max`;
  # a halted download leaves `{:too_large, bytes_seen}` as the body.
  defp bounded_collector(max) do
    fn {:data, chunk}, {req, resp} ->
      {verdict, body} = collect(resp.body, chunk, max)
      {verdict, {req, %{resp | body: body}}}
    end
  end

  defp collect({:too_large, _} = marker, _chunk, _max), do: {:halt, marker}

  defp collect(body, chunk, max) when is_binary(body) do
    seen = byte_size(body) + byte_size(chunk)
    if seen > max, do: {:halt, {:too_large, seen}}, else: {:cont, body <> chunk}
  end

  defp collect(_body, chunk, _max), do: {:cont, chunk}
end
