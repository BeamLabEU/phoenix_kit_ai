defmodule PhoenixKitAI.Web.Components.JournalRetentionCardTest do
  @moduledoc """
  The card's status lines that name a kind inside a sentence: each kind
  has its own sentence (no label lowercased into another one), in every
  catalogue; a period stored without its change time names that period.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Retention
  alias PhoenixKitAI.Web.Components.JournalRetentionCard

  @now ~U[2026-10-25 12:00:00Z]

  defp lines(settings, locale) do
    Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
      settings
      |> JournalRetentionCard.status_lines(Retention.last_run_from(nil), @now)
      |> Map.new(fn {id, _type, text} -> {id, text} end)
    end)
  end

  defp settling(kinds) do
    Enum.reduce(kinds, Retention.settings_from(nil), fn kind, acc ->
      acc
      |> Map.put(kind, {30, :day})
      |> put_in([:changed_at, kind], DateTime.add(@now, -3600))
    end)
  end

  defp unconfirmed(kinds) do
    Retention.settings_from(Map.new(kinds, &{Atom.to_string(&1), %{"n" => 30, "unit" => "day"}}))
  end

  @kinds [:content, :requests, :guard_events]

  @first %{
    "en" => %{
      content: "The first cleanup of the content of journal entries runs no earlier than",
      requests: "The first cleanup of journal entries runs no earlier than",
      guard_events: "The first cleanup of guard events runs no earlier than"
    },
    "ru" => %{
      content: "Первая очистка содержимого записей журнала — не раньше",
      requests: "Первая очистка записей журнала — не раньше",
      guard_events: "Первая очистка событий охраны задач — не раньше"
    },
    "et" => %{
      content: "Logikirjete sisu esimene puhastus – kõige varem",
      requests: "Logikirjete esimene puhastus – kõige varem",
      guard_events: "Valve sündmuste esimene puhastus – kõige varem"
    }
  }

  @unconfirmed %{
    "en" => %{
      content: "The period for the content of journal entries (30 days) is stored without",
      requests: "The period for journal entries (30 days) is stored without",
      guard_events: "The period for guard events (30 days) is stored without"
    },
    "ru" => %{
      content: "Срок для содержимого записей журнала (30 дней) сохранён без",
      requests: "Срок для записей журнала (30 дней) сохранён без",
      guard_events: "Срок для событий охраны задач (30 дней) сохранён без"
    },
    "et" => %{
      content: "Logikirjete sisu tähtaeg (30 päeva) on salvestatud ilma",
      requests: "Logikirjete tähtaeg (30 päeva) on salvestatud ilma",
      guard_events: "Valve sündmuste tähtaeg (30 päeva) on salvestatud ilma"
    }
  }

  # Russian: the verb agrees with the count — 1 / 2–4 / 5+
  @ru_plurals [
    {"%{count} journal entry deleted", "%{count} journal entries deleted",
     ["удалена 1 запись журнала", "удалены 2 записи журнала", "удалено 5 записей журнала"]},
    {"%{count} guard event deleted", "%{count} guard events deleted",
     [
       "удалено 1 событие охраны задач",
       "удалены 3 события охраны задач",
       "удалено 11 событий охраны задач"
     ]},
    {"%{count} journal entry older than %{date} will be deleted.",
     "%{count} journal entries older than %{date} will be deleted.",
     [
       "Будет удалена 21 запись журнала старше D.",
       "Будут удалены 2 записи журнала старше D.",
       "Будет удалено 5 записей журнала старше D."
     ]},
    {"%{count} guard event older than %{date} will be deleted.",
     "%{count} guard events older than %{date} will be deleted.",
     [
       "Будет удалено 1 событие охраны задач старше D.",
       "Будут удалены 4 события охраны задач старше D.",
       "Будет удалено 12 событий охраны задач старше D."
     ]}
  ]

  test "ru: guard events are named as the label names them, in every string" do
    po =
      File.read!(Application.app_dir(:phoenix_kit_ai, "priv/gettext/ru/LC_MESSAGES/default.po"))

    for line <- String.split(po, "\n"),
        String.starts_with?(line, "msgstr"),
        String.contains?(line, "охраны") do
      assert line =~ "охраны задач", line
    end
  end

  test "ru: the deletion counts agree with the number" do
    Gettext.with_locale(PhoenixKitAI.Gettext, "ru", fn ->
      for {msgid, plural, expected} <- @ru_plurals,
          text <- expected do
        [count] = Regex.run(~r/\d+/, text)

        assert Gettext.dpngettext(
                 PhoenixKitAI.Gettext,
                 "default",
                 nil,
                 msgid,
                 plural,
                 String.to_integer(count),
                 %{date: "D"}
               ) == text
      end
    end)
  end

  for locale <- ["en", "ru", "et"] do
    test "#{locale}: the first cleanup of each kind is a sentence of its own" do
      lines = lines(settling(@kinds), unquote(locale))

      for kind <- @kinds do
        assert lines["first-#{kind}"] =~ @first[unquote(locale)][kind]
      end
    end

    test "#{locale}: a period stored without its change time names the period" do
      lines = lines(unconfirmed(@kinds), unquote(locale))

      for kind <- @kinds do
        assert lines["unconfirmed-#{kind}"] =~ @unconfirmed[unquote(locale)][kind]
      end
    end
  end
end
