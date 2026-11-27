defmodule PhoenixKitAI.CSPInlineTagsTest do
  @moduledoc """
  The pages of this module work under a host Content-Security-Policy that allows inline code
  by nonce only (`script-src 'self' 'nonce-…'`). The module renders no inline `<style>` /
  `<script>` and no inline event handler; this test keeps it that way. An inline style added
  later carries the page's nonce through a feature-detecting `PhoenixKitAI.Web.CSP` helper
  (see AGENTS.md, "Content-Security-Policy"); a handler has no nonce, so a `phx-` binding or
  a hook in the module's bundle does that work.

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # The module's prebuilt JS (what `js_sources/0` declares), scanned for markup it builds.
  @bundles ["priv/static/assets/phoenix_kit_ai.js"]

  @tag_opening ~r/<(?:script|style)(?=[\s>])(?:[^>"']|"[^"]*"|'[^']*')*>/i

  test "templates keep scripts in hooks and put a nonce on inline styles" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not allowed_tag?(opening),
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # Skip quoted attribute values as a unit so words inside them cannot authorize a tag.
  @attribute ~r/\s+([^\s=\/>]+)\s*=\s*("[^"]*"|'[^']*'|\{[^}]*\}|[^\s>]+)/

  defp allowed_tag?(opening) do
    attributes =
      for [_, name, value] <- Regex.scan(@attribute, opening), into: %{} do
        {String.downcase(name), value}
      end

    if opening =~ ~r/^<script\b/i do
      Map.has_key?(attributes, "src") or
        attributes[":type"] == "{Phoenix.LiveView.ColocatedHook}"
    else
      (attributes["nonce"] || "") =~ ~r/^\{\s*(?:PhoenixKitAI\.Web\.)?CSP\.nonce\(/
    end
  end

  test "tag permissions belong to the relevant element and attribute" do
    assert allowed_tag?(~s(<script src="/app.js">))
    assert allowed_tag?("<script :type={Phoenix.LiveView.ColocatedHook}>")
    assert allowed_tag?("<style nonce={PhoenixKitAI.Web.CSP.nonce(assigns)}>")
    refute allowed_tag?("<style src='/app.css'>")
    refute allowed_tag?(~s(<SCRIPT data-src="/app.js">))
    refute allowed_tag?(~s(<script title=" src='/app.js' ">))
    refute allowed_tag?("<script nonce={CSP.nonce(assigns)}>")
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written, a literal attribute
  # the browser cannot match.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ ~r/\bnonce\s*=\s*\{\s*(?:PhoenixKitAI\.Web\.)?CSP\.nonce\(/,
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # Core's module is newer than the core floor: a direct call would not compile against the
  # floor. The module has no caller today; one added later goes through a helper at
  # `lib/phoenix_kit_ai/web/csp.ex`, the only file allowed to name core's module.
  test "PhoenixKitWeb.CSP is called through the feature-detecting helper only" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path != "lib/phoenix_kit_ai/web/csp.ex",
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*#/),
          line =~ ~r/PhoenixKitWeb\.CSP\.[a-z_]+\(/ or
            line =~ ~r/on_mount\(?\s*PhoenixKitWeb\.CSP\b/,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!(
             "\\son(?!ly=)[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]",
             "i"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding or a hook in the " <>
             "module's bundle):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img ONERROR = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button phx-click="go">) =~ @handler
    refute ~s(<.table only={@only}>) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  test "the bundle builds no markup with an inline event handler" do
    offenders =
      for {path, line, number} <- bundle_lines(),
          line =~ ~r/\son[a-z]+\s*=\s*\\?["']/i or line =~ ~r/javascript:/i,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # Hooks ship as a bundle. A dynamically created style needs the page nonce.
  test "the bundle creates no unstamped <style>/<script>, and evaluates no strings" do
    offenders =
      for path <- @bundles,
          [{_path, line, number} | following] <- Enum.chunk_every(bundle_lines([path]), 7, 1),
          next = Enum.map(following, &elem(&1, 1)),
          problem = bundle_problem(line, next),
          do: "#{path}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "adopting a style cannot authorize a script created by a hook" do
    next_lines = ["window.PhoenixKitInternals.adoptStyle(el)"]
    assert bundle_problem("document.createElement('script')", next_lines)
    refute bundle_problem("document.createElement('style')", next_lines)
  end

  defp bundle_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(\s*["']script["']\s*\)/i ->
        "creates a script element outside the hook bundle loader"

      line =~ ~r/createElement\(\s*["']style["']\s*\)/i and
          not Enum.any?(next_lines, &(&1 =~ "adoptStyle")) ->
        "creates a style element without a nearby adoptStyle call"

      line =~ ~r/["'`]<(?:style|script)\b/ ->
        "builds a <style>/<script> tag as a string"

      line =~ ~r/\beval\(|new Function\(/ ->
        "evaluates a string"

      true ->
        nil
    end
  end

  test "the scanned bundles are the ones js_sources/0 declares" do
    declared = for %{file: file} <- PhoenixKitAI.js_sources(), do: Path.join("priv", file)

    assert Enum.sort(declared) == Enum.sort(@bundles)
  end

  test "the scanned bundle is the only JavaScript the module ships" do
    assert Enum.sort(Path.wildcard("{lib,priv}/**/*.{js,ts}")) == Enum.sort(@bundles)
  end

  # The bundles' lines without their comment lines.
  defp bundle_lines(paths \\ @bundles) do
    for path <- paths,
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        not (line =~ ~r{^\s*(//|\*|/\*)}),
        do: {path, line, number}
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
