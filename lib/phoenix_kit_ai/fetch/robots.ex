defmodule PhoenixKitAI.Fetch.Robots do
  @moduledoc """
  robots.txt, parsed and matched the way RFC 9309 says: the group of the
  longest user-agent token our product token contains, else the `*` group;
  in it the longest matching rule wins (`*` matches any run of characters,
  a trailing `$` anchors the end), an `Allow` winning a tie; no matching
  rule allows. `Crawl-delay` (seconds), which the RFC leaves out, is read
  from the same group.
  """

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
    agent = String.downcase(agent)
    groups = groups(body)

    matching = fn {agents, _lines} ->
      agents
      |> Enum.filter(&(&1 != "*" and String.contains?(agent, &1)))
      |> Enum.map(&byte_size/1)
      |> Enum.max(fn -> 0 end)
    end

    best = groups |> Enum.map(matching) |> Enum.max(fn -> 0 end)

    # Every group naming the chosen token counts (a file may split one);
    # with none, every `*` group.
    lines =
      if best > 0,
        do: groups |> Enum.filter(&(matching.(&1) == best)) |> Enum.flat_map(&elem(&1, 1)),
        else:
          groups
          |> Enum.filter(fn {agents, _} -> "*" in agents end)
          |> Enum.flat_map(&elem(&1, 1))

    # An empty Disallow allows everything: it is no rule.
    rules =
      for {key, value} <- lines, key in ["allow", "disallow"], value != "" do
        {if(key == "allow", do: :allow, else: :disallow), value}
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
    path = if path in [nil, ""], do: "/", else: path

    rules
    |> Enum.filter(fn {_kind, pattern} -> matches?(pattern, path) end)
    |> Enum.max_by(fn {kind, pattern} -> {pattern_length(pattern), kind == :allow} end, fn ->
      nil
    end)
    |> case do
      nil -> true
      {kind, _pattern} -> kind == :allow
    end
  end

  # ── parsing ──────────────────────────────────────────────────────────

  # A group is one or more User-agent lines followed by its rules; a
  # User-agent line after a rule starts the next group.
  defp groups(body) do
    body
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({[], nil}, fn
      {"user-agent", agent}, {groups, {agents, [], :agents}} ->
        {groups, {[String.downcase(agent) | agents], [], :agents}}

      {"user-agent", agent}, {groups, current} ->
        {close(groups, current), {[String.downcase(agent)], [], :agents}}

      _line, {groups, nil} ->
        # A rule before any User-agent belongs to no group.
        {groups, nil}

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

    case String.split(raw, ":", parts: 2) do
      [key, value] -> {key |> String.trim() |> String.downcase(), String.trim(value)}
      _ -> nil
    end
  end

  defp parse_delay(value) do
    case Float.parse(value) do
      {delay, _} when delay >= 0 -> delay
      _ -> nil
    end
  end

  # ── matching ─────────────────────────────────────────────────────────

  defp matches?(pattern, path) do
    {pattern, anchored?} =
      if String.ends_with?(pattern, "$"),
        do: {String.trim_trailing(pattern, "$"), true},
        else: {pattern, false}

    regex =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}#{if anchored?, do: "\\z", else: ""}/s, path)
  end

  defp pattern_length(pattern), do: String.length(pattern)
end
