defmodule PhoenixKitAI.Fetch.Robots do
  @moduledoc """
  robots.txt, parsed and matched the way RFC 9309 says: the groups whose
  user-agent names our product token (compared case-insensitively, the
  line's value read up to its first character that cannot be in a token, so
  `PhoenixKitAI/1.0` names `phoenixkitai`), else the `*` groups; in them the
  rule matching the most octets wins (`*` matches any run of characters, a
  trailing `$` anchors the end), an `Allow` winning a tie; no matching rule
  allows, and `/robots.txt` itself is always allowed. Paths and rules are
  compared percent-encoded: a non-ASCII octet is encoded, an encoded
  unreserved character decoded. Lines other than `User-agent`, `Allow`,
  `Disallow` and `Crawl-delay` (a `Sitemap`, say) are ignored and do not
  end a group. `Crawl-delay` (seconds), which the RFC leaves out, is read
  from the same groups. A rule longer than 4 096 octets is ignored.
  """

  @rule_max 4_096
  @keys ~w(user-agent allow disallow crawl-delay)

  @type rule :: {:allow | :disallow, String.t()}
  @type t :: %{rules: [rule()], crawl_delay: number() | nil}

  @doc "Everything allowed: a robots.txt that is missing (4xx) or empty."
  @spec allow_all() :: t()
  def allow_all, do: %{rules: [], crawl_delay: nil}

  @doc "Everything disallowed: a robots.txt that could not be read (5xx, unreachable)."
  @spec deny_all() :: t()
  def deny_all, do: %{rules: [{:disallow, "/"}], crawl_delay: nil}

  @doc "The rules of `body` that apply to `agent` (our product token, e.g. `\"PhoenixKitAI\"`)."
  @spec parse(String.t(), String.t()) :: t()
  def parse(body, agent) when is_binary(body) do
    agent = agent |> to_string() |> token()
    groups = groups(body)

    ours = Enum.filter(groups, fn {agents, _lines} -> agent != "" and agent in agents end)

    # Every group naming us counts (a file may split one); with none, every
    # `*` group.
    lines =
      case ours do
        [] ->
          groups
          |> Enum.filter(fn {agents, _} -> "*" in agents end)
          |> Enum.flat_map(&elem(&1, 1))

        _ ->
          Enum.flat_map(ours, &elem(&1, 1))
      end

    # An empty Disallow allows everything: it is no rule.
    rules =
      for {key, value} <- lines,
          key in ["allow", "disallow"],
          value != "",
          byte_size(value) <= @rule_max do
        {if(key == "allow", do: :allow, else: :disallow), normalize(value)}
      end

    delay =
      Enum.find_value(lines, fn
        {"crawl-delay", value} -> parse_delay(value)
        _ -> nil
      end)

    %{rules: rules, crawl_delay: delay}
  end

  @doc "Whether `path` (with its query string) may be fetched under `robots`."
  @spec allowed?(t(), String.t()) :: boolean()
  def allowed?(%{rules: rules}, path) do
    path = if path in [nil, ""], do: "/", else: normalize(path)

    if robots_txt?(path) do
      true
    else
      rules
      |> Enum.filter(fn {_kind, pattern} -> matches?(pattern, path) end)
      |> Enum.max_by(fn {kind, pattern} -> {byte_size(pattern), kind == :allow} end, fn -> nil end)
      |> case do
        nil -> true
        {kind, _pattern} -> kind == :allow
      end
    end
  end

  defp robots_txt?(path), do: path == "/robots.txt" or String.starts_with?(path, "/robots.txt?")

  # ── parsing ──────────────────────────────────────────────────────────

  # A group is one or more User-agent lines followed by its rules; a
  # User-agent line after a rule starts the next group.
  defp groups(body) do
    body
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({[], nil}, fn
      {"user-agent", agent}, {groups, {agents, lines, :agents}} ->
        {groups, {[token(agent) | agents], lines, :agents}}

      {"user-agent", agent}, {groups, current} ->
        {close(groups, current), {[token(agent)], [], :agents}}

      _line, {groups, nil} ->
        # A rule before any User-agent belongs to no group.
        {groups, nil}

      # Crawl-delay is no rule of RFC 9309's: it does not end the run of
      # User-agent lines that starts a group.
      {"crawl-delay", _} = line, {groups, {agents, lines, mode}} ->
        {groups, {agents, [line | lines], mode}}

      line, {groups, {agents, lines, _}} ->
        {groups, {agents, [line | lines], :rules}}
    end)
    |> then(fn {groups, current} -> close(groups, current) end)
    |> Enum.reverse()
  end

  defp close(groups, nil), do: groups
  defp close(groups, {agents, lines, _}), do: [{agents, Enum.reverse(lines)} | groups]

  defp line(raw) do
    raw = raw |> String.split("#", parts: 2) |> hd() |> String.trim()

    with [key, value] <- String.split(raw, ":", parts: 2),
         key = key |> String.trim() |> String.downcase(),
         true <- key in @keys do
      {key, String.trim(value)}
    else
      _ -> nil
    end
  end

  # A user-agent value as a product token: `*`, else its leading run of
  # letters, `_` and `-`, lower-cased (`PhoenixKitAI/1.0 (+url)` → `phoenixkitai`).
  defp token(value) do
    value = String.trim(value)

    if String.starts_with?(value, "*") do
      "*"
    else
      case Regex.run(~r/\A[a-zA-Z_-]+/, value) do
        [token] -> String.downcase(token)
        nil -> ""
      end
    end
  end

  defp parse_delay(value) do
    case Float.parse(value) do
      {delay, _} when delay >= 0 -> delay
      _ -> nil
    end
  end

  # ── matching ─────────────────────────────────────────────────────────

  # Google's robots matcher: the set of path positions the pattern so far
  # can end at, advanced octet by octet — O(pattern × path), no regex to
  # backtrack or compile.
  defp matches?(pattern, path), do: match_from(pattern, path, [0], byte_size(path))

  defp match_from(_pattern, _path, [], _size), do: false
  defp match_from(<<>>, _path, _positions, _size), do: true
  defp match_from("$", _path, positions, size), do: size in positions

  defp match_from(<<"*", rest::binary>>, path, [lowest | _], size),
    do: match_from(rest, path, Enum.to_list(lowest..size//1), size)

  defp match_from(<<char, rest::binary>>, path, positions, size) do
    next = for p <- positions, p < size, :binary.at(path, p) == char, do: p + 1
    match_from(rest, path, next, size)
  end

  # RFC 9309 §2.2.2: compared percent-encoded — a non-ASCII (or control or
  # space) octet encoded, an encoded unreserved character decoded, the hex
  # of every other escape upper-cased.
  # Consecutive `*` are one (and would each cost a pass of the matcher).
  defp normalize(text) do
    text
    |> String.replace(~r/\*{2,}/, "*")
    |> decode_unreserved()
    |> URI.encode(&(&1 > 0x20 and &1 < 0x7F))
  end

  defp decode_unreserved(text) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, text, fn _whole, hex ->
      char = String.to_integer(hex, 16)

      if unreserved?(char),
        do: <<char>>,
        else: "%" <> String.upcase(hex)
    end)
  end

  defp unreserved?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?., ?_, ?~]
end
