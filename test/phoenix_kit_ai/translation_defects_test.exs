defmodule PhoenixKitAI.TranslationDefectsTest do
  @moduledoc """
  Regression tests for specific ru/et translation defects found during PR
  review (not gated by `:requires_phoenix_kit_i18n_api` — these exercise
  plain `Gettext` lookups against this module's own catalogue, not the
  `PhoenixKit.Dashboard.Tab` API).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Gettext, as: AIGettext

  # Regression: `endpoints.html.heex`'s integration-health badge has two
  # branches in the same `cond` filling the same slot (badge-error: the
  # pinned integration was deleted; badge-warning: none was ever selected).
  # Both used to translate to near-synonyms in Russian ("Интеграция
  # отсутствует" / "Нет интеграции"), distinguishable only by badge color.
  describe "'Integration missing' and 'No integration' read as distinct states" do
    test "ru" do
      Gettext.with_locale(AIGettext, "ru", fn ->
        deleted = Gettext.dgettext(AIGettext, "default", "Integration missing")
        never_selected = Gettext.dgettext(AIGettext, "default", "No integration")

        assert deleted == "Интеграция не найдена"
        assert never_selected == "Интеграция не выбрана"
        refute deleted == never_selected
      end)
    end

    test "et (already disambiguated before this test existed — guards against regression)" do
      Gettext.with_locale(AIGettext, "et", fn ->
        deleted = Gettext.dgettext(AIGettext, "default", "Integration missing")
        never_selected = Gettext.dgettext(AIGettext, "default", "No integration")

        refute deleted == never_selected
      end)
    end
  end

  # Regression: ru "Chat / Completion" ("Чат / завершение") sits in the same
  # model-type <select> as "Синтез речи" (text-to-speech) and reads as
  # "chat / termination" rather than "chat / generation".
  test "ru 'Chat / Completion' does not read as termination" do
    Gettext.with_locale(AIGettext, "ru", fn ->
      translated = Gettext.dgettext(AIGettext, "default", "Chat / Completion")

      refute translated =~ "завершение"
      assert translated == "Чат / генерация"
    end)
  end

  # Regression: ru "Uses" ("Используется", a passive verb) is the header of
  # `prompts.html.heex`'s numeric sortable `usage_count` column — it names a
  # count, not a state, and needs the noun form "Использований".
  test "ru 'Uses' (usage-count column header) is a noun, not a verb" do
    Gettext.with_locale(AIGettext, "ru", fn ->
      assert Gettext.dgettext(AIGettext, "default", "Uses") == "Использований"
    end)
  end

  # Regression: `{{variables}}`/`{{VariableName}}` is matched by
  # `Prompt`'s ASCII-only `@variable_regex` and `@valid_variable_name`
  # (prompt.ex). Translating the placeholder itself (e.g. ru
  # `{{переменные}}`, et `{{muutujaid}}`) teaches an example the parser
  # silently rejects.
  test "the '{{variables}}' placeholder stays untranslated in ru and et" do
    msgid = "Sent as the system message before the user prompt. Supports {{variables}} too."

    for locale <- ["ru", "et"] do
      Gettext.with_locale(AIGettext, locale, fn ->
        assert Gettext.dgettext(AIGettext, "default", msgid) =~ "{{variables}}"
      end)
    end
  end

  # Regression: this module's et catalogue used the formal "teie" address
  # (Valige, Sisestage, Muutke, ...) throughout, while core and the rest of
  # this module's own strings use the informal "sina" address (Vali,
  # Sisesta, Muuda, ...) — including a near-verbatim duplicate of core's
  # own "Vali teenusepakkuja..." that this module had spelled "Valige
  # teenusepakkuja…". A representative sample, not exhaustive.
  describe "et catalogue uses the informal 'sina' address, matching core" do
    test "'Select a provider...' matches core's informal phrasing" do
      Gettext.with_locale(AIGettext, "et", fn ->
        translated =
          Gettext.dgettext(
            AIGettext,
            "default",
            "Select a provider to see available models with pricing details"
          )

        assert translated == "Vali teenusepakkuja, et näha saadaolevaid mudeleid koos hinnainfoga"
      end)
    end

    test "a sample of formerly-formal imperatives are now informal" do
      Gettext.with_locale(AIGettext, "et", fn ->
        assert Gettext.dgettext(AIGettext, "default", "Please select an endpoint") ==
                 "Palun vali lõpp-punkt"

        assert Gettext.dgettext(AIGettext, "default", "Leave blank to inherit.") ==
                 "Jäta tühjaks, et pärida väärtus."

        assert Gettext.dgettext(AIGettext, "default", "Type your message to the AI...") ==
                 "Sisesta oma sõnum AI-le…"
      end)
    end
  end
end
