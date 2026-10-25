defmodule PhoenixKitAI.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every admin tab registered by `PhoenixKitAI.admin_tabs/0` carries
      `gettext_backend: PhoenixKitAI.Gettext`.
    * Locale switching on the module's own backend produces translated
      labels for every sidebar tab (regression guard for the
      `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with the
      package).
    * `Tab.localized_label/1` falls back to the raw msgid for an unknown
      locale.
    * `permission_metadata/0`'s label resolves through the same backend the
      admin permissions matrix uses.

  `admin_tabs/0` and `permission_metadata/0` declare their labels as plain
  string literals, so `mix gettext.extract` never sees this file directly —
  it scans for gettext macro call sites, not struct fields. `PhoenixKitAI.
  translatable_labels/0` pins each one via `dgettext_noop/2` so extraction
  finds them and `mix gettext.merge` doesn't delete them as obsolete (a
  `.po` entry absent from a freshly built `.pot` is removed by default,
  flags or no flags). See `priv/gettext/ru/LC_MESSAGES/default.po` for the
  translations and `guides/per-module-i18n.md` in `phoenix_kit` core for
  the general per-module i18n setup.
  """

  use ExUnit.Case, async: true

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitAI.Gettext, as: AIGettext

  describe "admin_tabs/0 wiring" do
    test "every tab carries the module's own gettext backend" do
      for tab <- PhoenixKitAI.admin_tabs() do
        assert tab.gettext_backend == AIGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"
      end
    end
  end

  # "AI" is intentionally left untranslated in both locales (matches core's
  # own treatment of "CRM" and other product-name tabs), so its msgstr is
  # identical to its msgid in every locale. A runtime `Tab.localized_label/1`
  # (or `Gettext.dgettext/3`) check can't tell "translated to the same
  # string" apart from "entry missing, fell back to the raw msgid" — both
  # return "AI". `po_msgstr/2` reads the parsed `.po` file directly instead,
  # so it fails if the catalogue entry (added via `translatable_labels/0`)
  # is ever deleted, e.g. by a `mix gettext.merge` run before it existed.
  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'AI' tab to 'AI' (intentionally untranslated)" do
      parent = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(parent) == "AI"
      end)

      assert po_msgstr("ru", "AI") == "AI"
    end

    test "et locale resolves the parent 'AI' tab to 'AI' (intentionally untranslated)" do
      parent = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(parent) == "AI"
      end)

      assert po_msgstr("et", "AI") == "AI"
    end

    test "ru locale resolves the 'Endpoints' tab to 'Конечные точки'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Конечные точки"
      end)
    end

    test "et locale resolves the 'Endpoints' tab to 'Lõpp-punktid'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Lõpp-punktid"
      end)
    end

    test "ru locale resolves the 'Prompts' tab to 'Промпты'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_prompts))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Промпты"
      end)
    end

    test "et locale resolves the 'Prompts' tab to 'Promptid'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_prompts))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Promptid"
      end)
    end

    test "ru locale resolves the 'Playground' tab to 'Песочница'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_playground))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Песочница"
      end)
    end

    test "et locale resolves the 'Playground' tab to 'Liivakast'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_playground))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Liivakast"
      end)
    end

    test "ru locale resolves the 'Usage' tab to 'Использование'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_usage))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Использование"
      end)
    end

    test "et locale resolves the 'Usage' tab to 'Kasutus'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_usage))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Kasutus"
      end)
    end

    test "unknown locale falls back to the raw msgid" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "zz", fn ->
        assert Tab.localized_label(tab) == tab.label
      end)
    end
  end

  describe "permission_metadata/0 wiring" do
    test "carries the module's own gettext backend for the permissions matrix" do
      meta = PhoenixKitAI.permission_metadata()

      assert meta.gettext_backend == AIGettext
      assert meta.gettext_domain == "default"
    end

    # Mirrors what `PhoenixKit.Users.Permissions.localized_module_label/1`
    # does at render time: `Gettext.dgettext(backend, domain, label)`. Like
    # the tab-level "AI" checks above, the label is intentionally
    # untranslated, so this is backed by `po_msgstr/2` rather than a
    # runtime-only lookup.
    test "label resolves through the declared backend and domain" do
      meta = PhoenixKitAI.permission_metadata()

      assert Gettext.dgettext(meta.gettext_backend, meta.gettext_domain, meta.label) == "AI"
      assert po_msgstr("ru", meta.label) == "AI"
      assert po_msgstr("et", meta.label) == "AI"
    end
  end

  # Regression: `Prompt`'s variable syntax (`{{VariableName}}`) is matched by
  # `@variable_regex ~r/\{\{(\w+)\}\}/` (prompt.ex) and validated by
  # `@valid_variable_name ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/` — both ASCII-only,
  # neither compiled with the `/u` flag. A translator who localizes the
  # `{{variables}}`/`{{VariableName}}` placeholder itself (e.g. Russian
  # `{{переменные}}`, Estonian `{{muutujaid}}`) teaches the user an example
  # that the parser silently rejects: following it produces a template whose
  # variable is never extracted or interpolated, with no error anywhere.
  describe "template placeholder syntax stays ASCII in every locale" do
    test "'{{variables}}' is not translated in the system-message hint" do
      msgid = "Sent as the system message before the user prompt. Supports {{variables}} too."

      for locale <- ["ru", "et"] do
        assert po_msgstr(locale, msgid) =~ "{{variables}}",
               "#{locale} msgstr for #{inspect(msgid)} must keep the literal " <>
                 "\"{{variables}}\" placeholder untranslated"
      end
    end
  end

  describe "translated catalogues" do
    test "no et or ru entry is left with an empty msgstr" do
      for locale <- ["ru", "et"] do
        path = Path.join(["priv", "gettext", locale, "LC_MESSAGES", "default.po"])
        {:ok, po} = Expo.PO.parse_file(path)

        empty =
          for message <- po.messages,
              strings = msgstrs(message),
              Enum.any?(strings, &(String.trim(&1) == "")),
              do: message.msgid |> IO.iodata_to_binary()

        assert empty == [], "#{locale}: untranslated #{inspect(empty)}"
      end
    end
  end

  defp msgstrs(%Expo.Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp msgstrs(%Expo.Message.Plural{msgstr: msgstr}),
    do: Enum.map(msgstr, fn {_n, text} -> IO.iodata_to_binary(text) end)

  # Reads the msgstr for `msgid` straight out of the locale's parsed `.po`
  # file (nil if the entry is missing), bypassing Gettext's fallback-to-msgid
  # behavior so a deleted/never-added entry actually fails the assertion.
  defp po_msgstr(locale, msgid) do
    path = Path.join(["priv", "gettext", locale, "LC_MESSAGES", "default.po"])
    {:ok, po} = Expo.PO.parse_file(path)

    po.messages
    |> Enum.find(&(IO.iodata_to_binary(&1.msgid) == msgid))
    |> case do
      nil -> nil
      entry -> IO.iodata_to_binary(entry.msgstr)
    end
  end
end
