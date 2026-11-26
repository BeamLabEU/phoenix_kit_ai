defmodule PhoenixKitAI.Fetch.Extract do
  @moduledoc """
  An HTML page's main content as clean text, plus what its head says about it.

  No HTML parser is a dependency of this module, so this is a tolerant
  tag scanner with a readability-style heuristic, not a DOM:

    1. Comments and the contents of `script`, `style`, `noscript`,
       `template`, `svg`, `iframe`, `canvas`, `object` and `textarea` are
       dropped first.
    2. The title (`og:title`, else `<title>`), description (`description`,
       else `og:description`), `lang`, canonical URL and site name are read
       from what is left.
    3. The page is walked block by block. `nav`, `header`, `footer`, `aside`,
       `form`, `button`, `select`, `dialog` and `menu` are boilerplate and
       dropped with everything inside them, and so is any element whose
       `class` / `id` / `role` names boilerplate (`menu`, `sidebar`, `cookie`,
       `breadcrumb`, `share`, `comment`, `banner`, …) unless it also names
       content (`article`, `content`, `main`, `post`, `entry`, `body`, `text`).
    4. When the page marks its main content (`main`, `article`,
       `role="main"`) and that holds at least a fifth of the text, only it is
       kept.
    5. A short block that is mostly link text (a row of links outside any
       `nav`) is dropped.

  The text keeps the structure a model reads well: blocks separated by a blank
  line, headings as `#`…`######`, list items as `- `, entities decoded,
  whitespace collapsed, a block repeated right after itself dropped.
  """

  @raw_text ~w(script style noscript template svg iframe canvas object textarea)
  @boilerplate ~w(nav header footer aside form button select dialog menu)
  @void ~w(area base br col embed hr img input link meta param source track wbr)
  @block ~w(address article blockquote body dd details div dl dt figcaption figure h1 h2 h3 h4 h5 h6 hr li main ol p pre section summary table tbody td tfoot th thead tr ul br)
  @main ~w(main article)

  @unlikely ~r/(?:^|[\s_\-])(?:nav|navbar|menu|header|footer|sidebar|side-bar|breadcrumbs?|cookies?|consent|banner|advert|ads?|sponsor|social|share|sharing|related|recommended|comments?|popup|modal|newsletter|subscribe|signup|login|skip|masthead|toolbar|pagination|pager)(?:$|[\s_\-])/i
  @likely ~r/article|content|main|post|entry|body|text|story/i

  @type t :: %{
          text: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          lang: String.t() | nil,
          canonical: String.t() | nil,
          site_name: String.t() | nil,
          main_content?: boolean()
        }

  @doc "The main text and metadata of `html` (see the moduledoc)."
  @spec extract(String.t()) :: t()
  def extract(html) when is_binary(html) do
    html = html |> utf8() |> strip_raw()
    meta = metadata(html)
    blocks = blocks(html)

    main = Enum.filter(blocks, & &1.main?)
    total = blocks |> Enum.map(& &1.chars) |> Enum.sum()
    main_chars = main |> Enum.map(& &1.chars) |> Enum.sum()
    use_main? = main != [] and main_chars * 5 >= total and main_chars > 0

    text =
      if(use_main?, do: main, else: blocks)
      |> Enum.reject(&link_row?/1)
      |> Enum.map(&render/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.dedup()
      |> Enum.join("\n\n")

    Map.merge(meta, %{text: text, main_content?: use_main?})
  end

  @doc "Decodes HTML entities (named ones in common use, and every numeric one)."
  @spec decode_entities(String.t()) :: String.t()
  def decode_entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/, text, fn whole, name ->
      entity(name) || whole
    end)
  end

  # ── stage 1 ──────────────────────────────────────────────────────────

  # A page that is not UTF-8 is read as Latin-1 (close enough to
  # windows-1252 for text a model reads).
  defp utf8(html) do
    if String.valid?(html) do
      html
    else
      case :unicode.characters_to_binary(html, :latin1) do
        bin when is_binary(bin) -> bin
        _ -> String.replace_invalid(html)
      end
    end
  end

  defp strip_raw(html) do
    html = Regex.replace(~r/<!--.*?-->/s, html, " ")
    html = Regex.replace(~r/<!\[CDATA\[.*?\]\]>/s, html, " ")

    Enum.reduce(@raw_text, html, fn tag, acc ->
      acc = Regex.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}\s*>/is, acc, " ")
      # An unclosed one runs to the end of the page.
      Regex.replace(~r/<#{tag}\b[^>]*>.*\z/is, acc, " ")
    end)
  end

  # ── stage 2 ──────────────────────────────────────────────────────────

  defp metadata(html) do
    metas = metas(html)

    %{
      title:
        clean(metas["og:title"]) ||
          clean(first(~r/<title\b[^>]*>(.*?)<\/title\s*>/is, html)),
      description: clean(metas["description"]) || clean(metas["og:description"]),
      lang: clean(first(~r/<html\b[^>]*\blang\s*=\s*["']?([^"'\s>]+)/i, html)),
      canonical: canonical(html),
      site_name: clean(metas["og:site_name"])
    }
  end

  defp metas(html) do
    ~r/<meta\b([^>]*)>/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.reduce(%{}, fn [attrs], acc ->
      attrs = attributes(attrs)
      name = attrs["name"] || attrs["property"]

      if is_binary(name) and is_binary(attrs["content"]),
        do: Map.put_new(acc, String.downcase(name), attrs["content"]),
        else: acc
    end)
  end

  defp canonical(html) do
    ~r/<link\b([^>]*)>/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.find_value(fn [attrs] ->
      attrs = attributes(attrs)

      if attrs["rel"]
         |> to_string()
         |> String.downcase()
         |> String.split()
         |> Enum.member?("canonical"),
         do: clean(attrs["href"])
    end)
  end

  defp attributes(text) do
    ~r/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
    |> Regex.scan(text)
    |> Map.new(fn [_ | [name | values]] ->
      {String.downcase(name), values |> Enum.reject(&(&1 == "")) |> List.first("")}
    end)
  end

  defp first(regex, html) do
    case Regex.run(regex, html, capture: :all_but_first) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case text |> strip_tags() |> decode_entities() |> squeeze() do
      "" -> nil
      value -> value
    end
  end

  defp strip_tags(text), do: Regex.replace(~r/<[^>]*>/, text, " ")

  # ── stage 3: blocks ──────────────────────────────────────────────────

  # The walk's state: the open drop (tag name and depth of the same name),
  # how deep inside main content and inside a link it is, the block being
  # filled (its kind and text) and the blocks done (newest first).
  defp blocks(html) do
    body =
      case Regex.run(~r/<body\b[^>]*>(.*)/is, html, capture: :all_but_first) do
        [inner] -> inner
        _ -> Regex.replace(~r/<head\b[^>]*>.*?<\/head\s*>/is, html, " ")
      end

    state = %{drop: nil, main: 0, link: 0, kind: :p, text: [], links: [], done: []}

    ~r/<[^>]*>/
    |> Regex.split(body, include_captures: true)
    |> Enum.reduce(state, &step/2)
    |> flush()
    |> Map.fetch!(:done)
    |> Enum.reverse()
  end

  defp step("<" <> _ = tag, state) do
    case tag_info(tag) do
      nil -> state
      info -> on_tag(info, state)
    end
  end

  defp step(_text, %{drop: {_, _}} = state), do: state

  defp step(text, state) do
    text = decode_entities(text)
    state = %{state | text: [state.text, text]}
    if state.link > 0, do: %{state | links: [state.links, text]}, else: state
  end

  # Inside a dropped element only its own name's depth matters.
  defp on_tag({:open, name, _attrs}, %{drop: {name, depth}} = state),
    do: if(name in @void, do: state, else: %{state | drop: {name, depth + 1}})

  defp on_tag({:close, name}, %{drop: {name, 1}} = state), do: %{state | drop: nil}

  defp on_tag({:close, name}, %{drop: {name, depth}} = state),
    do: %{state | drop: {name, depth - 1}}

  defp on_tag(_tag, %{drop: {_, _}} = state), do: state

  defp on_tag({:open, name, attrs}, state) do
    cond do
      name in @void and name != "br" ->
        state

      name in @boilerplate or (unlikely?(attrs) and name not in ["body", "html", "main"]) ->
        state |> flush() |> Map.put(:drop, {name, 1})

      true ->
        state
        |> then(&if(name in @block, do: flush(&1), else: &1))
        |> open(name, attrs)
    end
  end

  defp on_tag({:close, name}, state) do
    state
    |> then(&if(name in @block, do: flush(&1), else: &1))
    |> close(name)
  end

  defp open(state, "a", _attrs), do: %{state | link: state.link + 1}

  defp open(state, name, attrs) do
    state =
      if name in @main or attrs["role"] == "main",
        do: %{state | main: state.main + 1},
        else: state

    case name do
      "li" -> %{state | kind: :li}
      "h" <> n when n in ~w(1 2 3 4 5 6) -> %{state | kind: {:h, String.to_integer(n)}}
      "pre" -> %{state | kind: :pre}
      _ -> state
    end
  end

  # A closing tag cannot tell whether its opening one had `role="main"`;
  # `main` / `article` are what is counted down.
  defp close(state, "a"), do: %{state | link: max(state.link - 1, 0)}

  defp close(state, name) when name in @main, do: %{state | main: max(state.main - 1, 0)}

  # The kind a list item, heading or preformatted block gave lasts until it
  # closes, so a `<p>` inside an `<li>` is still the item.
  defp close(state, name) when name in ~w(li h1 h2 h3 h4 h5 h6 pre), do: %{state | kind: :p}
  defp close(state, _name), do: state

  defp flush(%{text: text, links: links, kind: kind, main: main} = state) do
    text = IO.iodata_to_binary(text)
    squeezed = if kind == :pre, do: String.trim(text), else: squeeze(text)

    done =
      if squeezed == "" do
        state.done
      else
        link_chars = links |> IO.iodata_to_binary() |> squeeze() |> String.length()

        [
          %{
            kind: kind,
            text: squeezed,
            chars: String.length(squeezed),
            link_chars: link_chars,
            main?: main > 0
          }
          | state.done
        ]
      end

    %{state | text: [], links: [], done: done}
  end

  defp tag_info(tag) do
    case Regex.run(~r/\A<\s*(\/?)\s*([a-zA-Z][a-zA-Z0-9:-]*)(.*?)\/?\s*>\z/s, tag) do
      [_, "/", name, _] -> {:close, String.downcase(name)}
      [_, "", name, attrs] -> {:open, String.downcase(name), attributes(attrs)}
      _ -> nil
    end
  end

  defp unlikely?(attrs) do
    names = Enum.map_join(["class", "id", "role"], " ", &Map.get(attrs, &1, ""))

    String.trim(names) != "" and Regex.match?(@unlikely, names) and
      not Regex.match?(@likely, names)
  end

  # ── stage 5 ──────────────────────────────────────────────────────────

  # A row of links: mostly link text and short. A long paragraph full of
  # links is still text.
  defp link_row?(%{chars: chars, link_chars: links, kind: kind}) when kind not in [:pre],
    do: chars < 300 and links * 2 > chars

  defp link_row?(_block), do: false

  defp render(%{kind: :li, text: text}), do: "- " <> text
  defp render(%{kind: {:h, n}, text: text}), do: String.duplicate("#", n) <> " " <> text
  defp render(%{text: text}), do: text

  # A no-break space is a space here (`String.split/1` keeps it).
  defp squeeze(text),
    do: text |> String.replace("\u00A0", " ") |> String.split() |> Enum.join(" ")

  # ── entities ─────────────────────────────────────────────────────────

  @named %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "laquo" => "«",
    "raquo" => "»",
    "bdquo" => "„",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "euro" => "€",
    "pound" => "£",
    "yen" => "¥",
    "cent" => "¢",
    "deg" => "°",
    "middot" => "·",
    "bull" => "•",
    "times" => "×",
    "shy" => "",
    "zwj" => "",
    "zwnj" => ""
  }

  defp entity("#x" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp entity("#X" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp entity("#" <> dec), do: codepoint(Integer.parse(dec))
  defp entity(name), do: Map.get(@named, name)

  defp codepoint({cp, ""}) when cp in 1..0xD7FF or cp in 0xE000..0x10FFFF, do: <<cp::utf8>>
  defp codepoint(_), do: nil
end
