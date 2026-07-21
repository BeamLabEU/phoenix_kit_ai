defmodule PhoenixKitAI.Components.AITranslate do
  @moduledoc """
  Shared AI-translation UI for multilang form LiveViews — the
  publishing/projects-style trigger button + modal, on top of core's
  `PhoenixKitAI.Translations` pipeline.

  Render-only function components driven by a single `ai_translate` config
  map the host LV builds each render; the host owns the state + event
  handlers (see `PhoenixKitAI.Translations` for the backend and
  any consumer's form LV for the wiring shape). Five surfaces:

    * `<.ai_multilang_tabs>` — core's multilang tabs with the
      button/progress/hint row bundled underneath in the canonical
      placement; the preferred entry point for new consumers (the modal
      still renders separately — see its doc).
    * `<.ai_translate_button>` — compact "AI Translate" trigger; toggles
      the modal. Spinner while a job is in flight.
    * `<.ai_translate_modal>` — daisyUI dialog: endpoint + prompt
      selectors, a "Generate Default Prompt" button when none exists, a
      scope picker (missing-only / all-overwrite / current tab), in-flight
      status, and one scope-driven "Translate" action.
    * `<.ai_translate_progress>` — slim inline progress bar for the session.
    * `<.ai_translate_hint>` — the "taking a while…" stall reassurance.

  ## Host contract

  Pass `ai_translate: %{...}` (string OR atom keys accepted):

      %{
        enabled: true,                  # gates render
        event: "translate_lang",        # dispatch (phx-value-lang)
        toggle_event: "toggle_ai",      # open/close modal
        select_endpoint_event: "...",   # endpoint dropdown change
        select_prompt_event: "...",     # prompt dropdown change
        select_scope_event: "...",      # scope radio change
        generate_prompt_event: "...",   # generate-default-prompt
        missing: ["es", "de"],          # langs lacking a translation
        all_langs: ["es", "de", "fr"],  # every non-primary enabled lang
        in_flight: ["es"],              # jobs running now
        modal_open: false,
        endpoints: [{uuid, name}, ...],
        prompts: [{uuid, name}, ...],
        selected_endpoint_uuid: "...",
        selected_prompt_uuid: "...",
        scope: :missing,                # :missing | :all | :current
        default_prompt_exists: true,
        current_lang: "es",
        primary_lang: "en",
        primary_lang_name: "English",
        # progress bar (optional):
        translation_status: :in_progress, # nil | :in_progress | :completed
        translation_progress: 1,
        translation_total: 3
      }

  ## Action contract

  The modal's single "Translate" button sends `event` with a `lang` value
  driven by `scope`:

    - `:missing` → `phx-value-lang="*"` (bulk, missing only)
    - `:all`     → `phx-value-lang="**"` (bulk, overwrite all non-primary)
    - `:current` → `phx-value-lang=<current_lang>` (single)

  Host's `handle_event(event, %{"lang" => lang}, socket)` branches on `"*"`,
  `"**"`, or a concrete code.

  ## Placement

  The modal contains its own `<form phx-change>` selectors — HTML forbids
  nested forms, so render `<.ai_translate_modal>` **outside** (after) the
  host's outer `</.form>`. The button can live inside the form. Both take
  the same config map; build it once and pass to both.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Components.Core.Icon
  alias PhoenixKitWeb.Components.MultilangForm

  attr(:ai_translate, :map, default: nil, doc: "Config map — see moduledoc.")

  @doc "Compact trigger button. Hidden when disabled / no toggle event."
  def ai_translate_button(assigns) do
    ~H"""
    <%= if button_visible?(@ai_translate) do %>
      <button
        type="button"
        class="btn btn-ghost btn-xs gap-2"
        phx-click={toggle_event_name(@ai_translate)}
        aria-haspopup="dialog"
        aria-expanded={if modal_open?(@ai_translate), do: "true", else: "false"}
      >
        <Icon.icon name="hero-language" class="w-4 h-4 text-primary" />
        <span>{gettext("AI Translate")}</span>
        <%= if has_in_flight?(@ai_translate) do %>
          <span class="loading loading-spinner loading-xs"></span>
        <% end %>
      </button>
    <% end %>
    """
  end

  attr(:ai_translate, :map, default: nil, doc: "Config map — see moduledoc.")

  @doc "Modal dialog: endpoint/prompt selectors + scope picker + action."
  def ai_translate_modal(assigns) do
    ~H"""
    <%= if modal_renderable?(@ai_translate) do %>
      <dialog id="ai-translation-modal" class={["modal", modal_open?(@ai_translate) && "modal-open"]}>
        <div class="modal-box max-w-lg">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-bold text-lg flex items-center gap-2">
              <Icon.icon name="hero-language" class="w-5 h-5 text-primary" />
              {gettext("AI Translation")}
            </h3>
            <button
              type="button"
              class="btn btn-sm btn-circle btn-ghost"
              phx-click={toggle_event_name(@ai_translate)}
              aria-label={gettext("Close")}
            >
              <Icon.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="space-y-4">
            <p class="text-sm text-base-content/70">
              {gettext(
                "Source: %{lang}. Each translation runs as a background job — you can keep editing while it finishes.",
                lang: source_lang_label(@ai_translate)
              )}
            </p>

            <div class="space-y-1">
              <form phx-change={get(@ai_translate, :select_endpoint_event)}>
                <label class="select select-sm w-full">
                  <select name="endpoint_uuid">
                    <option value="">{gettext("Select an endpoint...")}</option>
                    <%= for {id, name} <- ai_endpoints(@ai_translate) do %>
                      <option value={id} selected={get(@ai_translate, :selected_endpoint_uuid) == id}>
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
              <p class="flex items-start gap-1 text-xs text-base-content/60">
                <Icon.icon name="hero-information-circle" class="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  {gettext(
                    "Reasoning (\"thinking\") models are slower and may return unstructured output — a standard model is recommended for translation."
                  )}
                </span>
              </p>
            </div>

            <div class="space-y-1">
              <form phx-change={get(@ai_translate, :select_prompt_event)}>
                <label class="select select-sm w-full">
                  <select name="prompt_uuid">
                    <option value="">{gettext("Select a prompt...")}</option>
                    <%= for {id, name} <- ai_prompts(@ai_translate) do %>
                      <option value={id} selected={get(@ai_translate, :selected_prompt_uuid) == id}>
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
              <%= unless get(@ai_translate, :default_prompt_exists) == true do %>
                <button
                  type="button"
                  class="btn btn-outline btn-xs gap-1"
                  phx-click={get(@ai_translate, :generate_prompt_event)}
                >
                  <Icon.icon name="hero-sparkles" class="w-3 h-3" />
                  {gettext("Generate Default Prompt")}
                </button>
              <% end %>
            </div>

            <%= if has_in_flight?(@ai_translate) do %>
              <div class="alert alert-info py-2 text-xs gap-2">
                <span class="loading loading-spinner loading-xs"></span>
                <span>
                  {gettext("Translating to %{langs}…",
                    langs:
                      @ai_translate |> normalized_in_flight() |> Enum.map_join(", ", &String.upcase/1)
                  )}
                </span>
              </div>
            <% end %>

            <fieldset class="space-y-2">
              <legend class="text-sm font-medium">{gettext("Translate")}</legend>
              <%= for {value, label, disabled} <- scope_options(@ai_translate) do %>
                <label class={[
                  "flex items-start gap-2 cursor-pointer p-2 rounded hover:bg-base-200",
                  disabled && "opacity-50 cursor-not-allowed pointer-events-none"
                ]}>
                  <input
                    type="radio"
                    name="scope"
                    value={value}
                    class="radio radio-sm radio-primary mt-0.5"
                    checked={Atom.to_string(current_scope(@ai_translate)) == value}
                    disabled={disabled}
                    phx-click={if disabled, do: nil, else: get(@ai_translate, :select_scope_event)}
                    phx-value-scope={value}
                  />
                  <span class="text-sm leading-tight">{label}</span>
                </label>
              <% end %>
            </fieldset>

            <%= if current_scope(@ai_translate) == :all do %>
              <div class="alert alert-warning py-2 text-xs gap-2">
                <Icon.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
                <span>
                  {gettext(
                    "Existing translations in every non-primary language will be overwritten on completion."
                  )}
                </span>
              </div>
            <% end %>

            <div class="flex flex-wrap gap-3">
              <button
                type="button"
                class={[
                  "btn btn-primary btn-sm gap-1",
                  action_disabled?(@ai_translate) && "btn-disabled"
                ]}
                phx-click={event_name(@ai_translate)}
                phx-value-lang={scope_target(@ai_translate)}
                phx-disable-with={gettext("Starting…")}
                disabled={action_disabled?(@ai_translate)}
              >
                <Icon.icon name="hero-sparkles" class="w-4 h-4" />
                {action_label(@ai_translate)}
              </button>
            </div>
          </div>
        </div>
        <div class="modal-backdrop" phx-click={toggle_event_name(@ai_translate)}></div>
      </dialog>
    <% end %>
    """
  end

  attr(:ai_translate, :map,
    required: true,
    doc: "Same config map; reads translation_status/progress/total."
  )

  attr(:wrapper_class, :string, default: "flex-1 min-w-0")
  attr(:class, :string, default: "progress h-2 w-full block")

  @doc "Slim inline session progress bar. Renders once a dispatch has started."
  def ai_translate_progress(assigns) do
    ~H"""
    <%= if progress_visible?(@ai_translate) do %>
      <div class={@wrapper_class}>
        <progress
          class={[
            @class,
            translation_status(@ai_translate) == :completed && "progress-success",
            translation_status(@ai_translate) != :completed && "progress-primary"
          ]}
          value={translation_progress(@ai_translate)}
          max={max(translation_total(@ai_translate), 1)}
        >
        </progress>
      </div>
    <% end %>
    """
  end

  attr(:ai_translate, :map, default: nil, doc: "Same config map; reads `:slow` + `:in_flight`.")

  @doc """
  Reassurance line shown when a translation is taking a while (`slow: true`
  in the config while jobs are still in flight). A leading attention icon
  flags the line, then the visible message, then a trailing info icon whose
  tooltip carries the fuller "you can leave, nothing is lost" detail.
  Renders nothing otherwise.
  """
  def ai_translate_hint(assigns) do
    ~H"""
    <%= if hint_visible?(@ai_translate) do %>
      <div class="flex items-start gap-1.5 text-xs text-base-content/70 mt-1">
        <Icon.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning shrink-0 mt-px" />
        <span>
          {gettext(
            "This is taking longer than usual. Translations keep running in the background — you can safely leave this page."
          )}<span
            class="tooltip tooltip-top cursor-help align-middle ml-1 [--tooltip-max-width:20rem]"
            data-tip={
              gettext(
                "Each language is saved automatically the moment it finishes, so it's fine to navigate away or keep editing other fields — nothing will be lost."
              )
            }
          ><Icon.icon
              name="hero-information-circle"
              class="inline-block w-4 h-4 text-base-content/50"
            /></span>
        </span>
      </div>
    <% end %>
    """
  end

  attr(:multilang_enabled, :boolean, required: true)
  attr(:language_tabs, :list, required: true)
  attr(:current_lang, :string, required: true)
  attr(:compact, :boolean, default: nil)
  attr(:show_header, :boolean, default: true)
  attr(:show_info, :boolean, default: true)
  attr(:class, :string, default: "card-body pb-0")

  attr(:ai_translate, :map,
    default: nil,
    doc: "FormGlue config map; nil or disabled renders the tabs alone."
  )

  attr(:ai_row_class, :any,
    # Core's tabs wrap the switcher in a hardcoded mb-4; -mt-3 claws that
    # back to a tight 4px so the row reads as part of the tabs block. px-6
    # pairs with the default `class` ("card-body pb-0", which pads the tabs) —
    # the row is a SIBLING of that div, so it needs its own matching padding.
    default: "flex items-center gap-3 -mt-3 px-6",
    doc: """
    Class of the button/progress/hint row under the tabs. Tuned as a PAIR
    with `class`: replace `class` (e.g. with "" inside an already-padded
    container) and adjust this to match — typically dropping the px-6.
    """
  )

  @doc """
  Core's `<.multilang_tabs>` with the AI-translate row bundled underneath —
  the \"just enable it\" wrapper for the canonical placement every consumer
  was hand-building (a compact button/progress/hint row tucked under the
  tabs). Attrs mirror `PhoenixKitWeb.Components.MultilangForm.multilang_tabs/1`
  plus the `ai_translate` config map from `FormGlue.ai_translate_config/1`;
  when that is nil or disabled, the tabs render exactly as core's component
  alone would, so the attr is safe to pass unconditionally.

      <.ai_multilang_tabs
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
        ai_translate={FormGlue.ai_translate_config(assigns)}
      />

  The modal is NOT bundled — it carries its own selector `<form>`s and HTML
  forbids nesting, so keep `<.ai_translate_modal>` outside (after) the host's
  outer `</.form>` as before.

  Rendering alone is not enough: the config comes from the LV wiring —
  `use PhoenixKitAI.Components.AITranslate.Embed` (event/PubSub hooks) plus a
  `FormGlue.assign_ai_translation/4` call in mount with the consumer's
  `FormBinding`. Without it the config is nil and this renders tabs-only.

  `class` and `ai_row_class` defaults are tuned as a pair (the row is a
  sibling of the tabs div and pads itself to match `card-body`); override
  both together when embedding in a container that owns the padding.
  """
  def ai_multilang_tabs(assigns) do
    ~H"""
    <MultilangForm.multilang_tabs
      multilang_enabled={@multilang_enabled}
      language_tabs={@language_tabs}
      current_lang={@current_lang}
      compact={@compact}
      show_header={@show_header}
      show_info={@show_info}
      class={@class}
    />
    <%!-- Row visibility mirrors the tabs' own render condition — without it
      a single-language site (where core renders no tabs at all) would show
      the AI row floating alone with nothing to translate into. --%>
    <div
      :if={enabled?(@ai_translate) and @multilang_enabled and match?([_, _ | _], @language_tabs)}
      class={@ai_row_class}
    >
      <.ai_translate_button ai_translate={@ai_translate} />
      <.ai_translate_progress ai_translate={@ai_translate} />
      <.ai_translate_hint ai_translate={@ai_translate} />
    </div>
    """
  end

  # ─── Visibility / state helpers ────────────────────────────────

  defp hint_visible?(cfg) when is_map(cfg),
    do: enabled?(cfg) and get(cfg, :slow) == true and has_in_flight?(cfg)

  defp hint_visible?(_), do: false

  defp button_visible?(cfg) when is_map(cfg), do: enabled?(cfg) and toggle_event_name(cfg) != nil
  defp button_visible?(_), do: false

  defp modal_renderable?(cfg) when is_map(cfg),
    do: enabled?(cfg) and toggle_event_name(cfg) != nil

  defp modal_renderable?(_), do: false

  defp modal_open?(cfg), do: get(cfg, :modal_open) == true
  defp enabled?(cfg), do: get(cfg, :enabled) == true

  defp actionable_missing(cfg) do
    in_flight = normalized_in_flight(cfg)
    Enum.reject(normalized_missing(cfg), &(&1 in in_flight))
  end

  defp has_in_flight?(cfg), do: normalized_in_flight(cfg) != []

  defp translation_status(cfg) when is_map(cfg), do: get(cfg, :translation_status)
  defp translation_status(_), do: nil
  defp translation_progress(cfg) when is_map(cfg), do: get(cfg, :translation_progress) || 0
  defp translation_progress(_), do: 0
  defp translation_total(cfg) when is_map(cfg), do: get(cfg, :translation_total) || 0
  defp translation_total(_), do: 0

  defp progress_visible?(cfg) when is_map(cfg) do
    enabled?(cfg) and translation_status(cfg) in [:in_progress, :completed] and
      translation_total(cfg) > 0
  end

  defp progress_visible?(_), do: false

  defp normalized_missing(cfg),
    do: cfg |> get(:missing) |> List.wrap() |> Enum.map(&to_lang/1) |> Enum.reject(&is_nil/1)

  defp normalized_in_flight(cfg),
    do: cfg |> get(:in_flight) |> List.wrap() |> Enum.map(&to_lang/1) |> Enum.reject(&is_nil/1)

  defp to_lang(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp to_lang(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_lang(_), do: nil

  defp ai_endpoints(cfg), do: cfg |> get(:endpoints) |> List.wrap()
  defp ai_prompts(cfg), do: cfg |> get(:prompts) |> List.wrap()

  # ─── Scope picker ──────────────────────────────────────────────

  defp scope_options(cfg) do
    missing_count = length(actionable_missing(cfg))
    all_count = length(all_target_langs(cfg))
    current = get(cfg, :current_lang)

    [
      {"missing",
       gettext("Missing only (%{count} %{plural})",
         count: missing_count,
         plural: ngettext_plural(missing_count, "language", "languages")
       ), missing_count == 0},
      {"all",
       gettext("All non-primary languages (%{count}, overwrites existing)", count: all_count),
       all_count == 0},
      {"current",
       gettext("Current tab only (%{lang})",
         lang: if(is_binary(current), do: String.upcase(current), else: "—")
       ), not current_scope_available?(cfg)}
    ]
  end

  defp source_lang_label(cfg) do
    name = get(cfg, :primary_lang_name)
    code = get(cfg, :primary_lang)

    cond do
      is_binary(name) and String.trim(name) != "" -> name
      is_binary(code) and String.trim(code) != "" -> String.upcase(code)
      true -> gettext("the primary language")
    end
  end

  defp current_scope_available?(cfg) do
    current = get(cfg, :current_lang)
    primary = get(cfg, :primary_lang)
    is_binary(current) and current != "" and current != primary
  end

  defp all_target_langs(cfg) do
    primary = get(cfg, :primary_lang)

    cfg
    |> get(:all_langs)
    |> List.wrap()
    |> Enum.map(&to_lang/1)
    |> Enum.reject(&(is_nil(&1) or &1 == primary))
  end

  # The scope to actually act on: the configured one when it's enabled,
  # otherwise the first enabled option. Without this, the default `:missing`
  # strands the modal on a disabled radio + a disabled "Translate 0 missing"
  # button once everything's translated, even though "All non-primary" is
  # available. Drives the checked radio, the action label/target, and the
  # enabled state so the modal always offers a usable default.
  defp current_scope(cfg) do
    configured = configured_scope(cfg)
    opts = scope_options(cfg)

    if scope_disabled?(opts, configured) do
      first_enabled_scope(opts) || configured
    else
      configured
    end
  end

  defp configured_scope(cfg) do
    case get(cfg, :scope) do
      s when s in [:missing, "missing"] -> :missing
      s when s in [:all, "all"] -> :all
      s when s in [:current, "current"] -> :current
      _ -> :missing
    end
  end

  defp scope_disabled?(opts, scope) do
    Enum.any?(opts, fn {value, _label, disabled} ->
      value == Atom.to_string(scope) and disabled
    end)
  end

  defp first_enabled_scope(opts) do
    case Enum.find(opts, fn {_value, _label, disabled} -> not disabled end) do
      {value, _label, _disabled} -> String.to_existing_atom(value)
      nil -> nil
    end
  end

  defp scope_target(cfg) do
    case current_scope(cfg) do
      :missing -> "*"
      :all -> "**"
      :current -> get(cfg, :current_lang) || ""
    end
  end

  defp action_label(cfg) do
    case current_scope(cfg) do
      :missing ->
        gettext("Translate %{n} missing", n: length(actionable_missing(cfg)))

      :all ->
        gettext("Translate all %{n} languages", n: length(all_target_langs(cfg)))

      :current ->
        gettext("Translate to %{lang}", lang: String.upcase(get(cfg, :current_lang) || ""))
    end
  end

  defp action_disabled?(cfg) do
    blank?(get(cfg, :selected_endpoint_uuid)) or blank?(get(cfg, :selected_prompt_uuid)) or
      has_in_flight?(cfg) or scope_empty?(cfg)
  end

  defp scope_empty?(cfg) do
    case current_scope(cfg) do
      :missing -> actionable_missing(cfg) == []
      :all -> all_target_langs(cfg) == []
      :current -> not current_scope_available?(cfg)
    end
  end

  defp ngettext_plural(1, sing, _plur), do: sing
  defp ngettext_plural(_, _sing, plur), do: plur

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  defp event_name(cfg), do: trimmed_event(cfg, :event)
  defp toggle_event_name(cfg), do: trimmed_event(cfg, :toggle_event)

  defp trimmed_event(cfg, key) do
    case get(cfg, key) do
      ev when is_binary(ev) -> if String.trim(ev) == "", do: nil, else: ev
      _ -> nil
    end
  end

  defp get(cfg, key) when is_map(cfg) and is_atom(key) do
    case Map.fetch(cfg, key) do
      {:ok, v} -> v
      :error -> Map.get(cfg, Atom.to_string(key))
    end
  end

  defp get(_, _), do: nil
end
