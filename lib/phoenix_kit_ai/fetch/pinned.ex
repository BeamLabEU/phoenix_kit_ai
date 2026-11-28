defmodule PhoenixKitAI.Fetch.Pinned do
  @moduledoc """
  The connection `PhoenixKitAI.Fetch` makes: one GET on Mint, to the address
  that was checked. The way core's `PhoenixKit.Modules.Storage.RemoteFetch`
  and the bookings module's iCal fetcher do it:

    * the host is resolved once and **every** address it resolves to must be
      public (`PhoenixKit.Utils.PublicAddress`: loopback, private,
      link-local, CGNAT, multicast, reserved and the IPv6 forms that carry an
      IPv4 address are refused) — unless the call allows internal hosts;
    * the connection goes to that address, with the name for `Host`, SNI and
      certificate verification (Mint's `:hostname`), so nothing resolves the
      name again between the check and the connect (DNS rebinding);
    * one connection per request, closed after it: no pool to grow with the
      number of hosts a crawl visits;
    * the body is bounded while it streams (`max_bytes:`; cut with
      `truncate: true`, else `{:too_large, seen}` as the body), and every
      wait ends by the call's deadline.

  Redirects, retries and robots.txt are `Fetch`'s: this module makes one
  request and answers `{:ok, %Req.Response{}}`, `{:error, exception}` for a
  transport failure, or `{:refused, reason}` (`:blocked_host`, `:nxdomain`)
  for a host it may not or cannot connect to.
  """

  alias PhoenixKit.Utils.PublicAddress

  @connect_timeout 10_000

  @doc false
  @spec get(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()} | {:refused, atom()}
  def get(url, headers, opts) do
    uri = URI.parse(url)

    with {:ok, ip} <- resolve_within(uri.host, opts),
         {:ok, conn} <- connect(uri, ip, opts) do
      request(conn, uri, [{"host", host_header(uri)} | headers], opts)
    end
  end

  # The Host header from the URL as written: an IPv6 literal in brackets
  # (Mint would join the bare address and the port), the port only when it
  # is not the scheme's.
  defp host_header(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    default? = (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    if default?, do: host, else: "#{host}:#{port}"
  end

  # The lookup has no deadline of its own: it runs in a task the call
  # abandons when its deadline comes.
  defp resolve_within(host, opts) do
    task = Task.async(fn -> resolve(host, opts[:allow_internal] == true) end)

    case Task.yield(task, max(remaining(opts), 1)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, %Mint.TransportError{reason: :timeout}}
    end
  end

  # ── address ──────────────────────────────────────────────────────────

  @doc false
  # The address to connect to: only a host whose every address is public,
  # or with `allow_internal?` any address it has.
  @spec resolve(String.t() | nil, boolean()) :: {:ok, :inet.ip_address()} | {:refused, atom()}
  def resolve(host, _allow_internal?) when host in [nil, ""], do: {:refused, :nxdomain}

  def resolve(host, false) do
    case PublicAddress.resolve_public(host) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:refused, reason}
    end
  end

  def resolve(host, true) do
    charlist = host |> String.trim_leading("[") |> String.trim_trailing("]") |> to_charlist()

    case :inet.parse_strict_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        Enum.find_value([:inet, :inet6], {:refused, :nxdomain}, &address(charlist, &1))
    end
  end

  defp address(charlist, family) do
    case :inet.getaddr(charlist, family) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> nil
    end
  end

  # ── the request ──────────────────────────────────────────────────────

  defp connect(%URI{scheme: scheme, host: host, port: port}, ip, opts) do
    scheme = if scheme == "https", do: :https, else: :http
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")
    timeout = opts |> remaining() |> min(@connect_timeout) |> max(1)

    case Mint.HTTP.connect(scheme, ip, port,
           hostname: host,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, error}
    end
  end

  defp request(conn, uri, headers, opts) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    path = if uri.query, do: path <> "?" <> uri.query, else: path

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, ref} ->
        state = %{status: nil, headers: [], body: [], bytes: 0, done?: false}
        receive_loop(conn, ref, state, opts)

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, error}
    end
  end

  defp receive_loop(conn, ref, state, opts) do
    timeout = min(opts[:timeout] || 15_000, remaining(opts))

    if timeout <= 0 do
      finish(conn, {:error, %Mint.TransportError{reason: :timeout}})
    else
      conn |> Mint.HTTP.recv(0, timeout) |> received(ref, state, opts)
    end
  end

  defp received({:ok, conn, responses}, ref, state, opts) do
    case handle(responses, ref, state, opts) do
      {:cont, state} -> receive_loop(conn, ref, state, opts)
      {:done, state} -> finish(conn, {:ok, response(state)})
    end
  end

  defp received({:error, conn, error, _responses}, _ref, _state, _opts),
    do: finish(conn, {:error, error})

  @doc false
  # One batch of Mint responses folded into the response being read.
  def handle([], _ref, state, _opts), do: {:cont, state}

  def handle([{:status, ref, status} | rest], ref, state, opts),
    do: handle(rest, ref, %{state | status: status}, opts)

  # An interim response (100 Continue, 103 Early Hints): the final status
  # follows on the same request.
  def handle([{:headers, ref, _headers} | rest], ref, %{status: status} = state, opts)
      when status in 100..199,
      do: handle(rest, ref, %{state | status: nil}, opts)

  def handle([{:headers, ref, headers} | rest], ref, %{bytes: 0, body: []} = state, opts),
    do: handle(rest, ref, %{state | headers: state.headers ++ headers}, opts)

  # Trailers carry nothing wanted.
  def handle([{:headers, ref, _trailers} | rest], ref, state, opts),
    do: handle(rest, ref, state, opts)

  def handle([{:data, ref, data} | rest], ref, state, opts) do
    max = opts[:max_bytes]
    seen = state.bytes + byte_size(data)

    cond do
      seen <= max ->
        handle(rest, ref, %{state | body: [state.body, data], bytes: seen}, opts)

      opts[:truncate] == true ->
        keep = binary_part(data, 0, max - state.bytes)
        {:done, %{state | body: [state.body, keep], bytes: max}}

      true ->
        {:done, %{state | body: {:too_large, seen}}}
    end
  end

  # A `:done` before any final status ends an interim response (older Mint
  # versions send one): the final response follows.
  def handle([{:done, ref} | rest], ref, %{status: nil} = state, opts),
    do: handle(rest, ref, state, opts)

  def handle([{:done, ref} | _rest], ref, state, _opts), do: {:done, state}
  def handle([_other | rest], ref, state, opts), do: handle(rest, ref, state, opts)

  defp response(%{status: status, headers: headers, body: body}) do
    body = if is_list(body), do: IO.iodata_to_binary(body), else: body

    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
    Req.Response.new(status: status, headers: headers, body: body)
  end

  defp finish(conn, result) do
    Mint.HTTP.close(conn)
    result
  end

  defp remaining(opts) do
    case opts[:deadline_at] do
      at when is_integer(at) -> max(at - System.monotonic_time(:millisecond), 0)
      _ -> opts[:timeout] || 15_000
    end
  end
end
