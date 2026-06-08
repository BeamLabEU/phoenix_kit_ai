defmodule PhoenixKitAI.Components.AITranslate.FormGlue do
  @moduledoc """
  Shared LiveView glue for the AI-translate modal — the stateful counterpart
  to the render-only `PhoenixKitAI.Components.AITranslate` components.

  Owns the whole modal/progress/stall state machine so consumers (catalogue,
  projects, …) don't each re-implement it:

    * mount state + per-resource PubSub subscription (`assign_ai_translation/4`)
    * modal open/close, endpoint/prompt/scope selection, generate-default-prompt
    * scope-driven dispatch (missing `"*"` / overwrite `"**"` / single tab)
      via core `PhoenixKitAI.Translations`
    * live progress + a STALL hint ("taking a while…") driven by a per-arm
      timer that fires only when no language completes for `ai_stall_ms/0`
    * folding `{:ai_translation, _, _}` PubSub events back into the form

  The only storage-specific behaviour — which langs already have a translation,
  how to merge a completed translation into the live changeset, and who the
  actor is — is supplied by a `PhoenixKitAI.Components.AITranslate.FormBinding`
  module, passed once at mount.

  ## Host wiring (thin)

      use Gettext, ...
      alias PhoenixKitAI.Components.AITranslate.FormGlue

      # mount/3 (on :edit pass the resource, on :new pass nil)
      |> FormGlue.assign_ai_translation("project", project_or_nil, MyApp.AITranslateBinding)

      # one config call feeds button + modal + progress + hint
      <.ai_translate_button ai_translate={FormGlue.ai_translate_config(assigns)} />

      # six thin handle_event clauses delegate to:
      #   toggle_ai_modal/1, select_ai_endpoint/2, select_ai_prompt/2,
      #   select_ai_scope/2, generate_ai_prompt/1, dispatch_ai_translate/2

      # one handle_info:
      def handle_info({:ai_translation, event, payload}, socket),
        do: {:noreply, FormGlue.handle_ai_translation_event(socket, event, payload, &assign_form/2)}

  `assign_form/2` (the 4th arg to `handle_ai_translation_event/4`) is the LV's
  own `(socket, changeset) -> socket` helper — the glue uses it to re-assign
  the patched changeset so the LV's exact form-sync behaviour is preserved.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitAI.Translations
  alias PhoenixKit.Utils.Multilang

  # How long the progress bar may STALL — no language completing — before the
  # "taking a while, runs in the background" hint shows. About the bar hanging,
  # not any single language's duration. Each completion resets the clock.
  # Overridable via `config :phoenix_kit, :ai_translation_stall_ms`.
  @default_ai_stall_ms 5_000

  defp ai_stall_ms do
    Application.get_env(:phoenix_kit, :ai_translation_stall_ms, @default_ai_stall_ms)
  end

  @doc """
  Assign the AI-translate mount state and (on the connected mount of an
  existing resource) subscribe to its core translation topic.

  Pass the resource struct on `:edit`; pass `nil` on `:new`. `resource_type`
  is the key registered via `ai_translatables/0`; `binding` is the consumer's
  `FormBinding` module.
  """
  @spec assign_ai_translation(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          struct() | nil,
          module()
        ) :: Phoenix.LiveView.Socket.t()
  def assign_ai_translation(socket, resource_type, %{uuid: uuid} = _resource, binding)
      when is_binary(resource_type) and is_binary(uuid) and is_atom(binding) do
    available? = Translations.available?()

    if available? and Phoenix.LiveView.connected?(socket) do
      Translations.subscribe(resource_type, uuid)
    end

    socket
    |> Phoenix.Component.assign(
      ai_form_binding: binding,
      ai_resource_type: resource_type,
      ai_resource_uuid: uuid,
      ai_translation_available?: available?,
      ai_in_flight: [],
      ai_scope: :missing,
      ai_modal_open: false,
      ai_status: nil,
      ai_progress: 0,
      ai_total: 0,
      ai_slow: false,
      ai_slow_timer_ref: nil,
      ai_slow_token: nil
    )
    |> assign_endpoint_prompt_state(available?)
  end

  def assign_ai_translation(socket, _resource_type, _resource, binding) do
    Phoenix.Component.assign(socket,
      ai_form_binding: binding,
      ai_resource_type: nil,
      ai_resource_uuid: nil,
      ai_translation_available?: false,
      ai_in_flight: [],
      ai_scope: :missing,
      ai_modal_open: false,
      ai_status: nil,
      ai_progress: 0,
      ai_total: 0,
      ai_slow: false,
      ai_slow_timer_ref: nil,
      ai_slow_token: nil,
      ai_endpoints: [],
      ai_prompts: [],
      ai_selected_endpoint: nil,
      ai_selected_prompt: nil,
      ai_default_prompt_exists: false
    )
  end

  # The endpoint/prompt lookups hit Settings + the AI plugin, so only run them
  # on the connected mount (the dead HTTP render doesn't need them, and mount/3
  # fires twice).
  defp assign_endpoint_prompt_state(socket, true) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.Component.assign(socket,
        ai_endpoints: Translations.list_endpoints(),
        ai_prompts: Translations.list_prompts(),
        ai_selected_endpoint: Translations.default_endpoint_uuid(),
        ai_selected_prompt: Translations.default_prompt_uuid(),
        ai_default_prompt_exists: Translations.default_prompt_exists?()
      )
    else
      empty_endpoint_prompt_state(socket)
    end
  end

  defp assign_endpoint_prompt_state(socket, _false), do: empty_endpoint_prompt_state(socket)

  defp empty_endpoint_prompt_state(socket) do
    Phoenix.Component.assign(socket,
      ai_endpoints: [],
      ai_prompts: [],
      ai_selected_endpoint: nil,
      ai_selected_prompt: nil,
      ai_default_prompt_exists: false
    )
  end

  @doc "Modal open/close toggle."
  def toggle_ai_modal(socket),
    do: Phoenix.Component.assign(socket, :ai_modal_open, not socket.assigns.ai_modal_open)

  @doc "Endpoint dropdown change."
  def select_ai_endpoint(socket, uuid),
    do: Phoenix.Component.assign(socket, :ai_selected_endpoint, blank_to_nil(uuid))

  @doc "Prompt dropdown change."
  def select_ai_prompt(socket, uuid),
    do: Phoenix.Component.assign(socket, :ai_selected_prompt, blank_to_nil(uuid))

  @doc "Scope radio change (`missing` | `all` | `current`)."
  def select_ai_scope(socket, scope) when scope in ~w(missing all current),
    do: Phoenix.Component.assign(socket, :ai_scope, String.to_existing_atom(scope))

  def select_ai_scope(socket, _scope), do: socket

  @doc "Provision the shared default translation prompt and select it."
  def generate_ai_prompt(socket) do
    case Translations.ensure_default_prompt() do
      {:ok, %{uuid: uuid}} ->
        socket
        |> Phoenix.Component.assign(:ai_prompts, Translations.list_prompts())
        |> Phoenix.Component.assign(:ai_default_prompt_exists, true)
        |> Phoenix.Component.assign(:ai_selected_prompt, uuid)
        |> Phoenix.LiveView.put_flash(:info, gettext("Default translation prompt generated."))

      {:error, _reason} ->
        flash_error(socket, gettext("Could not generate the default translation prompt."))
    end
  end

  @doc """
  Build the `ai_translate` config map for the `AITranslate` components from the
  form's assigns, or `nil` when AI translation isn't available. The `missing`
  list comes from the binding (live changeset), so it reflects unsaved +
  just-translated state.
  """
  @spec ai_translate_config(map()) :: map() | nil
  def ai_translate_config(assigns) do
    if assigns[:ai_translation_available?] do
      %{
        enabled: true,
        event: "ai_translate_lang",
        toggle_event: "ai_toggle_modal",
        select_endpoint_event: "ai_select_endpoint",
        select_prompt_event: "ai_select_prompt",
        select_scope_event: "ai_select_scope",
        generate_prompt_event: "ai_generate_prompt",
        missing: missing_langs(assigns),
        all_langs: all_target_langs(),
        in_flight: assigns.ai_in_flight,
        modal_open: assigns.ai_modal_open,
        endpoints: assigns.ai_endpoints,
        prompts: assigns.ai_prompts,
        selected_endpoint_uuid: assigns.ai_selected_endpoint,
        selected_prompt_uuid: assigns.ai_selected_prompt,
        scope: assigns.ai_scope,
        default_prompt_exists: assigns.ai_default_prompt_exists,
        current_lang: assigns[:current_lang],
        primary_lang: Multilang.primary_language(),
        primary_lang_name: lang_name(assigns[:language_tabs], Multilang.primary_language()),
        translation_status: assigns.ai_status,
        translation_progress: assigns.ai_progress,
        translation_total: assigns.ai_total,
        slow: assigns.ai_slow
      }
    end
  end

  defp lang_name(tabs, code) do
    case Enum.find(tabs || [], &(&1.code == code)) do
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc """
  Dispatch a translation from the modal's "Translate" action. `lang` is the
  scope sentinel: `"*"` (missing only), `"**"` (all non-primary, overwrite),
  or a concrete language code (current tab). Closes the modal, grows
  `:ai_in_flight`, advances the progress session, and flashes the outcome.
  """
  @spec dispatch_ai_translate(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def dispatch_ai_translate(socket, lang) do
    socket = Phoenix.Component.assign(socket, :ai_modal_open, false)
    endpoint = socket.assigns.ai_selected_endpoint || Translations.default_endpoint_uuid()
    prompt = socket.assigns.ai_selected_prompt || Translations.default_prompt_uuid()

    cond do
      blank_to_nil(endpoint) == nil ->
        flash_error(socket, gettext("Select an AI endpoint first."))

      blank_to_nil(prompt) == nil ->
        flash_error(socket, gettext("Select a translation prompt first."))

      true ->
        do_dispatch_ai(socket, lang, endpoint, prompt)
    end
  end

  # Bulk scopes: "*" (missing) / "**" (all non-primary).
  defp do_dispatch_ai(socket, scope, endpoint, prompt) when scope in ["*", "**"] do
    targets =
      case scope do
        "*" -> missing_langs(socket.assigns)
        "**" -> all_target_langs()
      end
      |> Enum.reject(&(&1 in socket.assigns.ai_in_flight))

    base = %{
      resource_type: socket.assigns.ai_resource_type,
      resource_uuid: socket.assigns.ai_resource_uuid,
      endpoint_uuid: endpoint,
      prompt_uuid: prompt,
      source_lang: Multilang.primary_language(),
      actor_uuid: actor_uuid(socket)
    }

    case Translations.enqueue_all_missing(base, targets) do
      {:ok, %{in_flight: [_ | _] = in_flight, errors: errors}} ->
        socket
        |> add_in_flight(in_flight)
        |> bump_started(length(in_flight))
        |> dispatch_flash(in_flight, errors)

      {:ok, %{errors: [_ | _] = errors}} ->
        dispatch_flash(socket, [], errors)

      {:ok, _} ->
        Phoenix.LiveView.put_flash(socket, :info, gettext("Nothing to translate."))

      {:error, _reason} ->
        flash_error(socket, gettext("Could not start translation."))
    end
  end

  # A stale/crafted empty target — no-op.
  defp do_dispatch_ai(socket, lang, _endpoint, _prompt)
       when is_binary(lang) and lang == "",
       do: socket

  # Single language (current tab). Refuse to translate INTO the source.
  defp do_dispatch_ai(socket, lang, endpoint, prompt) do
    if lang == Multilang.primary_language() do
      flash_error(socket, gettext("Can't translate the source language."))
    else
      do_dispatch_single(socket, lang, endpoint, prompt)
    end
  end

  defp do_dispatch_single(socket, lang, endpoint, prompt) do
    params = %{
      resource_type: socket.assigns.ai_resource_type,
      resource_uuid: socket.assigns.ai_resource_uuid,
      endpoint_uuid: endpoint,
      prompt_uuid: prompt,
      source_lang: Multilang.primary_language(),
      target_lang: lang,
      actor_uuid: actor_uuid(socket)
    }

    case Translations.enqueue(params) do
      {:ok, %{conflict?: false}} ->
        socket
        |> add_in_flight([lang])
        |> bump_started(1)
        |> Phoenix.LiveView.put_flash(
          :info,
          gettext("Translating to %{lang}…", lang: String.upcase(lang))
        )

      {:ok, %{conflict?: true}} ->
        Phoenix.LiveView.put_flash(socket, :info, gettext("Translation already in progress."))

      {:error, _reason} ->
        flash_error(socket, gettext("Could not start translation."))
    end
  end

  defp add_in_flight(socket, langs),
    do:
      Phoenix.Component.assign(
        socket,
        :ai_in_flight,
        Enum.uniq(socket.assigns.ai_in_flight ++ langs)
      )

  # Progress session: reset on a fresh start, add to a running total.
  defp bump_started(socket, count) when count > 0 do
    socket = arm_stall_timer(socket)

    case socket.assigns.ai_status do
      s when s in [nil, :completed] ->
        Phoenix.Component.assign(socket,
          ai_status: :in_progress,
          ai_progress: 0,
          ai_total: count,
          ai_slow: false
        )

      :in_progress ->
        Phoenix.Component.assign(socket, :ai_total, socket.assigns.ai_total + count)
    end
  end

  defp bump_started(socket, _zero), do: socket

  # (Re)start the stall clock: cancel any pending timer, schedule a fresh one,
  # clear the hint. Called at dispatch AND after each completion so the timer
  # only fires when progress has STALLED for `ai_stall_ms/0`.
  defp arm_stall_timer(socket) do
    socket = cancel_stall_timer(socket)

    # A per-arm token guards against a stale `:slow_tick` already delivered to
    # the mailbox before `cancel_stall_timer/1` ran (cancel can't un-send it).
    token = make_ref()

    ref =
      if Phoenix.LiveView.connected?(socket) do
        Process.send_after(self(), {:ai_translation, :slow_tick, %{token: token}}, ai_stall_ms())
      end

    Phoenix.Component.assign(socket,
      ai_slow_timer_ref: ref,
      ai_slow_token: token,
      ai_slow: false
    )
  end

  defp cancel_stall_timer(socket) do
    case socket.assigns[:ai_slow_timer_ref] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    Phoenix.Component.assign(socket, ai_slow_timer_ref: nil, ai_slow_token: nil)
  end

  defp missing_langs(assigns) do
    binding = assigns.ai_form_binding

    Translations.missing_languages(
      Multilang.enabled_languages(),
      Multilang.primary_language(),
      binding.existing_translation_langs(assigns.ai_resource_type, assigns)
    )
  end

  defp all_target_langs do
    primary = Multilang.primary_language()
    Enum.reject(Multilang.enabled_languages(), &(&1 == primary))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp actor_uuid(socket), do: socket.assigns.ai_form_binding.actor_uuid(socket)

  defp dispatch_flash(socket, in_flight, errors) do
    cond do
      in_flight == [] and errors != [] ->
        flash_error(socket, gettext("Translation could not be started."))

      errors != [] ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          ngettext(
            "Translating %{count} language; some could not start.",
            "Translating %{count} languages; some could not start.",
            length(in_flight)
          )
        )

      true ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          ngettext(
            "Translating %{count} language…",
            "Translating %{count} languages…",
            length(in_flight)
          )
        )
    end
  end

  @doc """
  Fold a `{:ai_translation, event, payload}` message into the form socket.

  `assign_cs` is the LV's own `(socket, changeset) -> socket` helper — on
  `:translation_completed` the binding merges the translated fields into the
  live changeset and `assign_cs` re-assigns it (so the result shows without a
  DB reload and unsaved edits survive). Returns the updated socket.
  """
  @spec handle_ai_translation_event(
          Phoenix.LiveView.Socket.t(),
          atom(),
          map(),
          (Phoenix.LiveView.Socket.t(), Ecto.Changeset.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def handle_ai_translation_event(socket, :translation_started, %{target_lang: lang}, _assign_cs)
      when is_binary(lang) do
    if lang in socket.assigns.ai_in_flight do
      # Our own dispatch already added it + sized the progress session.
      socket
    else
      # A job started elsewhere (another session/tab on this resource). Track
      # it AND grow the session so a later completion can't push past total.
      socket
      |> add_in_flight([lang])
      |> bump_started(1)
    end
  end

  def handle_ai_translation_event(socket, :translation_completed, payload, assign_cs) do
    lang = payload[:target_lang]
    fields = payload[:fields] || %{}

    # No per-language flash — with many languages that's dozens of toasts. The
    # progress bar + the field filling in carry the signal.
    socket
    |> maybe_apply_translation(lang, fields, assign_cs)
    |> mark_lang_done(lang)
  end

  def handle_ai_translation_event(socket, :translation_failed, payload, _assign_cs) do
    lang = payload[:target_lang]

    socket
    |> mark_lang_done(lang)
    |> Phoenix.LiveView.put_flash(:error, ai_failed_flash(lang))
  end

  # Stall timer landed: no language completed for `ai_stall_ms/0` — show the
  # "taking a while" reassurance, but only if something's still running and the
  # tick isn't a stale one from a superseded clock.
  def handle_ai_translation_event(socket, :slow_tick, payload, _assign_cs) do
    cond do
      socket.assigns.ai_in_flight == [] -> socket
      payload[:token] != socket.assigns[:ai_slow_token] -> socket
      true -> Phoenix.Component.assign(socket, :ai_slow, true)
    end
  end

  def handle_ai_translation_event(socket, _event, _payload, _assign_cs), do: socket

  defp maybe_apply_translation(socket, lang, fields, assign_cs)
       when is_binary(lang) and map_size(fields) > 0 do
    binding = socket.assigns.ai_form_binding
    cs = socket.assigns.form.source
    new_cs = binding.apply_translation(socket.assigns.ai_resource_type, cs, lang, fields)
    assign_cs.(socket, new_cs)
  end

  defp maybe_apply_translation(socket, _lang, _fields, _assign_cs), do: socket

  # Terminal lifecycle for a language: drop from in-flight, advance progress,
  # flip to :completed when nothing's left. No-op for a stale/duplicate event.
  defp mark_lang_done(socket, lang) when is_binary(lang) do
    in_flight = socket.assigns.ai_in_flight

    if lang in in_flight do
      new_in_flight = in_flight -- [lang]
      # Clamp to total — defends the bar against any started/completed skew.
      progress = min((socket.assigns.ai_progress || 0) + 1, socket.assigns.ai_total)
      status = if new_in_flight == [], do: :completed, else: :in_progress

      socket =
        Phoenix.Component.assign(socket,
          ai_in_flight: new_in_flight,
          ai_progress: progress,
          ai_status: status
        )

      # Progress advanced: restart the stall clock (hide the hint) if more
      # remain, or cancel it entirely once the batch is done.
      if new_in_flight == [],
        do: socket |> cancel_stall_timer() |> Phoenix.Component.assign(:ai_slow, false),
        else: arm_stall_timer(socket)
    else
      socket
    end
  end

  defp mark_lang_done(socket, _lang), do: socket

  defp ai_failed_flash(lang) when is_binary(lang),
    do: gettext("Translation failed for %{lang}.", lang: String.upcase(lang))

  defp ai_failed_flash(_), do: gettext("Translation failed.")

  defp flash_error(socket, msg), do: Phoenix.LiveView.put_flash(socket, :error, msg)
end
