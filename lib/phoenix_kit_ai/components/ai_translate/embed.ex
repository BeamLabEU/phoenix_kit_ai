defmodule PhoenixKitAI.Components.AITranslate.Embed do
  @moduledoc """
  Host-side wiring for the AI-translate modal — `use` this in a form
  LiveView and it injects the boilerplate that every consumer of
  `PhoenixKitAI.Components.AITranslate.FormGlue` was hand-duplicating:

    * the six `handle_event` clauses that delegate the modal's button
      clicks (`ai_toggle_modal`, `ai_select_endpoint`, `ai_select_prompt`,
      `ai_select_scope`, `ai_generate_prompt`, `ai_translate_lang`) to the
      matching `FormGlue` helpers, and
    * the `handle_info({:ai_translation, event, payload}, socket)` clause
      that folds PubSub progress/result events back into the form.

  Forgetting any of these is a silent failure: the modal renders, but
  translations never run, progress never updates, or the form never
  re-syncs with the result. The macro makes that impossible to forget.

  ## Usage

      use MyAppWeb, :live_view
      use PhoenixKitAI.Components.AITranslate.Embed

      # still call this yourself in mount/apply_action — the resource is
      # dynamic (the loaded record on :edit, nil on :new):
      |> FormGlue.assign_ai_translation("project", project_or_nil, MyBinding)

      # render the button/progress/hint/modal from FormGlue.ai_translate_config(assigns)

  ## How it composes

  The handlers are attached as `:handle_event` / `:handle_info` lifecycle
  hooks via `on_mount`, so they **compose** with the form's own
  `handle_event`/`handle_info` clauses — no clause-grouping warning, no
  clobbering. Non-AI events/messages pass straight through
  (`{:cont, socket}`); the AI ones are handled and halted. Mirrors the
  lifecycle-hook approach in `PhoenixKitWeb.Components.MediaBrowser.Embed`
  and `PhoenixKitComments.Embed`.

  Lifecycle hooks run *before* the LiveView's own callbacks, and the AI
  hooks `:halt` on the events/messages they own. So a host that also
  defines `handle_info({:ai_translation, _, _}, socket)` (or one of the
  six `ai_*` `handle_event` clauses) will find that clause **shadowed** —
  the hook handles and halts first, the host clause never fires. There is
  no double-handling; just don't re-implement the AI clauses in the host.

  ## Form re-sync

  After a translation merges into the live changeset, the form must be
  re-assigned. The default sets both `:changeset` and `:form`
  (`assign(socket, changeset: cs, form: to_form(cs))`) — the superset
  that fits every current consumer. A host whose sync differs can define
  `ai_translate_assign_form/2` (`(socket, changeset) -> socket`); the hook
  uses it when present.
  """

  alias PhoenixKitAI.Components.AITranslate.FormGlue

  defmacro __using__(_opts) do
    quote do
      on_mount(PhoenixKitAI.Components.AITranslate.Embed)
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.LiveView.attach_hook(
        :phoenix_kit_ai_translate_events,
        :handle_event,
        &__handle_event__/3
      )
      |> Phoenix.LiveView.attach_hook(
        :phoenix_kit_ai_translate_info,
        :handle_info,
        &__handle_info__/2
      )

    {:cont, socket}
  end

  @doc false
  def __handle_event__("ai_translate_lang", %{"lang" => lang}, socket),
    do: {:halt, FormGlue.dispatch_ai_translate(socket, lang)}

  def __handle_event__("ai_toggle_modal", _params, socket),
    do: {:halt, FormGlue.toggle_ai_modal(socket)}

  def __handle_event__("ai_select_endpoint", %{"endpoint_uuid" => uuid}, socket),
    do: {:halt, FormGlue.select_ai_endpoint(socket, uuid)}

  def __handle_event__("ai_select_prompt", %{"prompt_uuid" => uuid}, socket),
    do: {:halt, FormGlue.select_ai_prompt(socket, uuid)}

  def __handle_event__("ai_select_scope", %{"scope" => scope}, socket),
    do: {:halt, FormGlue.select_ai_scope(socket, scope)}

  def __handle_event__("ai_generate_prompt", _params, socket),
    do: {:halt, FormGlue.generate_ai_prompt(socket)}

  def __handle_event__(_event, _params, socket), do: {:cont, socket}

  @doc false
  def __handle_info__({:ai_translation, event, payload}, socket) do
    {:halt, FormGlue.handle_ai_translation_event(socket, event, payload, &resync_form/2)}
  end

  def __handle_info__(_msg, socket), do: {:cont, socket}

  # Re-assign the form after a translation patches the changeset. Honors a
  # host-defined `ai_translate_assign_form/2` override; otherwise sets both
  # `:changeset` and `:form`.
  defp resync_form(socket, changeset) do
    view = socket.view

    if is_atom(view) and function_exported?(view, :ai_translate_assign_form, 2) do
      view.ai_translate_assign_form(socket, changeset)
    else
      socket
      |> Phoenix.Component.assign(:changeset, changeset)
      |> Phoenix.Component.assign(:form, Phoenix.Component.to_form(changeset))
    end
  end
end
