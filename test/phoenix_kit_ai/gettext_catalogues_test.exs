defmodule PhoenixKitAI.GettextCataloguesTest do
  @moduledoc """
  Every language this module ships is complete: each entry of the template is
  translated (an empty `msgstr` shows English on that language's pages, as
  Dictate's "Writing down what you said…" did on German, Spanish, French,
  Italian and Chinese ones before they had catalogues), none is fuzzy (gettext
  ignores a fuzzy entry), every placeholder survives, and a plural entry has
  the number of forms its header declares.
  """
  use ExUnit.Case, async: true

  alias Expo.Message.{Plural, Singular}

  @root "priv/gettext"
  @shipped ~w(de en es et fr it ru zh)

  defp locales do
    @root
    |> File.ls!()
    |> Enum.filter(&File.exists?(Path.join([@root, &1, "LC_MESSAGES", "default.po"])))
    |> Enum.sort()
  end

  defp po(locale),
    do: Expo.PO.parse_file!(Path.join([@root, locale, "LC_MESSAGES", "default.po"]))

  defp text(iodata), do: IO.iodata_to_binary(iodata)

  defp placeholders(string),
    do: ~r/%\{\w+\}/ |> Regex.scan(string) |> List.flatten() |> MapSet.new()

  defp fuzzy?(message), do: Enum.any?(message.flags, &("fuzzy" in &1))

  defp nplurals(po) do
    [_, n] = Regex.run(~r/nplurals=(\d+)/, Enum.join(po.headers))
    String.to_integer(n)
  end

  test "the module ships its languages" do
    assert locales() == @shipped
  end

  # The line a consuming app found in English on its German, Spanish, French,
  # Italian and Chinese pages: the catalogues are compiled into the backend.
  test "Dictate's status line speaks every shipped language" do
    english = "Writing down what you said…"

    for locale <- @shipped -- ["en"] do
      text =
        Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
          Gettext.dgettext(PhoenixKitAI.Gettext, "default", english)
        end)

      refute text == english, "#{locale} shows it in English"
    end
  end

  test "each catalogue has every entry of the template" do
    keys = fn messages -> MapSet.new(messages, &{text(&1.msgctxt || ""), text(&1.msgid)}) end
    template = keys.(Expo.PO.parse_file!(Path.join(@root, "default.pot")).messages)

    for locale <- locales() do
      assert keys.(po(locale).messages) == template, "#{locale} is out of step with default.pot"
    end
  end

  for locale <- ~w(de es et fr it ru zh) do
    test "#{locale}: every entry is translated, none fuzzy, placeholders kept" do
      catalogue = po(unquote(locale))
      forms = nplurals(catalogue)

      problems =
        for message <- catalogue.messages, problem = problem(message, forms), do: problem

      assert problems == [], Enum.join(Enum.take(problems, 20), "\n")
    end
  end

  defp problem(message, forms) do
    if fuzzy?(message),
      do: "fuzzy: #{text(message.msgid)}",
      else: entry_problem(message, forms)
  end

  defp entry_problem(%Singular{} = message, _forms) do
    msgid = text(message.msgid)
    msgstr = text(message.msgstr)

    cond do
      String.trim(msgstr) == "" -> "untranslated: #{msgid}"
      placeholders(msgstr) != placeholders(msgid) -> "placeholders: #{msgid}"
      true -> nil
    end
  end

  defp entry_problem(%Plural{} = message, forms) do
    msgid = text(message.msgid)
    strings = message.msgstr |> Enum.sort() |> Enum.map(fn {_, s} -> text(s) end)
    allowed = MapSet.union(placeholders(msgid), placeholders(text(message.msgid_plural)))

    cond do
      length(strings) != forms ->
        "#{length(strings)} plural forms, not #{forms}: #{msgid}"

      Enum.any?(strings, &(String.trim(&1) == "")) ->
        "untranslated: #{msgid}"

      Enum.any?(strings, &(not MapSet.subset?(placeholders(&1), allowed))) ->
        "placeholders: #{msgid}"

      true ->
        nil
    end
  end
end
