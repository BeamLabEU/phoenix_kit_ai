defmodule PhoenixKitAI.FetchTest do
  @moduledoc """
  `PhoenixKitAI.Fetch` against `Req.Test` stubs — no network: robots.txt,
  retries, the per-host pace, redirects, the size bound and the extraction.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.Fetch
  alias PhoenixKitAI.Fetch.{Extract, HostState, Robots}

  @page """
  <!doctype html>
  <html lang="et">
  <head>
    <title>Saal A — Example</title>
    <meta name="description" content="A hall for 40 &amp; more">
    <meta property="og:site_name" content="Example">
    <link rel="canonical" href="https://example.test/saal-a">
    <style>body { color: red }</style>
    <script>var nav = "<nav>not a tag</nav>";</script>
  </head>
  <body>
    <header><a href="/">Home</a> <a href="/halls">Halls</a></header>
    <nav><ul><li><a href="/a">A</a></li><li><a href="/b">B</a></li></ul></nav>
    <div class="cookie-banner">We use cookies. <button>OK</button></div>
    <main>
      <h1>Saal A</h1>
      <p>A bright hall with room for forty people, a projector and a small kitchen.</p>
      <ul><li><p>Projector</p></li><li>Kitchen</li></ul>
      <p>Price: 50&nbsp;€ per hour &mdash; weekends 70&#160;€.</p>
      <div class="share"><a href="/fb">Facebook</a> <a href="/x">X</a></div>
    </main>
    <aside>Other halls nearby</aside>
    <footer>© Example 2026 · <a href="/privacy">Privacy</a></footer>
  </body>
  </html>
  """

  setup do
    case Process.whereis(HostState) do
      nil -> start_supervised!(HostState)
      _ -> :ok
    end

    HostState.clear()
    on_exit(&HostState.clear/0)
    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        req_options: [plug: {Req.Test, __MODULE__}],
        allow_internal: true,
        rate_limit_ms: 0,
        base_delay_ms: 0
      ],
      extra
    )
  end

  # Routes by path: robots.txt answers `robots`, everything else `page`.
  defp stub(robots, page) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:hit, conn.request_path, Plug.Conn.get_req_header(conn, "user-agent")})

      case conn.request_path do
        "/robots.txt" -> robots.(conn)
        _ -> page.(conn)
      end
    end)
  end

  defp html(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, body)
  end

  defp text(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end

  describe "fetch/2" do
    test "returns the main content as clean text, with the head's metadata" do
      stub(&text(&1, "", 404), &html(&1, @page))

      assert {:ok, page} = Fetch.fetch("https://example.test/saal-a", opts())

      assert page.title == "Saal A — Example"
      assert page.description == "A hall for 40 & more"
      assert page.lang == "et"
      assert page.canonical == "https://example.test/saal-a"
      assert page.site_name == "Example"
      assert page.status == 200
      assert page.content_type == "text/html"
      assert page.final_url == "https://example.test/saal-a"
      assert page.main_content?
      assert page.attempts == 1
      assert page.bytes == byte_size(@page)
      refute Map.has_key?(page, :html)

      assert page.text ==
               """
               # Saal A

               A bright hall with room for forty people, a projector and a small kitchen.

               - Projector

               - Kitchen

               Price: 50 € per hour — weekends 70 €.\
               """

      for gone <- [
            "Home",
            "Halls",
            "cookies",
            "Other halls",
            "Privacy",
            "Facebook",
            "color",
            "nav"
          ],
          do: refute(page.text =~ gone, "#{gone} should be gone")

      assert_received {:hit, "/robots.txt", [ua]}
      assert ua =~ "PhoenixKitAI/"
    end

    test "robots.txt: a disallowed path is not requested, and the rules are cached per host" do
      robots = """
      User-agent: *
      Disallow: /private
      Allow: /private/open$
      """

      stub(&text(&1, robots), &html(&1, "<p>#{&1.request_path}</p>"))

      assert {:error, {:disallowed_by_robots, "https://example.test/private/x"}} =
               Fetch.fetch("https://example.test/private/x", opts())

      assert {:ok, %{text: "/private/open"}} =
               Fetch.fetch("https://example.test/private/open", opts())

      assert {:ok, _} = Fetch.fetch("https://example.test/public", opts())

      hits = collect_hits()
      assert Enum.count(hits, &(&1 == "/robots.txt")) == 1
      refute "/private/x" in hits
      assert Fetch.allowed?("https://example.test/private/y", opts()) == false
    end

    test "robots.txt that cannot be read disallows, unless told otherwise; robots: false skips it" do
      stub(&text(&1, "oops", 503), &html(&1, "<p>ok</p>"))

      assert {:error, {:disallowed_by_robots, _}} = Fetch.fetch("https://down.test/a", opts())

      HostState.clear()

      assert {:ok, %{text: "ok"}} =
               Fetch.fetch("https://down.test/a", opts(robots_unreachable: :allow))

      HostState.clear()
      assert {:ok, _} = Fetch.fetch("https://down.test/b", opts(robots: false))
      refute "/robots.txt" in (collect_hits() |> Enum.drop(2))
    end

    test "retries a 503 and a 429 with backoff, then succeeds" do
      counter = :counters.new(1, [])

      stub(&text(&1, "", 404), fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> text(conn, "busy", 503)
          2 -> conn |> Plug.Conn.put_resp_header("retry-after", "0") |> text("slow down", 429)
          _ -> html(conn, "<p>third time</p>")
        end
      end)

      assert {:ok, %{text: "third time", attempts: 3}} =
               Fetch.fetch("https://flaky.test/p", opts(max_attempts: 3))
    end

    test "gives up after max_attempts and says why" do
      stub(&text(&1, "", 404), &text(&1, "busy", 503))

      assert {:error, {:http_status, 503}} =
               Fetch.fetch("https://flaky.test/p", opts(max_attempts: 2))

      stub(&text(&1, "", 404), &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:fetch_failed, :econnrefused}} =
               Fetch.fetch("https://flaky.test/p", opts(max_attempts: 2))
    end

    test "requests to one host start at least rate_limit_ms apart" do
      stub(&text(&1, "", 404), &html(&1, "<p>x</p>"))
      started = System.monotonic_time(:millisecond)

      for n <- 1..3, do: {:ok, _} = Fetch.fetch("https://slow.test/#{n}", opts(rate_limit_ms: 60))

      # robots.txt + 3 pages = 4 slots, 3 gaps of 60 ms.
      assert System.monotonic_time(:millisecond) - started >= 180
    end

    test "Crawl-delay raises the pace" do
      stub(&text(&1, "User-agent: *\nCrawl-delay: 0.1\n"), &html(&1, "<p>x</p>"))
      {:ok, _} = Fetch.fetch("https://delay.test/1", opts())
      started = System.monotonic_time(:millisecond)
      {:ok, _} = Fetch.fetch("https://delay.test/2", opts())
      {:ok, _} = Fetch.fetch("https://delay.test/3", opts())
      assert System.monotonic_time(:millisecond) - started >= 100
    end

    test "follows redirects (checking each hop) up to max_redirects" do
      stub(&text(&1, "", 404), fn conn ->
        case conn.request_path do
          "/old" -> conn |> Plug.Conn.put_resp_header("location", "/new") |> text("", 301)
          "/loop" -> conn |> Plug.Conn.put_resp_header("location", "/loop") |> text("", 302)
          _ -> html(conn, "<p>new</p>")
        end
      end)

      assert {:ok, %{text: "new", final_url: "https://r.test/new", url: "https://r.test/old"}} =
               Fetch.fetch("https://r.test/old", opts())

      assert {:error, :too_many_redirects} =
               Fetch.fetch("https://r.test/loop", opts(max_redirects: 2))
    end

    test "an internal host is refused unless allowed; only http(s)" do
      assert {:error, {:unsafe_url, _}} =
               Fetch.fetch("http://127.0.0.1/x", opts(allow_internal: false))

      assert {:error, {:unsafe_url, _}} = Fetch.fetch("ftp://example.test/x", opts())
      assert {:error, {:unsafe_url, _}} = Fetch.fetch("not a url", opts())
    end

    test "a body over max_bytes is refused; text/plain is kept; other types are not text" do
      stub(&text(&1, "", 404), fn conn ->
        case conn.request_path do
          "/big" ->
            html(conn, String.duplicate("a", 2_000))

          "/plain" ->
            text(conn, "  just text \n")

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, "png")
        end
      end)

      assert {:error, {:too_large, 1_000}} =
               Fetch.fetch("https://t.test/big", opts(max_bytes: 1_000))

      assert {:ok, %{text: "just text", content_type: "text/plain"}} =
               Fetch.fetch("https://t.test/plain", opts())

      assert {:error, {:unsupported_content_type, "image/png"}} =
               Fetch.fetch("https://t.test/img", opts())
    end

    test "keep_html: true keeps the page" do
      stub(&text(&1, "", 404), &html(&1, "<p>x</p>"))
      assert {:ok, %{html: "<p>x</p>"}} = Fetch.fetch("https://k.test/", opts(keep_html: true))
    end
  end

  describe "Robots" do
    test "the longest matching rule wins, Allow on a tie; wildcards and $" do
      rules =
        Robots.parse(
          """
          # comment
          User-agent: *
          Disallow: /shop
          Allow: /shop/public
          Disallow: /*.pdf$
          Disallow:
          """,
          "PhoenixKitAI"
        )

      refute Robots.allowed?(rules, "/shop/cart")
      assert Robots.allowed?(rules, "/shop/public/item")
      refute Robots.allowed?(rules, "/files/a.pdf")
      assert Robots.allowed?(rules, "/files/a.pdf?x=1")
      assert Robots.allowed?(rules, "/")
    end

    test "our own group wins over *, and groups naming us are merged" do
      rules =
        Robots.parse(
          """
          User-agent: *
          Disallow: /

          User-agent: OtherBot
          User-agent: phoenixkitai
          Disallow: /admin

          User-agent: PhoenixKitAI
          Crawl-delay: 2
          """,
          "PhoenixKitAI"
        )

      assert Robots.allowed?(rules, "/halls")
      refute Robots.allowed?(rules, "/admin/x")
      assert rules.crawl_delay == 2.0
    end
  end

  describe "fetch/2: robots.txt reading, encodings, attempts" do
    defp routes(table) do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test, {:hit, conn.request_path, Plug.Conn.get_req_header(conn, "user-agent")})
        Map.get(table, conn.request_path, &text(&1, "", 404)).(conn)
      end)
    end

    defp moved(conn, to), do: conn |> Plug.Conn.put_resp_header("location", to) |> text("", 302)

    test "robots.txt behind a chain of redirects is read once, not checked against itself" do
      routes(%{
        "/robots.txt" => &moved(&1, "/rules"),
        "/rules" => &moved(&1, "/rules-v2"),
        "/rules-v2" => &text(&1, "User-agent: *\nDisallow: /private\n"),
        "/open" => &html(&1, "<p>open</p>")
      })

      assert {:error, {:disallowed_by_robots, _}} =
               Fetch.fetch("https://chain.test/private", opts())

      assert {:ok, %{text: "open"}} = Fetch.fetch("https://chain.test/open", opts())
      assert Enum.count(collect_hits(), &(&1 == "/robots.txt")) == 1
    end

    test "a robots.txt over 512 000 bytes: its first 512 000 bytes count" do
      big = "User-agent: *\nDisallow: /private\n" <> String.duplicate("# padding\n", 60_000)

      routes(%{"/robots.txt" => &text(&1, big), "/open" => &html(&1, "<p>open</p>")})

      assert {:ok, %{text: "open"}} = Fetch.fetch("https://big.test/open", opts())

      assert {:error, {:disallowed_by_robots, _}} =
               Fetch.fetch("https://big.test/private", opts())
    end

    test "a cut robots.txt loses its cut line, not the rule's meaning" do
      head = "User-agent: *\nDisallow: /private\n"
      rule = "Allow: /private/public\n"
      # Byte 512 000 falls inside the Allow line, just after `/private`.
      pad = 512_000 - byte_size(head) - byte_size("Allow: /private")
      padding = String.duplicate("#", pad - 1) <> "\n"
      body = head <> padding <> rule <> "Disallow: /tail\n"

      routes(%{"/robots.txt" => &text(&1, body), "/private" => &html(&1, "<p>p</p>")})

      assert {:error, {:disallowed_by_robots, _}} =
               Fetch.fetch("https://cut.test/private", opts())
    end

    test "a robots.txt of exactly 512 000 bytes is read whole" do
      head = "User-agent: *\n"
      last = "Disallow: /x #"
      body = head <> last <> String.duplicate("a", 512_000 - byte_size(head) - byte_size(last))
      assert byte_size(body) == 512_000

      routes(%{"/robots.txt" => &text(&1, body), "/x" => &html(&1, "<p>x</p>")})
      assert {:error, {:disallowed_by_robots, _}} = Fetch.fetch("https://exact.test/x", opts())
    end

    test "the robots cache is per product token; an unreadable file per call's policy" do
      routes(%{
        "/robots.txt" => &text(&1, "User-agent: BotA\nDisallow: /\n"),
        "/page" => &html(&1, "<p>page</p>")
      })

      assert {:error, {:disallowed_by_robots, _}} =
               Fetch.fetch("https://agents.test/page", opts(user_agent: "BotA/1.0"))

      assert {:ok, _} = Fetch.fetch("https://agents.test/page", opts(user_agent: "BotB/1.0"))

      routes(%{"/robots.txt" => &text(&1, "down", 503), "/page" => &html(&1, "<p>page</p>")})

      assert {:error, {:disallowed_by_robots, _}} = Fetch.fetch("https://down2.test/page", opts())

      # Cached as unreadable, not as the first caller's verdict.
      assert {:ok, _} =
               Fetch.fetch("https://down2.test/page", opts(robots_unreachable: :allow))
    end

    test "an IPv6 literal keeps its brackets in the robots.txt URL" do
      test = self()

      routes(%{
        "/robots.txt" => fn conn ->
          send(test, {:robots_at, conn.host, conn.port})
          text(conn, "User-agent: *\nDisallow: /private\n")
        end,
        "/x" => &html(&1, "<p>x</p>")
      })

      assert {:ok, %{text: "x"}} = Fetch.fetch("http://[::1]:8080/x", opts())
      assert_received {:robots_at, host, 8080} when host in ["::1", "[::1]"]

      assert {:error, {:disallowed_by_robots, _}} =
               Fetch.fetch("http://[::1]:8080/private", opts())
    end

    test "a name that does not resolve is refused like an internal one" do
      assert {:error, {:unsafe_url, _}} =
               Fetch.fetch("https://no-such-host.invalid/x", opts(allow_internal: false))
    end

    test "a body sent compressed although none was asked for is refused" do
      routes(%{
        "/gz" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> html(:zlib.gzip("<p>zipped</p>"))
        end
      })

      assert {:error, {:unsupported_content_encoding, "gzip"}} =
               Fetch.fetch("https://gz.test/gz", opts(robots: false))

      routes(%{
        "/two" => fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([
            {"content-encoding", "identity"},
            {"content-encoding", "gzip"}
          ])
          |> html(:zlib.gzip("<p>zipped</p>"))
        end
      })

      assert {:error, {:unsupported_content_encoding, "gzip"}} =
               Fetch.fetch("https://gz.test/two", opts(robots: false))
    end

    test "attempts counts every request for the page, redirects included" do
      counter = :counters.new(1, [])

      routes(%{
        "/start" => fn conn ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: text(conn, "busy", 503),
            else: moved(conn, "/end")
        end,
        "/end" => &html(&1, "<p>end</p>")
      })

      assert {:ok, %{text: "end", attempts: 3}} =
               Fetch.fetch("https://count.test/start", opts(robots: false))
    end
  end

  describe "the pinned connection (no Req stub)" do
    # A one-shot HTTP server on 127.0.0.1: answers each connection with
    # `reply.(request)` (nil: never answers) and sends the request to the test.
    defp serve(reply) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      test = self()

      server =
        spawn_link(fn ->
          accept = fn accept ->
            case :gen_tcp.accept(listen, 5_000) do
              {:ok, socket} ->
                request = read_request(socket, "")
                send(test, {:request, request})

                case reply.(request) do
                  nil -> Process.sleep(1_000)
                  response -> :gen_tcp.send(socket, response)
                end

                :gen_tcp.close(socket)
                accept.(accept)

              {:error, _} ->
                :ok
            end
          end

          accept.(accept)
        end)

      on_exit(fn -> Process.exit(server, :kill) end)
      port
    end

    defp read_request(socket, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        acc
      else
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          {:error, _} -> acc
        end
      end
    end

    defp http(status, body, type \\ "text/html") do
      "HTTP/1.1 #{status} X\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
        body
    end

    defp pinned(extra \\ []),
      do:
        Keyword.merge(
          [allow_internal: true, robots: false, rate_limit_ms: 0, base_delay_ms: 0],
          extra
        )

    test "connects to the address it resolved, with the name as Host" do
      port = serve(fn _ -> http(200, "<p>pinned</p>") end)

      assert {:ok, %{text: "pinned", status: 200}} =
               Fetch.fetch("http://localhost:#{port}/page", pinned())

      assert_received {:request, request}
      assert request =~ "GET /page HTTP/1.1"
      assert request =~ ~r/\r\nhost: localhost(:#{port})?\r\n/i
    end

    test "an IPv6 literal goes to Host in brackets; a caller's deadline_at: nil is no deadline" do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          :inet6,
          active: false,
          reuseaddr: true,
          ip: {0, 0, 0, 0, 0, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        send(test, {:request, read_request(socket, "")})
        :gen_tcp.send(socket, http(200, "<p>six</p>"))
        :gen_tcp.close(socket)
      end)

      assert {:ok, %{text: "six"}} =
               Fetch.fetch("http://[::1]:#{port}/", pinned(deadline_at: nil))

      assert_received {:request, request}
      assert request =~ ~r/\r\nhost: \[::1\]:#{port}\r\n/i
    end

    test "a Req option plug: nil does not route around the pinned connection" do
      port = serve(fn _ -> http(200, "<p>pinned anyway</p>") end)

      assert {:ok, %{text: "pinned anyway"}} =
               Fetch.fetch("http://127.0.0.1:#{port}/", pinned(req_options: [plug: nil]))
    end

    test "an interim :done before the final status is not the end of the response" do
      state = %{status: nil, headers: [], body: [], bytes: 0, done?: false}
      ref = make_ref()

      assert {:cont, %{status: 200}} =
               PhoenixKitAI.Fetch.Pinned.handle(
                 [{:status, ref, 103}, {:headers, ref, []}, {:done, ref}, {:status, ref, 200}],
                 ref,
                 state,
                 max_bytes: 10
               )
    end

    test "resolution refuses an internal address unless allowed" do
      assert {:refused, :blocked_host} = PhoenixKitAI.Fetch.Pinned.resolve("localhost", false)
      assert {:refused, :blocked_host} = PhoenixKitAI.Fetch.Pinned.resolve("127.0.0.1", false)
      assert {:ok, {127, 0, 0, 1}} = PhoenixKitAI.Fetch.Pinned.resolve("127.0.0.1", true)
    end

    test "the body is bounded while it streams" do
      port = serve(fn _ -> http(200, String.duplicate("x", 10_000), "text/plain") end)

      assert {:error, {:too_large, 1_000}} =
               Fetch.fetch("http://127.0.0.1:#{port}/big", pinned(max_bytes: 1_000))
    end

    test "a deadline during robots.txt is not cached as an unreadable file" do
      calls = :counters.new(1, [])

      port =
        serve(fn request ->
          :counters.add(calls, 1, 1)

          cond do
            :counters.get(calls, 1) == 1 -> nil
            request =~ "GET /robots.txt" -> http(200, "User-agent: *\nDisallow:\n", "text/plain")
            true -> http(200, "<p>ok</p>")
          end
        end)

      url = "http://127.0.0.1:#{port}/a"
      assert {:error, :deadline} = Fetch.fetch(url, pinned(robots: true, deadline: 300))
      # Cached as unreadable, the default policy would now refuse it.
      assert {:ok, %{text: "ok"}} = Fetch.fetch(url, pinned(robots: true))
    end

    test "deadline: a server that never answers ends the call by then" do
      port = serve(fn _ -> nil end)

      {microseconds, result} =
        :timer.tc(fn ->
          Fetch.fetch("http://127.0.0.1:#{port}/slow", pinned(deadline: 300, max_attempts: 5))
        end)

      assert result == {:error, :deadline}
      assert microseconds < 3_000_000
    end
  end

  describe "deadline: and the defaults" do
    test "a wait for the host's next slot past the deadline is {:error, :deadline}" do
      stub(&text(&1, "", 404), &html(&1, "<p>ok</p>"))

      assert {:ok, _} = Fetch.fetch("https://pace.test/a", opts(rate_limit_ms: 5_000))

      {microseconds, result} =
        :timer.tc(fn ->
          Fetch.fetch("https://pace.test/b", opts(rate_limit_ms: 5_000, deadline: 500))
        end)

      assert result == {:error, :deadline}
      assert microseconds < 1_000_000
    end

    test "max_bytes defaults to 2 MB and deadline to 60 s" do
      assert Fetch.options([])[:max_bytes] == 2_000_000
      assert Fetch.options([])[:deadline] == 60_000
    end
  end

  describe "HostState" do
    test "prune/0 deletes expired rules and past slots, keeps the live ones" do
      HostState.put_robots({"https://old.test", "x"}, Robots.allow_all(), 0)
      HostState.put_robots({"https://live.test", "x"}, Robots.allow_all(), 60_000)
      assert HostState.reserve("old.test", 0) == 0
      assert HostState.reserve("busy.test", 60_000) == 0

      assert HostState.prune() == 2
      assert HostState.robots({"https://live.test", "x"}) == Robots.allow_all()
      # busy.test's next slot is still a minute away.
      assert HostState.reserve("busy.test", 0) > 0
    end
  end

  describe "Robots per RFC 9309" do
    test "a group applies only when its user-agent is our product token" do
      body = """
      User-agent: Kit
      Disallow: /

      User-agent: *
      Disallow: /private
      """

      # `Kit` is part of `PhoenixKitAI`, not its token.
      rules = Robots.parse(body, "PhoenixKitAI")
      assert Robots.allowed?(rules, "/halls")
      refute Robots.allowed?(rules, "/private")

      # A user-agent line's value is read as a token: `PhoenixKitAI/1.0` names us.
      versioned =
        Robots.parse("User-agent: PhoenixKitAI/1.0 (+x)\nDisallow: /a\n", "PhoenixKitAI")

      refute Robots.allowed?(versioned, "/a")
    end

    test "a Crawl-delay between User-agent lines does not split their group" do
      rules =
        Robots.parse(
          "User-agent: Other\nCrawl-delay: 1\nUser-agent: PhoenixKitAI\nDisallow: /private\n",
          "PhoenixKitAI"
        )

      refute Robots.allowed?(rules, "/private")

      assert Robots.parse(
               "User-agent: Other\nCrawl-delay: 1\nUser-agent: X\nDisallow: /p\n",
               "Other"
             )
             |> Robots.allowed?("/p") == false
    end

    test "lines other than the group's own (Sitemap) neither end a group nor count" do
      rules =
        Robots.parse(
          """
          User-agent: PhoenixKitAI
          Sitemap: https://example.test/sitemap.xml
          User-agent: OtherBot
          Disallow: /private
          """,
          "PhoenixKitAI"
        )

      refute Robots.allowed?(rules, "/private")
    end

    test "paths and rules compare percent-encoded; the longest rule in octets wins" do
      rules = Robots.parse("User-agent: *\nDisallow: /private\nDisallow: /café\n", "PhoenixKitAI")
      refute Robots.allowed?(rules, "/%70rivate")
      refute Robots.allowed?(rules, "/caf%C3%A9")
      refute Robots.allowed?(rules, "/caf%c3%a9/menu")
      assert Robots.allowed?(rules, "/cafe")

      # `/é` is three octets encoded, longer than `/*`.
      octets = Robots.parse("User-agent: *\nDisallow: /é\nAllow: /*\n", "PhoenixKitAI")
      refute Robots.allowed?(octets, "/%C3%A9")
    end

    test "/robots.txt is always allowed; a hostile wildcard rule matches in time" do
      assert Robots.allowed?(Robots.deny_all(), "/robots.txt")

      pattern = "/" <> String.duplicate("*a", 30) <> "*b"
      rules = Robots.parse("User-agent: *\nDisallow: #{pattern}\n", "PhoenixKitAI")
      path = "/" <> String.duplicate("a", 3_000)

      {microseconds, verdicts} =
        :timer.tc(fn -> {Robots.allowed?(rules, path), Robots.allowed?(rules, path <> "b")} end)

      assert verdicts == {true, false}
      assert microseconds < 2_000_000
    end
  end

  describe "Extract" do
    test "without main content marks, link rows and boilerplate classes are dropped" do
      html = """
      <body>
        <div id="menu"><a href="/1">One</a> <a href="/2">Two</a></div>
        <div class="article-body">
          <p>The text of the article, long enough to be the content of the page by any measure.</p>
          <p><a href="/a">Home</a> | <a href="/b">About</a> | <a href="/c">Contact</a></p>
          <p>Read <a href="/more">more about halls</a> in the guide that explains everything there is to know.</p>
        </div>
      </body>
      """

      %{text: text, main_content?: false} = Extract.extract(html)
      assert text =~ "The text of the article"
      assert text =~ "Read more about halls in the guide"
      refute text =~ "One"
      refute text =~ "Contact"
    end

    test "a hostile page is read in linear time (no regex retried from every opening tag)" do
      # Most of these took tens of seconds at these sizes with lazy
      # `<x>.*?</x>` regexes and a whole-tag regex; each is milliseconds now.
      hostile = [
        "<p>kept</p>" <> String.duplicate("<script>x", 20_000),
        "<p>kept</p>" <> String.duplicate("<!-->", 40_000),
        String.duplicate("<head>", 20_000) <> "<p>kept</p>",
        String.duplicate("<title>", 20_000) <> "<p>kept</p>",
        "<p>kept</p><a" <> String.duplicate(" ", 200_000) <> "!>",
        "<p>kept</p><a " <> String.duplicate("a", 200_000) <> "=\">",
        # Openers with no `>` at all, and one `>` after all of them.
        # 5 MiB with no `>` anywhere: minutes before the stray-`<` pass.
        "kept " <> String.duplicate("<script ", 655_360),
        "<p>kept</p>" <> String.duplicate("<html ", 100_000) <> ">"
      ]

      for html <- hostile do
        {microseconds, %{text: text}} = :timer.tc(fn -> Extract.extract(html) end)
        assert text =~ "kept"
        # Each took from 40 s to minutes before; seconds now, even on a
        # loaded box.
        assert microseconds < 20_000_000, "took #{div(microseconds, 1000)} ms"
      end
    end

    test "a < inside an attribute or in text is not taken for a stray one" do
      html = ~s(<body><div class="nav x<y">Menu row</div><p>a < b</p><p>Content kept</p></body>)
      %{text: text} = Extract.extract(html)
      refute text =~ "Menu"
      refute text =~ "nav"
      assert text =~ "Content kept"
    end

    test "comments, CDATA and raw-text elements are dropped, whatever their case" do
      html = """
      <body><!-- <p>comment</p> --><p>one</p><SCRIPT type="x">two</Script >
      <![CDATA[ three ]]><p>four</p><style>five</style><p>six</p><textarea>seven
      """

      assert Extract.extract(html).text == "one\n\nfour\n\nsix"
      assert Extract.extract("<head><title>T &amp; U</title></head><p>x</p>").title == "T & U"
    end

    test "main content marked by role=\"main\" ends at its own closing tag" do
      html = """
      <body>
        <div role="main"><div><p>The main text, long enough to be most of the page by far.</p></div></div>
        <p>Outside the main content.</p>
      </body>
      """

      assert %{text: text, main_content?: true} = Extract.extract(html)
      assert text =~ "The main text"
      refute text =~ "Outside"

      # An element left open inside it ends with it, as in a browser…
      unclosed =
        ~s(<body><div role="main"><article><p>Inside the article, the long main text.</p></div><p>Outside</p></body>)

      refute Extract.extract(unclosed).text =~ "Outside"

      # …while a same-name element nested in an open one only counts down.
      nested =
        ~s(<body><div role="main"><article><div>The first part of the text</div><p>The rest of the main text</p></article></div><p>Out</p></body>)

      # A closing tag closes what is open inside it too.
      misnested =
        ~s(<body><div role="main"><article><div>The inside, the main text of it all.</article></div><p>Outside</p></body>)

      refute Extract.extract(misnested).text =~ "Outside"

      assert %{text: text} = Extract.extract(nested)
      assert text =~ "The rest of the main text"
      refute text =~ "Out\n" or String.ends_with?(text, "Out")
    end

    test "entities, Latin-1 bytes and unclosed scripts" do
      assert Extract.decode_entities("&lt;b&gt; &#x41;&#66; &unknown; &#0;") ==
               "<b> AB &unknown; &#0;"

      %{text: text} = Extract.extract("<p>caf\xE9</p><script>never closed")
      assert text == "café"
    end
  end

  defp collect_hits(acc \\ []) do
    receive do
      {:hit, path, _ua} -> collect_hits([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
