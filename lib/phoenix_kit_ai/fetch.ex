defmodule PhoenixKitAI.Fetch do
  @moduledoc """
  Fetching pages for crawl-style input: robots.txt, retries with backoff, a
  per-host rate limit, and the page's main content as clean text — what a
  model should read, not the 98% of a page that is navigation.

      {:ok, page} = PhoenixKitAI.Fetch.fetch("https://example.com/hall/5")
      page.text        # main content, blocks separated by blank lines
      page.title       # og:title, else <title>
      page.final_url   # after redirects

  Optional: nothing else in the module calls it. It makes no AI call and
  writes no usage row; pair it with `PhoenixKitAI.ContentHashes` to skip
  pages whose text has not changed.

  ## What a fetch does

    1. **The URL is checked** like an image URL (`Providers.HTTP.host_class/2`):
       http(s) only, and a host that is or resolves to an internal address is
       refused (`{:error, {:unsafe_url, url}}`) unless `allow_internal: true`
       (or `config :phoenix_kit_ai, :fetch, allow_internal: true`). Every
       redirect hop is checked again; at most `max_redirects:`.
    2. **robots.txt** of the URL's origin is read (and cached on the node for
       `robots_ttl:` seconds) and matched for the `user_agent:`'s product
       token. A disallowed path is `{:error, {:disallowed_by_robots, url}}`
       and no request is made. A missing robots.txt (4xx) allows everything;
       one that cannot be read (5xx, 429, unreachable) disallows everything
       for a few minutes, as RFC 9309 asks — `robots_unreachable: :allow`
       turns that around. `robots: false` skips it (your own sites).
    3. **The host's rate limit**: requests to one host start at least
       `rate_limit_ms:` apart on this node (the robots.txt `Crawl-delay`
       raises it, up to `max_crawl_delay_ms:`). The caller sleeps for its slot.
    4. **Retries**: a transport error, a timeout, 408, 425, 429, 500, 502,
       503 or 504 is tried again up to `max_attempts:` in all, waiting
       `base_delay_ms × 2^(n-1)` (at most `max_delay_ms:`), or the
       `Retry-After` seconds when the server names them (capped the same).
    5. **The body** is read up to `max_bytes:`; past it the fetch is
       `{:error, {:too_large, max}}`. HTML is turned into text by
       `PhoenixKitAI.Fetch.Extract`; `text/plain` is kept as it is; anything
       else is `{:error, {:unsupported_content_type, type}}`.

  ## The result

      %{
        url: "https://…",          # as asked
        final_url: "https://…",    # after redirects
        status: 200,
        content_type: "text/html",
        text: "…",                 # main content
        title: "…" | nil,
        description: "…" | nil,
        lang: "et" | nil,
        canonical: "https://…" | nil,
        site_name: "…" | nil,
        main_content?: true,       # the page marked its main content and that was kept
        bytes: 211_000,            # body as received
        text_bytes: 4_300,
        attempts: 1,
        fetched_at: ~U[…],
        html: "…"                  # only with `keep_html: true`
      }

  ## Options

  Per call, over `config :phoenix_kit_ai, :fetch, [...]`, over the defaults:
  `user_agent:` (`"PhoenixKitAI/<version> (+https://github.com/BeamLabEU/phoenix_kit_ai)"`;
  robots.txt is matched on its first word), `robots:` (`true`),
  `robots_ttl:` (3 600 s), `robots_unreachable:` (`:deny`), `rate_limit_ms:`
  (1 000), `max_crawl_delay_ms:` (30 000), `max_attempts:` (3),
  `base_delay_ms:` (500), `max_delay_ms:` (10 000), `timeout:` (15 000 ms,
  receive; connect is at most 10 s), `max_bytes:` (5 000 000),
  `max_redirects:` (5), `allow_internal:` (`false`), `keep_html:` (`false`),
  `headers:` (extra request headers), `req_options:` (extra `Req` options;
  `config :phoenix_kit_ai, :req_options` is appended too — tests stub with
  `Req.Test` through it).

  ## Scope

  Per node: the robots cache and the rate limit live in
  `PhoenixKitAI.Fetch.HostState` (in `PhoenixKitAI.children/0`). Several
  nodes crawling one host each keep their own pace. Without that process a
  fetch reads robots.txt every time and waits for no slot (logged once).
  No JavaScript is run: a page that renders its text in the browser has
  little text here.
  """

  require Logger

  alias PhoenixKitAI.Fetch.{Extract, HostState, Robots}
  alias PhoenixKitAI.Providers.HTTP

  @version Mix.Project.config()[:version]

  @defaults [
    user_agent: "PhoenixKitAI/#{@version} (+https://github.com/BeamLabEU/phoenix_kit_ai)",
    robots: true,
    robots_ttl: 3_600,
    robots_unreachable: :deny,
    rate_limit_ms: 1_000,
    max_crawl_delay_ms: 30_000,
    max_attempts: 3,
    base_delay_ms: 500,
    max_delay_ms: 10_000,
    timeout: 15_000,
    max_bytes: 5_000_000,
    max_redirects: 5,
    allow_internal: false,
    keep_html: false,
    headers: [],
    req_options: []
  ]

  # How long an unreadable robots.txt keeps its verdict (RFC 9309 §2.4 lets a
  # crawler assume a full disallow while the server errs).
  @unreachable_ttl_ms 5 * 60_000
  @retry_statuses [408, 425, 429, 500, 502, 503, 504]
  @html_types ["text/html", "application/xhtml+xml"]

  @type page :: %{
          required(:url) => String.t(),
          required(:final_url) => String.t(),
          required(:status) => pos_integer(),
          required(:content_type) => String.t() | nil,
          required(:text) => String.t(),
          required(:title) => String.t() | nil,
          required(:description) => String.t() | nil,
          required(:lang) => String.t() | nil,
          required(:canonical) => String.t() | nil,
          required(:site_name) => String.t() | nil,
          required(:main_content?) => boolean(),
          required(:bytes) => non_neg_integer(),
          required(:text_bytes) => non_neg_integer(),
          required(:attempts) => pos_integer(),
          required(:fetched_at) => DateTime.t(),
          optional(:html) => String.t()
        }

  @doc "Fetches `url` and returns its main content (see the moduledoc)."
  @spec fetch(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    opts = options(opts)
    warn_without_state()

    with {:ok, uri} <- check_url(url, opts),
         :ok <- check_robots(uri, opts),
         {:ok, response, final_url, attempts} <- get(url, opts, opts[:max_redirects]) do
      to_page(url, final_url, response, attempts, opts)
    end
  end

  @doc """
  Whether robots.txt lets `user_agent:` fetch `url` (reads and caches it like
  `fetch/2`). `{:error, reason}` for a URL that may not be fetched at all.
  """
  @spec allowed?(String.t(), keyword()) :: boolean() | {:error, term()}
  def allowed?(url, opts \\ []) do
    opts = options(opts)

    with {:ok, uri} <- check_url(url, opts) do
      robots(uri, opts) |> Robots.allowed?(path(uri))
    end
  end

  @doc "The options a call runs with: the call's over `config :phoenix_kit_ai, :fetch` over the defaults."
  @spec options(keyword()) :: keyword()
  def options(opts) do
    config = Application.get_env(:phoenix_kit_ai, :fetch, [])
    config = if Keyword.keyword?(config), do: config, else: []

    @defaults |> Keyword.merge(config) |> Keyword.merge(opts)
  end

  # ── checks ───────────────────────────────────────────────────────────

  defp check_url(url, opts) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if opts[:allow_internal] == true or HTTP.host_class(host, timeout: 5_000) != :internal,
          do: {:ok, uri},
          else: {:error, {:unsafe_url, url}}

      _ ->
        {:error, {:unsafe_url, url}}
    end
  end

  defp check_robots(uri, opts) do
    if opts[:robots] == false or Robots.allowed?(robots(uri, opts), path(uri)),
      do: :ok,
      else: {:error, {:disallowed_by_robots, URI.to_string(uri)}}
  end

  defp robots(uri, opts) do
    origin = origin(uri)

    case HostState.robots(origin) do
      nil ->
        {rules, ttl} = read_robots(origin, opts)
        HostState.put_robots(origin, rules, ttl)
        rules

      rules ->
        rules
    end
  end

  defp read_robots(origin, opts) do
    # robots.txt is fetched once, without retries: its absence or failure has
    # a meaning of its own.
    robots_opts = Keyword.merge(opts, max_attempts: 1, max_bytes: 512_000)

    case get(origin <> "/robots.txt", robots_opts, opts[:max_redirects]) do
      {:ok, %{status: status, body: body}, _final, _attempts} when status in 200..299 ->
        {Robots.parse(to_string(body), agent_token(opts[:user_agent])), opts[:robots_ttl] * 1_000}

      {:ok, %{status: status}, _final, _attempts} when status in 400..499 and status != 429 ->
        {Robots.allow_all(), opts[:robots_ttl] * 1_000}

      _unreachable ->
        rules =
          if opts[:robots_unreachable] == :allow, do: Robots.allow_all(), else: Robots.deny_all()

        {rules, @unreachable_ttl_ms}
    end
  end

  defp agent_token(user_agent) do
    user_agent |> to_string() |> String.split(["/", " "], parts: 2) |> hd()
  end

  # ── the request ──────────────────────────────────────────────────────

  defp get(url, opts, redirects_left) do
    case attempt(url, opts, 1) do
      {:ok, %{status: status} = response, attempts} when status in [301, 302, 303, 307, 308] ->
        redirect(url, response, opts, redirects_left, attempts)

      {:ok, response, attempts} ->
        {:ok, response, url, attempts}

      {:error, _} = error ->
        error
    end
  end

  defp redirect(_url, _response, _opts, 0, _attempts), do: {:error, :too_many_redirects}

  defp redirect(url, response, opts, redirects_left, _attempts) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        next = url |> URI.merge(location) |> URI.to_string()

        with {:ok, uri} <- check_url(next, opts),
             :ok <- check_hop_robots(url, uri, opts),
             do: get(next, opts, redirects_left - 1)

      [] ->
        {:error, {:redirect_without_location, url}}
    end
  end

  # robots.txt itself is fetched whatever the rules say.
  defp check_hop_robots(url, uri, opts),
    do: if(robots_txt?(url), do: :ok, else: check_robots(uri, opts))

  defp robots_txt?(url), do: String.ends_with?(URI.parse(url).path || "", "/robots.txt")

  defp attempt(url, opts, n) do
    wait_for_slot(url, opts)
    max_attempts = opts[:max_attempts]

    case request(url, opts) do
      {:ok, %Req.Response{status: status} = response}
      when status in @retry_statuses and n < max_attempts ->
        backoff(n, retry_after(response), opts)
        attempt(url, opts, n + 1)

      {:ok, %Req.Response{body: {:too_large, _seen}}} ->
        {:error, {:too_large, opts[:max_bytes]}}

      {:ok, response} ->
        {:ok, response, n}

      {:error, _reason} when n < max_attempts ->
        backoff(n, nil, opts)
        attempt(url, opts, n + 1)

      {:error, reason} ->
        {:error, {:fetch_failed, transport_tag(reason)}}
    end
  end

  defp request(url, opts) do
    timeout = opts[:timeout]

    req =
      [
        url: url,
        method: :get,
        headers:
          [{"user-agent", opts[:user_agent]}, {"accept", "text/html,text/plain;q=0.9,*/*;q=0.1"}] ++
            List.wrap(opts[:headers]),
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: timeout,
        connect_options: [timeout: min(timeout, 10_000)],
        into: bounded_collector(opts[:max_bytes])
      ] ++ List.wrap(opts[:req_options]) ++ Application.get_env(:phoenix_kit_ai, :req_options, [])

    Req.request(req)
  rescue
    error -> {:error, error}
  end

  defp wait_for_slot(url, opts) do
    host = URI.parse(url).host || ""
    interval = interval(url, opts)

    case HostState.reserve(host, interval) do
      0 -> :ok
      wait -> Process.sleep(wait)
    end
  end

  # The host's own Crawl-delay raises the pace, never lowers it; read from
  # the cache only, so asking for robots.txt never waits for robots.txt.
  defp interval(url, opts) do
    base = max(opts[:rate_limit_ms], 0)

    delay =
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
          case HostState.robots(origin(uri)) do
            %{crawl_delay: seconds} when is_number(seconds) ->
              min(round(seconds * 1_000), opts[:max_crawl_delay_ms])

            _ ->
              0
          end

        _ ->
          0
      end

    max(base, delay)
  end

  defp backoff(n, retry_after, opts) do
    max_delay = opts[:max_delay_ms]

    delay =
      case retry_after do
        seconds when is_integer(seconds) -> min(seconds * 1_000, max_delay)
        nil -> min(opts[:base_delay_ms] * Integer.pow(2, n - 1), max_delay)
      end

    if delay > 0, do: Process.sleep(delay)
  end

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds
    else
      _ -> nil
    end
  end

  defp transport_tag(%{__exception__: true, reason: reason}) when is_atom(reason), do: reason
  defp transport_tag(%{__exception__: true, __struct__: module}), do: module
  defp transport_tag(reason) when is_atom(reason), do: reason
  defp transport_tag(_reason), do: :unknown

  # Streams the body, halting once it outgrows `max`.
  defp bounded_collector(max) do
    fn {:data, chunk}, {req, resp} ->
      {verdict, body} = collect(resp.body, chunk, max)
      {verdict, {req, %{resp | body: body}}}
    end
  end

  defp collect({:too_large, _} = marker, _chunk, _max), do: {:halt, marker}

  defp collect(body, chunk, max) do
    body = if is_binary(body), do: body, else: ""
    seen = byte_size(body) + byte_size(chunk)
    if seen > max, do: {:halt, {:too_large, seen}}, else: {:cont, body <> chunk}
  end

  # ── the page ─────────────────────────────────────────────────────────

  defp to_page(url, final_url, %Req.Response{status: status} = response, attempts, opts) do
    body = if is_binary(response.body), do: response.body, else: ""
    type = content_type(response)

    cond do
      status not in 200..299 ->
        {:error, {:http_status, status}}

      type in @html_types or (type == nil and html?(body)) ->
        extracted = Extract.extract(body)
        {:ok, page(url, final_url, status, type, body, extracted, attempts, opts)}

      type == "text/plain" ->
        text = body |> plain_text() |> String.trim()

        extracted = %{
          text: text,
          title: nil,
          description: nil,
          lang: nil,
          canonical: nil,
          site_name: nil,
          main_content?: false
        }

        {:ok, page(url, final_url, status, type, body, extracted, attempts, opts)}

      true ->
        {:error, {:unsupported_content_type, type}}
    end
  end

  defp page(url, final_url, status, type, body, extracted, attempts, opts) do
    page =
      Map.merge(extracted, %{
        url: url,
        final_url: final_url,
        status: status,
        content_type: type,
        bytes: byte_size(body),
        text_bytes: byte_size(extracted.text),
        attempts: attempts,
        fetched_at: DateTime.utc_now()
      })

    if opts[:keep_html] == true, do: Map.put(page, :html, body), else: page
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp html?(body),
    do:
      Regex.match?(
        ~r/\A\s*(<!doctype html|<html)/i,
        binary_part(body, 0, min(byte_size(body), 512))
      )

  defp plain_text(body) do
    if String.valid?(body), do: body, else: String.replace_invalid(body)
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    default? = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    "#{scheme}://#{host}" <> if(default? or is_nil(port), do: "", else: ":#{port}")
  end

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  defp warn_without_state do
    if not HostState.running?() and :persistent_term.get({__MODULE__, :warned}, false) == false do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "[PhoenixKitAI.Fetch] PhoenixKitAI.Fetch.HostState is not running: robots.txt is read " <>
          "on every fetch and no per-host rate limit applies (start PhoenixKitAI.children/0)"
      )
    end
  end
end
