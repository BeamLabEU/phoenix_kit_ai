defmodule PhoenixKitAI.Components.AiMultilangTabsTest do
  @moduledoc """
  Render pins for `<.ai_multilang_tabs>` — the bundled tabs + AI-translate
  row wrapper:

    * with an enabled config: tabs render AND the button/progress/hint row
      shows in the canonical under-the-tabs placement
    * with a nil/disabled config: identical to core's tabs alone — no row,
      no button (safe to pass the attr unconditionally)
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitAI.Components.AITranslate

  defp tabs do
    [
      %{code: "en-US", name: "English", is_primary: true},
      %{code: "de-DE", name: "German", is_primary: false}
    ]
  end

  defp config do
    %{
      enabled: true,
      event: "ai_translate_lang",
      toggle_event: "ai_toggle_modal",
      select_endpoint_event: "ai_select_endpoint",
      select_prompt_event: "ai_select_prompt",
      select_scope_event: "ai_select_scope",
      generate_prompt_event: "ai_generate_prompt",
      missing: ["de-DE"],
      all_langs: ["de-DE"],
      in_flight: [],
      modal_open: false,
      endpoints: [],
      prompts: [],
      selected_endpoint_uuid: nil,
      selected_prompt_uuid: nil,
      scope: :missing,
      translation_progress: 0,
      translation_total: 0,
      translation_status: nil,
      slow: false,
      default_prompt_exists: false,
      current_lang: "en-US"
    }
  end

  test "puts the AI button at the end of the tab row, with no row of its own" do
    assigns = %{tabs: tabs(), config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    assert html =~ "AI Translate"
    assert html =~ "German"
    # One row: the tabs, then the button, in the same flex container.
    assert html =~ ~r/class="flex items-end gap-2 mb-4".*German.*AI Translate/s
    # Nothing running: no progress/hint row under the tabs.
    refute html =~ "-mt-3"
    refute html =~ "<progress"
  end

  test "an in-flight session renders the progress bar inside the row" do
    config =
      %{config() | in_flight: ["de-DE"], translation_status: :in_progress, translation_total: 1}

    assigns = %{tabs: tabs(), config: config}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    assert html =~ "progress"
  end

  test "ai_row_class and class both forward" do
    assigns = %{tabs: tabs(), config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        class="my-tabs-class"
        ai_row_class="my-row-class"
        ai_translate={@config}
      />
      """)

    assert html =~ "my-tabs-class"
    refute html =~ "card-body"
    # The row class is for the progress/hint row, drawn only while a
    # translation runs.
    refute html =~ "my-row-class"

    running = %{
      config()
      | in_flight: ["de-DE"],
        translation_status: :in_progress,
        translation_total: 1
    }

    assigns = %{tabs: tabs(), config: running}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_row_class="my-row-class"
        ai_translate={@config}
      />
      """)

    assert html =~ "my-row-class"
    assert html =~ "<progress"
  end

  test "nil config renders the tabs alone — no AI row" do
    assigns = %{tabs: tabs()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
      />
      """)

    refute html =~ "AI Translate"
    refute html =~ "-mt-3"
    assert html =~ "German"
  end

  test "single-language tabs render nothing AND suppress the AI row" do
    # Core's tabs self-hide with fewer than two languages; the AI row must
    # follow (no floating "AI Translate" with nothing to translate into).
    assigns = %{config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={[%{code: "en-US", name: "English", is_primary: true}]}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    refute html =~ "AI Translate"
    refute html =~ "Content Language"
  end

  test "multilang disabled suppresses tabs and AI row alike" do
    assigns = %{tabs: tabs(), config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={false}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    refute html =~ "AI Translate"
  end

  test "disabled config renders the tabs alone" do
    assigns = %{tabs: tabs(), config: %{config() | enabled: false}}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    refute html =~ "AI Translate"
  end

  test "the Content Language header is off by default, matching core's multilang_tabs" do
    assigns = %{tabs: tabs(), config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        ai_translate={@config}
      />
      """)

    # Core flipped show_header/show_info to false (2026-08-15 product call).
    # This wrapper declares its OWN attr defaults rather than inheriting them,
    # so nothing makes the two track each other automatically — if core's
    # default moves again and this one does not, AI-enabled forms silently
    # keep chrome every other form has lost. That is what this pins.
    refute html =~ "Content Language"

    # The tabs themselves are unaffected — this is about the header row only.
    assert html =~ "German"
  end

  test "an explicit show_header still renders the header" do
    assigns = %{tabs: tabs(), config: config()}

    html =
      rendered_to_string(~H"""
      <.ai_multilang_tabs
        multilang_enabled={true}
        language_tabs={@tabs}
        current_lang="en-US"
        show_header={true}
        ai_translate={@config}
      />
      """)

    # The default changed; the attr did not go away.
    assert html =~ "Content Language"
  end
end
