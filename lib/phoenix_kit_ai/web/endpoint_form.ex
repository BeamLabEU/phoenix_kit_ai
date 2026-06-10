defmodule PhoenixKitAI.Web.EndpointForm do
  @moduledoc """
  LiveView for creating and editing AI endpoints.

  An endpoint combines provider credentials, model selection, and generation
  parameters into a single configuration.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events, as: IntegrationEvents
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.OpenRouterClient
  alias PhoenixKitAI.Web.AuthHelpers

  # ===========================================
  # FUNCTION COMPONENTS
  # ===========================================

  attr(:key, :string, required: true)
  attr(:definition, :map, required: true)
  attr(:form, :map, required: true)
  attr(:endpoint, :any, default: nil)
  attr(:selected_model, :map, default: nil)
  attr(:size, :string, default: "md")

  def param_input(assigns) do
    field = assigns.definition.field
    field_str = Atom.to_string(field)
    current_value = resolve_current_value(assigns, field, field_str)

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:field_str, field_str)
      |> assign(:current_value, current_value)
      |> assign(:input_class, size_class(assigns.size, "input"))
      |> assign(:textarea_class, size_class(assigns.size, "textarea"))

    ~H"""
    <div class="form-control">
      <label class="label">
        <span class={if @size == "sm", do: "label-text", else: "label-text font-medium"}>
          {@definition.label}
        </span>
      </label>

      <%= case @definition.type do %>
        <% :float -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            step={@definition[:step] || 0.1}
            min={@definition[:min]}
            max={@definition[:max]}
            placeholder={@definition[:placeholder]}
          />
        <% :integer -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            min={@definition[:min]}
            max={get_max_for_field(@field_str, @definition, @selected_model)}
            placeholder={get_placeholder_for_field(@field_str, @definition, @selected_model)}
          />
        <% :string_list -> %>
          <textarea
            name={"endpoint[#{@field_str}]"}
            class={@textarea_class}
            rows="2"
            placeholder={@definition[:placeholder] || "One per line"}
          >{@current_value}</textarea>
        <% _ -> %>
          <input
            type="text"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            placeholder={@definition[:placeholder]}
          />
      <% end %>
    </div>
    """
  end

  attr(:model, :map, required: true)
  attr(:selected, :boolean, required: true)
  attr(:show_clear, :boolean, default: false)

  @doc """
  Renders a single model option as a clickable card with name, ID,
  context-length / max-output badges, and prompt / completion pricing.

  The same card is used in two places:

  * **Inside the model grid** — the operator's browse surface. Click
    selects. The currently-selected card is excluded from the grid
    (it's hoisted to the top — see below) so each model appears in
    exactly one location.
  * **Hoisted above the grid as the "Current Model"** — when
    `@selected_model` is set, the card moves out of the grid to the
    top of the section. `show_clear: true` adds an "X" button that
    deselects (drops the card back into the grid). Clicking the
    card body itself is a no-op (selecting an already-selected
    model has no effect).

  This keeps a single source of truth for the rich model display —
  badges + pricing — instead of duplicating the layout between a
  separate summary panel and the grid.
  """
  def model_card(assigns) do
    pricing = assigns.model.pricing || %{}

    assigns =
      assigns
      |> assign(:prompt_price, format_price(pricing["prompt"]))
      |> assign(:completion_price, format_price(pricing["completion"]))

    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="select_model"
        phx-value-model={@model.id}
        data-search-text={String.downcase("#{@model.name || ""} #{@model.id}")}
        class={
          "relative rounded-lg border p-3 transition-colors cursor-pointer text-left w-full " <>
            "[&.phx-click-loading]:pointer-events-none [&.phx-click-loading]:opacity-60 " <>
            if(@show_clear, do: "pr-10 ", else: "") <>
            if @selected do
              "border-primary bg-primary/10 ring-2 ring-primary/20"
            else
              "border-base-300 bg-base-200 hover:border-primary hover:bg-base-100"
            end
        }
      >
        <%!-- Spinner overlay during in-flight click. Hidden by default;
             revealed when Phoenix's `.phx-click-loading` class lands on
             the parent button. Pointer-events-none on the parent stops
             repeat clicks while it's spinning. --%>
        <span class="hidden [.phx-click-loading_&]:flex absolute inset-0 items-center justify-center bg-base-100/40 rounded-lg z-10">
          <span class="loading loading-spinner loading-sm"></span>
        </span>
        <div class="min-w-0">
          <div class="font-semibold truncate">
            {@model.name || @model.id}
          </div>

          <div class="text-xs font-mono text-base-content/50 truncate">
            {@model.id}
          </div>

          <div class="flex flex-wrap gap-1 mt-2">
            <span :if={@model.context_length} class="badge badge-outline badge-xs h-auto">
              {format_number(@model.context_length)} ctx
            </span>

            <span :if={@model.max_completion_tokens} class="badge badge-outline badge-xs h-auto">
              {format_number(@model.max_completion_tokens)} out
            </span>

            <span :if={@prompt_price} class="badge badge-success badge-outline badge-xs h-auto">
              {@prompt_price}/M in
            </span>

            <span :if={@completion_price} class="badge badge-warning badge-outline badge-xs h-auto">
              {@completion_price}/M out
            </span>
          </div>
        </div>
      </button>

      <%!-- Clear button overlay — only present on the hoisted card
           at the top. The button sits outside the main click target
           (which would itself trigger `select_model` on the same
           id, a no-op). Anchored to the top-right corner; the
           `right-10` offset from the pre-drop check-icon layout is
           gone now that the check icon was removed. --%>
      <button
        :if={@show_clear}
        type="button"
        phx-click="clear_model"
        phx-disable-with={gettext("…")}
        class="btn btn-ghost btn-sm btn-square absolute top-2 right-2 [&.phx-click-loading]:pointer-events-none"
        aria-label={gettext("Clear model")}
        title={gettext("Clear model")}
      >
        <.icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  defp resolve_current_value(assigns, field, field_str) do
    value =
      assigns.form.params[field_str] ||
        (assigns.endpoint && Map.get(assigns.endpoint, field)) ||
        assigns.definition[:default] ||
        ""

    case {assigns.definition.type, value} do
      {:string_list, list} when is_list(list) -> Enum.join(list, "\n")
      _ -> value
    end
  end

  defp size_class("sm", "input"), do: "input input-bordered input-sm"
  defp size_class(_, "input"), do: "input input-bordered"
  defp size_class("sm", "textarea"), do: "textarea textarea-bordered textarea-sm"
  defp size_class(_, "textarea"), do: "textarea textarea-bordered"

  defp get_max_for_field("max_tokens", _definition, selected_model) do
    selected_model && selected_model.max_completion_tokens
  end

  defp get_max_for_field(_field, definition, _selected_model) do
    definition[:max]
  end

  defp get_placeholder_for_field("max_tokens", _definition, selected_model) do
    if selected_model && selected_model.max_completion_tokens do
      "Max: #{selected_model.max_completion_tokens}"
    else
      "Model default"
    end
  end

  defp get_placeholder_for_field(_field, definition, _selected_model) do
    definition[:placeholder]
  end

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount/3 — they run twice. The `enabled?` check,
    # integration listing, and endpoint load all happen in
    # `handle_params/3`.
    if connected?(socket), do: IntegrationEvents.subscribe()

    socket =
      socket
      |> assign(:project_title, nil)
      |> assign(:current_path, Routes.path("/admin/ai"))
      |> assign(:provider_connections, [])
      |> assign(:provider_options, Endpoint.provider_options())
      |> assign(:current_provider, "openrouter")
      |> assign(:models, [])
      |> assign(:models_grouped, [])
      |> assign(:models_loading, false)
      |> assign(:models_loading_slow, false)
      |> assign(:model_fetch_slow_timer, nil)
      |> assign(:models_error, nil)
      |> assign(:selected_model, nil)
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])
      |> assign(:model_type, :text)
      |> assign(:endpoint, nil)
      |> assign(:active_connection, nil)
      |> assign(:selected_uuids, [])
      |> assign(:integration_connected, false)
      |> assign(:form, to_form(AI.change_endpoint(%Endpoint{})))
      |> assign(:page_title, "AI Endpoint")
      |> assign(:loaded_id, :unloaded)

    {:ok, socket}
  end

  defp load_endpoint(socket, nil) do
    # New endpoint: nothing is pre-selected. The picker reflects the
    # endpoint's actual state (no integration yet), so the operator
    # explicitly picks one. Auto-selecting a single available connection
    # would mask "no integration set" with "an integration is set" and
    # confuse anyone scanning the form to verify wiring.
    socket
    |> assign(:page_title, "New AI Endpoint")
    |> assign(:endpoint, nil)
    |> assign(:form, to_form(AI.change_endpoint(%Endpoint{})))
    |> assign(:active_connection, nil)
    |> assign(:selected_uuids, [])
    |> assign(:integration_connected, false)
  end

  defp load_endpoint(socket, id) do
    case AI.get_endpoint(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Endpoint not found"))
        |> push_navigate(to: PhoenixKitAI.Routes.ai_path())

      endpoint ->
        changeset = AI.change_endpoint(endpoint)
        connections = socket.assigns.provider_connections

        {active, orphaned_integration_uuid} = resolve_active_connection(endpoint, connections)
        connected = active && Integrations.connected?(active)
        selected_uuids = picker_selected_uuids(active, orphaned_integration_uuid)

        socket
        |> assign(:page_title, "Edit AI Endpoint")
        |> assign(:endpoint, endpoint)
        |> assign(:form, to_form(changeset))
        |> assign(:active_connection, active)
        |> assign(:selected_uuids, selected_uuids)
        |> assign(:integration_connected, connected)
        |> assign(:current_provider, endpoint.provider)
        |> assign(:model_type, model_type_for(endpoint.model))
        |> maybe_fetch_models_on_load(connected)
    end
  end

  # Resolves the picker's `active_connection` from the endpoint's
  # `integration_uuid`. Falls back to the legacy `provider` field (which
  # carried the uuid before the dedicated column existed) so endpoints
  # that pre-date V107's backfill still light up the right picker entry.
  #
  # The picker reflects the endpoint's actual stored state — it never
  # auto-picks a connection the endpoint isn't pinned to. When
  # `integration_uuid` is set but unresolvable, the orphan uuid is
  # returned so the picker renders its "Integration deleted" warning.
  defp resolve_active_connection(endpoint, connections) do
    cond do
      endpoint.integration_uuid &&
          Enum.any?(connections, &(&1.uuid == endpoint.integration_uuid)) ->
        {endpoint.integration_uuid, nil}

      endpoint.integration_uuid ->
        # Set but unresolvable — surface the orphan.
        {nil, endpoint.integration_uuid}

      endpoint.provider && Enum.any?(connections, &(&1.uuid == endpoint.provider)) ->
        {endpoint.provider, nil}

      true ->
        {nil, nil}
    end
  end

  # `selected_uuids` is what the picker renders as selected. When
  # `active` resolves cleanly it's just `[active]`. When the original
  # integration is deleted, the orphan uuid is passed so the picker can
  # render its "Integration deleted" warning alongside the other cards.
  defp picker_selected_uuids(active, orphaned_integration_uuid) do
    cond do
      active -> [active]
      orphaned_integration_uuid -> [orphaned_integration_uuid]
      true -> []
    end
  end

  defp maybe_fetch_models_on_load(socket, connected) when connected in [nil, false], do: socket

  defp maybe_fetch_models_on_load(socket, _connected) do
    send(self(), :fetch_models_from_integration)
    start_model_fetch_indicators(socket)
  end

  @impl true
  def handle_params(params, _url, socket) do
    # `:loaded_id` tracks which `params["id"]` the LV currently has data
    # for. `:unloaded` is the initial sentinel set in `mount/3`; `nil`
    # means "loaded as the new-endpoint form"; a binary UUID means
    # "loaded for that endpoint". Re-loads only when the id actually
    # changes — handles the `push_patch` case where the same LV process
    # is reused across `/endpoints/A/edit` → `/endpoints/B/edit` (no
    # caller does this today, but cheap to be safe for future routes).
    if socket.assigns.loaded_id == params["id"] do
      {:noreply, socket}
    else
      handle_initial_params(params, socket)
    end
  end

  defp handle_initial_params(params, socket) do
    if AI.enabled?() do
      connections = load_all_provider_connections()

      socket =
        socket
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:site_url, Settings.get_setting("site_url"))
        |> assign(:provider_connections, connections)
        |> load_endpoint(params["id"])
        |> refresh_provider_options(connections)
        |> assign(:loaded_id, params["id"])

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("AI module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    # When the operator changes the provider dropdown, the previously
    # picked integration is for a different provider — clear it so the
    # picker doesn't render an off-provider uuid as orphaned. Also nil
    # out base_url so the changeset's `maybe_set_default_base_url`
    # picks up the new provider's default URL.
    {params, socket} = maybe_handle_provider_change(params, socket)

    # Build the changeset to keep `@form` and `@selected_model` in
    # sync with user input, but DON'T stamp `:action, :validate` —
    # that's what makes Phoenix's `<.input>` render error markup, and
    # surfacing "can't be blank" before the user clicks Save is the
    # behaviour the boss explicitly didn't want. Errors come back on
    # save-failure via the action that `Repo.insert/update` stamps
    # automatically.
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(params)

    # Update selected model when model changes
    selected_model =
      case params["model"] do
        nil -> socket.assigns.selected_model
        "" -> nil
        model_id -> find_model(socket.assigns.models, model_id)
      end

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)
      |> assign(:current_provider, params["provider"] || socket.assigns[:current_provider])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    # Reset provider selection
    socket =
      socket
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    # Find models for this provider
    provider_models =
      case Enum.find(socket.assigns.models_grouped, fn {p, _} -> p == provider end) do
        {_, models} -> models
        nil -> []
      end

    socket =
      socket
      |> assign(:selected_provider, provider)
      |> assign(:provider_models, provider_models)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"_target" => ["model"], "model" => ""}, socket) do
    # Ignore when reset to placeholder
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"model" => model_id}, socket) when model_id != "" do
    # Find the model details
    selected_model = find_model(socket.assigns.models, model_id)

    # Update the form with new model
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    # No action stamp — see the comment in the `"validate"` handler.
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_model", _params, socket) do
    # Clear the model selection
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", "")

    # No action stamp — see the comment in the `"validate"` handler.
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", %{"model" => model_id}, socket) when model_id != "" do
    # Set model from manual input (when models list not loaded)
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    # No action stamp — see the comment in the `"validate"` handler.
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_reasoning", _params, socket) do
    # Toggle the reasoning_enabled value in form params
    current_value =
      socket.assigns.form.params["reasoning_enabled"] == "true" ||
        socket.assigns.form.params["reasoning_enabled"] == true ||
        (socket.assigns.endpoint && socket.assigns.endpoint.reasoning_enabled == true)

    new_value = if current_value, do: "false", else: "true"
    updated_params = Map.put(socket.assigns.form.params, "reasoning_enabled", new_value)

    form = %{socket.assigns.form | params: updated_params}
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("select_provider_connection", %{"action" => "deselect"}, socket) do
    # Clicking the currently-selected card unpicks it. Round-trip
    # through the changeset so future field-level validators on
    # `:integration_uuid` (or anything else cast alongside it) run
    # for free — bypassing the changeset and mutating `form.params`
    # directly was a footgun waiting to happen.
    new_params = Map.put(socket.assigns.form.params, "integration_uuid", nil)

    # No action stamp — see the comment in the `"validate"` handler.
    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:active_connection, nil)
      |> assign(:selected_uuids, [])
      |> assign(:integration_connected, false)
      |> assign(:models, [])
      |> assign(:models_grouped, [])
      |> stop_model_fetch_indicators()
      |> assign(:models_error, nil)

    {:noreply, socket}
  end

  def handle_event("select_provider_connection", %{"uuid" => uuid}, socket) do
    # Pin the endpoint to the chosen integration row by uuid.
    updated_params = Map.put(socket.assigns.form.params, "integration_uuid", uuid)
    form = %{socket.assigns.form | params: updated_params}

    connected = Integrations.connected?(uuid)

    # Clear stale model state from any previous integration. Without
    # this, switching A → B leaves A's model list rendered while B's
    # fetch is in flight (and if B's fetch fails, A's models stay
    # visible alongside the error pane — a misleading combination).
    # The picker is about to repopulate from B's response anyway, so
    # zeroing out is safe.
    socket =
      socket
      |> assign(:form, form)
      |> assign(:active_connection, uuid)
      |> assign(:selected_uuids, [uuid])
      |> assign(:integration_connected, connected)
      |> assign(:models, [])
      |> assign(:models_grouped, [])
      |> assign(:models_error, nil)
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])
      |> assign(:selected_model, nil)

    # Reload models with new connection
    if connected do
      send(self(), :fetch_models_from_integration)
      {:noreply, start_model_fetch_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_model_fetch", _params, socket) do
    # Re-trigger `:fetch_models_from_integration` after a previous
    # fetch failed. Surfaced via the retry button on the model picker
    # error pane so operators don't have to re-pick the integration
    # to recover from a transient upstream failure (5xx, timeout,
    # rate-limit). The handler is a no-op if the active integration
    # isn't connected anymore — same gate as the initial fetch.
    if socket.assigns[:integration_connected] do
      send(self(), :fetch_models_from_integration)
      {:noreply, start_model_fetch_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_model_type", %{"model_type" => type}, socket) do
    # Switching the type re-runs the same fetch flow with a different
    # `model_type` filter. The model picker is the only thing that
    # changes shape, so clear the current model/provider selection (a
    # chat model isn't valid under the TTS filter and vice-versa) and
    # let the post-fetch block re-derive them from the filtered list.
    socket =
      socket
      |> assign(:model_type, parse_model_type(type))
      |> assign(:selected_model, nil)
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])
      |> assign(:models, [])
      |> assign(:models_grouped, [])

    if socket.assigns[:integration_connected] do
      send(self(), :fetch_models_from_integration)
      {:noreply, start_model_fetch_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"endpoint" => params}, socket) do
    # Merge provider_settings from nested params
    provider_settings = %{
      "http_referer" => get_in(params, ["provider_settings", "http_referer"]) || "",
      "x_title" => get_in(params, ["provider_settings", "x_title"]) || "",
      # Per-endpoint default TTS voice (used by PhoenixKitAI.speak/3 when
      # the caller passes no voice). Only the TTS type renders this input,
      # so for other types it submits as "" — a harmless no-op.
      "voice" => get_in(params, ["provider_settings", "voice"]) || ""
    }

    params = Map.put(params, "provider_settings", provider_settings)

    # Stamp integration_uuid from the picker's current state — a uuid
    # when one is selected, nil when the operator unpicked (or never
    # picked one). Always writing means an explicit deselect actually
    # clears the column on save instead of silently retaining the
    # previously-stored value. The legacy `provider` column stays at
    # whatever it was (defaults to "openrouter") — not used for
    # resolution anymore, just kept until the column is dropped.
    params = Map.put(params, "integration_uuid", socket.assigns[:active_connection])

    # Parse numeric fields and string lists
    params =
      params
      |> parse_float("temperature")
      |> parse_integer("max_tokens")
      |> parse_float("top_p")
      |> parse_integer("top_k")
      |> parse_float("frequency_penalty")
      |> parse_float("presence_penalty")
      |> parse_float("repetition_penalty")
      |> parse_integer("seed")
      |> parse_integer("dimensions")
      |> parse_string_list("stop")

    save_endpoint(socket, params)
  end

  defp maybe_handle_provider_change(params, socket) do
    new_provider = params["provider"]
    current_provider = socket.assigns[:current_provider]

    provider_changed? =
      is_binary(new_provider) and is_binary(current_provider) and new_provider != current_provider

    if provider_changed? do
      # Clear the model id too — model strings are provider-shaped
      # ("anthropic/claude-3-opus" on OpenRouter, "mistral-large-latest"
      # on Mistral) and a stale id from the previous provider would
      # silently survive into save if the operator never re-picked.
      # Use "" rather than nil — the template's `params["model"] ||
      # @endpoint.model` fallback would otherwise resurface the saved
      # model (nil is falsy in Elixir, "" is truthy).
      params =
        params
        |> Map.put("base_url", "")
        |> Map.put("model", "")

      socket =
        socket
        |> assign(:active_connection, nil)
        |> assign(:selected_uuids, [])
        |> assign(:integration_connected, false)
        |> assign(:models, [])
        |> assign(:models_grouped, [])
        |> assign(:selected_model, nil)
        |> assign(:selected_provider, nil)
        |> assign(:provider_models, [])
        |> stop_model_fetch_indicators()
        |> assign(:models_error, nil)

      {params, socket}
    else
      {params, socket}
    end
  end

  defp reload_connections(socket) do
    connections = load_all_provider_connections()
    current_active = socket.assigns[:active_connection]
    endpoint_uuid = socket.assigns[:endpoint] && socket.assigns.endpoint.integration_uuid

    {active, orphaned} = resolve_reloaded_connection(connections, current_active, endpoint_uuid)
    selected_uuids = picker_selected_uuids(active, orphaned)
    connected = active && Integrations.connected?(active)

    socket
    |> assign(:provider_connections, connections)
    |> assign(:active_connection, active)
    |> assign(:selected_uuids, selected_uuids)
    |> assign(:integration_connected, connected)
    |> refresh_provider_options(connections)
  end

  # Re-resolves the active connection after the connection list reloads.
  # Keeps the current selection if it still exists; otherwise surfaces a
  # now-deleted pinned integration as an orphan rather than silently
  # switching the endpoint to a different connection.
  defp resolve_reloaded_connection(connections, current_active, endpoint_uuid) do
    cond do
      current_active && Enum.any?(connections, &(&1.uuid == current_active)) ->
        {current_active, nil}

      endpoint_uuid && not Enum.any?(connections, &(&1.uuid == endpoint_uuid)) ->
        {nil, endpoint_uuid}

      true ->
        {nil, nil}
    end
  end

  defp refresh_provider_options(socket, connections) do
    # The "keep current_provider in the list" branch only applies on
    # edit — preserving the endpoint's saved provider when its
    # provider has 0 connections. On `:new`, `current_provider` is
    # the mount default ("openrouter"), not a saved selection;
    # padding it in would surface a dead-end provider whose only
    # path forward is "go set up an integration first."
    editing? = socket.assigns[:endpoint] != nil

    pinned_provider = if editing?, do: socket.assigns[:current_provider]

    assign(
      socket,
      :provider_options,
      provider_options_for(connections, pinned_provider)
    )
  end

  # Loads connections for every AI provider in one shot. The picker
  # filters client-side via its `provider` attr (matches `data["provider"]`),
  # so feeding it the union lets a `provider` field change in the form
  # immediately re-filter the cards without a server round-trip — and
  # without us having to track which provider the connections are for.
  defp load_all_provider_connections do
    Endpoint.valid_providers()
    |> Enum.flat_map(&Integrations.list_connections/1)
  end

  # Provider-dropdown options filtered to providers with at least one
  # configured integration. Two special cases:
  #
  # * **No connections anywhere** → fall back to the full provider list
  #   so the dropdown is still usable while the operator follows the
  #   "Settings → Integrations" hint to set one up. Checked against the
  #   raw connection list (not the connection set + current_provider)
  #   so the mount-default `current_provider = "openrouter"` doesn't
  #   silently turn the full-fallback into "just OpenRouter".
  #
  # * **Editing an endpoint whose provider has 0 connections** → keep
  #   the endpoint's saved provider in the list so the user's
  #   selection doesn't vanish mid-flow.
  defp provider_options_for(connections, current_provider) do
    available_from_connections =
      connections
      |> Enum.map(& &1.data["provider"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(available_from_connections) == 0 do
      Endpoint.provider_options()
    else
      available =
        if current_provider,
          do: MapSet.put(available_from_connections, current_provider),
          else: available_from_connections

      Enum.filter(Endpoint.provider_options(), fn {_label, key} ->
        MapSet.member?(available, key)
      end)
    end
  end

  # Normalise a form field value (always a string from HTML) into the
  # shape the changeset expects. Blank strings become nil; invalid
  # numeric input is left untouched so Ecto can emit its own error.
  defp parse_field(params, key, parser) do
    case params[key] do
      nil -> params
      "" -> Map.put(params, key, nil)
      val when is_binary(val) -> Map.put(params, key, parser.(val, params[key]))
      _ -> params
    end
  end

  defp parse_float(params, key) do
    parse_field(params, key, fn val, original ->
      case Float.parse(val) do
        {num, _} -> num
        :error -> original
      end
    end)
  end

  defp parse_integer(params, key) do
    parse_field(params, key, fn val, original ->
      case Integer.parse(val) do
        {num, _} -> num
        :error -> original
      end
    end)
  end

  defp parse_string_list(params, key) do
    parse_field(params, key, fn val, _original ->
      list =
        val
        |> String.split(~r/[\r\n]+/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      if list == [], do: nil, else: list
    end)
  end

  defp save_endpoint(socket, params) do
    opts = actor_opts(socket)

    result =
      if socket.assigns.endpoint do
        AI.update_endpoint(socket.assigns.endpoint, params, opts)
      else
        AI.create_endpoint(params, opts)
      end

    case result do
      {:ok, endpoint} ->
        action = if socket.assigns.endpoint, do: "updated", else: "created"
        message = save_success_message(endpoint, action)

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: PhoenixKitAI.Routes.ai_path())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  rescue
    e ->
      Logger.error(
        "Endpoint save failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  # Builds the post-save flash message, appending a soft warning when the
  # endpoint's `provider` points at an integration that is not currently
  # connected AND there is no legacy `api_key` fallback. Save still
  # succeeds — the user is free to connect the integration afterwards.
  defp save_success_message(endpoint, action) do
    base = gettext("Endpoint %{action} successfully", action: action)

    case integration_warning(endpoint) do
      nil -> base
      warning -> base <> ". " <> warning
    end
  end

  @doc false
  # Public for testability. Returns the soft-warning string for an
  # endpoint whose chosen integration isn't reachable AND has no legacy
  # `api_key` fallback. Returns nil when any branch of the resolution
  # ladder keeps the endpoint working at request time. Mirrors the
  # ladder in `OpenRouterClient.resolve_api_key/1` so the warning can't
  # disagree with what the next request would actually do.
  def integration_warning(endpoint) when is_map(endpoint) do
    integration_uuid = Map.get(endpoint, :integration_uuid)
    provider = Map.get(endpoint, :provider)
    api_key = Map.get(endpoint, :api_key)

    cond do
      # Endpoint pinned via integration_uuid — that specific row is
      # the source of truth, regardless of what the legacy `provider`
      # column still says.
      present?(integration_uuid) and Integrations.connected?(integration_uuid) ->
        nil

      # Legacy endpoint with a stored api_key — fallback path still works.
      present?(api_key) ->
        nil

      # Pinned to an integration that isn't reachable — surface that.
      present?(integration_uuid) ->
        gettext(
          "The selected integration is not connected — requests will fail until you connect it in Settings → Integrations."
        )

      # No integration_uuid, but the legacy `provider` column may
      # carry a uuid (pre-V107) or a `provider:name` string. The
      # dual-input shim handles both shapes.
      present?(provider) ->
        provider_connection_warning(provider)

      true ->
        gettext(
          "No integration configured for this endpoint. Set up the API key in Settings → Integrations."
        )
    end
  end

  # Soft warning for an endpoint resolved via the legacy `provider`
  # column — nil when that provider's integration is reachable.
  defp provider_connection_warning(provider) do
    if Integrations.connected?(provider) do
      nil
    else
      gettext(
        "The %{provider} integration is not connected — requests will fail until you connect it in Settings → Integrations.",
        provider: "\"#{provider}\""
      )
    end
  end

  # True when `value` is a non-empty binary.
  defp present?(value), do: is_binary(value) and value != ""

  # Captures the current admin/user's UUID so the Activity feed can
  # attribute the mutation to the right actor. Returns an empty list
  # when the scope isn't available (e.g. in isolated test sockets).
  defp actor_opts(socket), do: AuthHelpers.actor_opts(socket)

  # PubSub: reload connections when integrations change
  @impl true
  def handle_info({event, _, _}, socket)
      when event in [
             :integration_setup_saved,
             :integration_connected,
             :integration_connection_added
           ] do
    {:noreply, reload_connections(socket)}
  end

  def handle_info({event, _}, socket)
      when event in [:integration_disconnected, :integration_connection_removed] do
    {:noreply, reload_connections(socket)}
  end

  def handle_info({:integration_validated, _, _}, socket) do
    {:noreply, reload_connections(socket)}
  end

  @impl true
  def handle_info(:fetch_models_from_integration, socket) do
    # All three current providers (OpenRouter, Mistral, DeepSeek)
    # expose `<base_url>/models` with an OpenAI-compatible
    # `{"data": [{"id": ...}, ...]}` shape. The fetcher uses the
    # endpoint's `base_url` to hit the right host, and groups by
    # the endpoint's `provider` for IDs without a slash (so Mistral's
    # "mistral-large-latest" and DeepSeek's "deepseek-chat" land in
    # one group rather than each spawning a one-off group).
    #
    # Only fetch for the picker's actual selection. Falling back to
    # "any openrouter:default connection" silently misled operators
    # whose integration was named anything other than "default" (and
    # contradicted the picker's "reflect state, never auto-pick"
    # policy).
    active_key = socket.assigns[:active_connection]

    case active_key && Integrations.get_credentials(active_key) do
      {:ok, %{"api_key" => api_key}} when is_binary(api_key) and api_key != "" ->
        # Validate-then-fetch. The model fetch is gated on a real
        # auth check (`Integrations.validate_connection/2` hits the
        # provider's `validation.url` — `/auth/key` for OpenRouter,
        # which actually verifies the Bearer token) so a bad key
        # can't paint a working-looking model grid.
        #
        # The validation runs in a supervised Task to keep the LV
        # responsive (Req.get is blocking; inline would freeze the LV
        # process for the round-trip). The Task records the validation
        # result (PubSub auto-broadcasts on status change → picker
        # badge updates) and sends `{:validation_done, uuid, result,
        # api_key}` back so the LV can decide whether to continue
        # with the model fetch.
        #
        # `Task.Supervisor.start_child` (not bare `Task.start`) is the
        # playbook-mandated shape for fire-and-forget LV-spawned work:
        # if the Task crashes (HTTP transport error not caught by
        # `validate_connection`, sandbox exit in tests, etc.) the
        # supervisor restarts/discards rather than orphaning the
        # process. `Task.start_link` is wrong here — a linked crash
        # would take down the LV process.
        #
        # `$callers` propagation: `Task.Supervisor.start_child`
        # doesn't carry the caller chain that `Req.Test.allow/3`
        # walks to find the stubbed plug. We copy the LV's chain
        # into the Task so tests that allow the LV pid also cover
        # this Task.
        parent = self()
        callers = [parent | Process.get(:"$callers", [])]

        Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
          Process.put(:"$callers", callers)
          result = Integrations.validate_connection(active_key)
          Integrations.record_validation(active_key, result)
          send(parent, {:validation_done, active_key, result, api_key})
        end)

        # Loading-state assigns were already set by the caller's
        # `start_model_fetch_indicators`; leave them alone so the
        # spinner stays visible until validation resolves.
        {:noreply, socket}

      _ ->
        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models_error, "No API key configured")

        {:noreply, socket}
    end
  end

  # Validation succeeded — proceed with the model fetch.
  # Guarded on `active_connection` matching the uuid the Task ran for
  # so a stale completion from a previously-picked integration can't
  # repopulate models after the operator switched.
  @impl true
  def handle_info({:validation_done, uuid, :ok, api_key}, socket) do
    if socket.assigns[:active_connection] == uuid do
      send(self(), {:fetch_models, api_key, uuid})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Validation failed — clear loading + surface the auth error.
  # No model fetch is issued so the grid stays empty (no false-positive
  # "look, models are loading!" while the key can't actually auth).
  def handle_info({:validation_done, uuid, {:error, reason}, _api_key}, socket) do
    if socket.assigns[:active_connection] == uuid do
      socket =
        socket
        |> stop_model_fetch_indicators()
        |> assign(:models_error, format_validation_error(reason))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fetch_models, api_key, uuid}, socket) do
    # Stale-fetch guard: if the operator picked a different
    # integration between Task scheduling and message delivery,
    # `uuid` no longer matches the active connection — drop the
    # response so it can't repopulate models for the wrong
    # integration. Defence in depth; `:validation_done` already
    # gates the producer side.
    #
    # Both sides have to be concrete uuids for the guard to fire.
    # A nil `active_connection` (operator deselected, or unit-test
    # direct send) bypasses the guard — the section gating renders
    # an empty body in that state anyway, so stale data is harmless.
    active = socket.assigns[:active_connection]

    if is_binary(uuid) and is_binary(active) and active != uuid do
      {:noreply, socket}
    else
      do_fetch_models(socket, api_key)
    end
  end

  # The integration's `/models` fetch is wedged or slow; the picker
  # spinner has been spinning for 10s. Surface a "still loading" hint
  # so the operator knows it's not the UI that's stuck — they can
  # decide to wait or cancel out. The handler is idempotent: if the
  # actual fetch already completed, models_loading is false and we
  # leave models_loading_slow false too (no UI change).
  @impl true
  def handle_info(:model_fetch_slow, socket) do
    if socket.assigns[:models_loading] do
      {:noreply, assign(socket, :models_loading_slow, true)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for unmatched messages (PubSub from other modules, late
  # replies after navigation, etc.). Log at :debug per the workspace
  # sync precedent — never silently swallow a message we didn't expect.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.EndpointForm] unhandled handle_info: #{inspect(msg)}"
    end)

    {:noreply, socket}
  end

  # Private helpers

  defp do_fetch_models(socket, api_key) do
    base_url = current_models_base_url(socket)
    fallback_provider = socket.assigns[:current_provider]

    fetch_opts = [
      # Always assigned in mount (defaults to :text), so no fallback needed.
      model_type: socket.assigns.model_type,
      base_url: base_url,
      fallback_provider: fallback_provider
    ]

    case OpenRouterClient.fetch_models_grouped(api_key, fetch_opts) do
      {:ok, grouped} ->
        # Intentionally NOT calling `record_validation(:ok)` here —
        # OpenRouter's `/models` endpoint is effectively public
        # (returns 200 + the model list for any / no Bearer token),
        # so fetch success doesn't prove the api_key can actually
        # authenticate a chat completion. The real auth check is the
        # provider's `validation.url` (`/auth/key` for OpenRouter),
        # which `:validate_integration` kicks off in parallel.

        # Flatten for easy lookup
        models =
          grouped
          |> Enum.flat_map(fn {_provider, models} -> models end)

        # Set selected model if editing existing endpoint
        selected_model =
          case socket.assigns.endpoint do
            %{model: model_id} when is_binary(model_id) and model_id != "" ->
              find_model(models, model_id)

            _ ->
              nil
          end

        # When the response groups under a single provider (Mistral /
        # DeepSeek / any direct API whose model IDs don't carry a
        # `provider/model` slash), the "select provider" dropdown is a
        # one-option click that gates the grid behind needless friction.
        # Auto-select the sole group so the operator lands directly on
        # the model cards. The grid clear-button still lets them empty
        # the selection if they want to dismiss the picker.
        {selected_provider, provider_models} =
          case grouped do
            [{provider, models}] -> {provider, models}
            _ -> {socket.assigns[:selected_provider], socket.assigns[:provider_models] || []}
          end

        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models, models)
          |> assign(:models_grouped, grouped)
          |> assign(:models_error, nil)
          |> assign(:selected_model, selected_model)
          |> assign(:selected_provider, selected_provider)
          |> assign(:provider_models, provider_models)

        {:noreply, socket}

      {:error, reason} ->
        # Same rationale as the success branch above — fetch_models
        # isn't the right validation signal. The parallel
        # `:validate_integration` Task handles the real check.
        translated = PhoenixKitAI.Errors.message(reason)

        # Log the failure with grep-able context (provider + reason) so
        # operators can correlate "model dropdown is empty" reports with
        # upstream API issues. Provider is the form-side selection at
        # the time of fetch.
        Logger.warning(fn ->
          "[PhoenixKitAI.Web.EndpointForm] model fetch failed: " <>
            "provider=#{inspect(socket.assigns[:current_provider])}, " <>
            "reason=#{inspect(reason)}"
        end)

        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models_error, translated)

        {:noreply, socket}
    end
  end

  defp format_validation_error(reason) when is_binary(reason), do: reason
  defp format_validation_error(reason), do: PhoenixKitAI.Errors.message(reason)

  defp find_model(models, model_id) do
    Enum.find(models, fn m -> m.id == model_id end)
  end

  # The model-type picker drives which `model_type` filter the fetch
  # uses. Only Chat and TTS are wired today (embedding/image come from
  # other sources); anything unrecognised falls back to chat.
  defp parse_model_type("tts"), do: :tts
  defp parse_model_type(_), do: :text

  # Infer an existing endpoint's type from its saved model id so editing
  # a TTS endpoint opens on the TTS filter (and shows the voice field).
  defp model_type_for(model) when is_binary(model) do
    if String.contains?(String.downcase(model), "tts"), do: :tts, else: :text
  end

  defp model_type_for(_), do: :text

  # Sets the loading indicator and schedules a 10s "still loading"
  # timer. The timer ref is stashed on the socket so the completion
  # handlers can cancel it. If the fetch completes before 10s, the
  # timer fires harmlessly into the no-op branch of the slow handler.
  # If 10s passes first, the spinner gains a "still loading" hint so
  # the operator knows it's not a wedged UI.
  defp start_model_fetch_indicators(socket) do
    cancel_model_fetch_slow_timer(socket)

    timer_ref = Process.send_after(self(), :model_fetch_slow, 10_000)

    socket
    |> assign(:models_loading, true)
    |> assign(:models_loading_slow, false)
    |> assign(:models_error, nil)
    |> assign(:model_fetch_slow_timer, timer_ref)
  end

  # Reset path — fetch completed (success or error). Cancels the
  # 10s timer if still pending and clears all loading-state assigns.
  defp stop_model_fetch_indicators(socket) do
    cancel_model_fetch_slow_timer(socket)

    socket
    |> assign(:models_loading, false)
    |> assign(:models_loading_slow, false)
    |> assign(:model_fetch_slow_timer, nil)
  end

  defp cancel_model_fetch_slow_timer(socket) do
    case socket.assigns[:model_fetch_slow_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end
  end

  # Resolves the base URL the model fetcher should hit.
  #
  # Reuses the saved `endpoint.base_url` ONLY when the form's currently
  # selected provider matches the endpoint's saved provider. Otherwise
  # the operator switched providers in edit mode and the saved URL is
  # for a different host — falling back to it would silently misroute
  # the model fetch (e.g. fetch from openrouter.ai while the active
  # integration is a Mistral key). Falls through to the schema default
  # for the form-side provider, then to OpenRouter's URL as a last
  # resort. The new-endpoint flow has no saved endpoint, so it always
  # takes the second branch.
  defp current_models_base_url(socket) do
    current_provider = socket.assigns[:current_provider]
    endpoint = socket.assigns[:endpoint]
    endpoint_url = endpoint && endpoint.base_url

    cond do
      # Use `&&` throughout: strict `and` raises BadBooleanError on
      # `nil` (which is what `endpoint && endpoint.provider == ...`
      # returns when `endpoint` is nil on the new-endpoint flow).
      endpoint && endpoint.provider == current_provider && present?(endpoint_url) ->
        endpoint_url

      is_binary(current_provider) ->
        Endpoint.default_base_url(current_provider) || OpenRouterClient.base_url()

      true ->
        OpenRouterClient.base_url()
    end
  end

  @doc """
  Parameter definitions with type, constraints, and UI metadata.
  Only parameters we support in the UI are defined here.
  """
  def parameter_definitions do
    %{
      # Basic parameters
      "temperature" => %{
        type: :float,
        label: "Temperature",
        min: 0,
        max: 2,
        step: 0.1,
        default: 0.7,
        field: :temperature,
        group: :basic,
        description: "Controls randomness in responses"
      },
      "max_tokens" => %{
        type: :integer,
        label: "Max Tokens",
        min: 1,
        field: :max_tokens,
        group: :basic,
        description: "Maximum tokens to generate"
      },
      "top_p" => %{
        type: :float,
        label: "Top P",
        min: 0,
        max: 1,
        step: 0.1,
        field: :top_p,
        group: :basic,
        description: "Nucleus sampling threshold"
      },
      "top_k" => %{
        type: :integer,
        label: "Top K",
        min: 1,
        field: :top_k,
        group: :basic,
        description: "Top-k sampling parameter"
      },
      # Advanced parameters
      "frequency_penalty" => %{
        type: :float,
        label: "Frequency Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :frequency_penalty,
        group: :advanced,
        description: "Penalize frequent tokens"
      },
      "presence_penalty" => %{
        type: :float,
        label: "Presence Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :presence_penalty,
        group: :advanced,
        description: "Penalize tokens already present"
      },
      "repetition_penalty" => %{
        type: :float,
        label: "Repetition Penalty",
        min: 0,
        max: 2,
        step: 0.1,
        field: :repetition_penalty,
        group: :advanced,
        description: "Penalize repeated sequences"
      },
      "seed" => %{
        type: :integer,
        label: "Seed",
        field: :seed,
        group: :advanced,
        placeholder: "Random",
        description: "For reproducible outputs"
      },
      "stop" => %{
        type: :string_list,
        label: "Stop Sequences",
        field: :stop,
        group: :advanced,
        placeholder: "One per line",
        description: "Sequences that stop generation"
      }
    }
  end

  @doc """
  Returns parameters supported by the model, filtered to ones we have UI for.
  Groups them by :basic and :advanced.
  """
  def get_supported_params(nil) do
    # No model selected - show all parameters
    definitions = parameter_definitions()
    group_parameters(Map.keys(definitions), definitions)
  end

  def get_supported_params(%AIModel{} = model) do
    definitions = parameter_definitions()
    supported_keys = Enum.filter(model.supported_parameters, &Map.has_key?(definitions, &1))
    group_parameters(supported_keys, definitions)
  end

  def get_supported_params(model) when is_map(model) do
    supported = model["supported_parameters"] || []
    definitions = parameter_definitions()
    supported_keys = Enum.filter(supported, &Map.has_key?(definitions, &1))
    group_parameters(supported_keys, definitions)
  end

  defp group_parameters(keys, definitions) do
    keys
    |> Enum.map(fn key -> {key, definitions[key]} end)
    |> Enum.group_by(fn {_key, def} -> def.group end)
    |> Map.new(fn {group, params} ->
      {group, Enum.sort_by(params, fn {key, _} -> key end)}
    end)
  end

  @doc """
  Gets the max tokens limit for the selected model.
  """
  def model_max_tokens(nil), do: nil

  def model_max_tokens(%AIModel{} = model) do
    model.max_completion_tokens || model.context_length
  end

  def model_max_tokens(model) when is_map(model) do
    model["max_completion_tokens"] || model["context_length"]
  end

  @doc """
  Formats a number with thousands separators.
  """
  def format_number(nil), do: "0"
  def format_number(num) when is_integer(num), do: Integer.to_string(num) |> add_commas()
  def format_number(num) when is_float(num), do: round(num) |> Integer.to_string() |> add_commas()
  def format_number(num) when is_binary(num), do: num

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @doc """
  Formats a per-token model price as a per-million-tokens display.

  OpenRouter pricing comes back in two shapes — newer rows use a JSON
  number, older rows use a stringified float. This helper accepts
  either and returns a rounded "$X.XX" string. Returns `nil` for
  empty/missing values so the template can render-or-skip cleanly.

  ## Examples

      iex> EndpointForm.format_price(0.0000015)
      "$1.50"

      iex> EndpointForm.format_price("0.0000015")
      "$1.50"

      iex> EndpointForm.format_price(nil)
      nil
  """
  @spec format_price(number() | String.t() | nil) :: String.t() | nil
  def format_price(nil), do: nil
  def format_price(""), do: nil

  def format_price(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> format_price(n)
      :error -> nil
    end
  end

  def format_price(value) when is_number(value) do
    # `value * 1.0` forces an integer (free-tier 0 pricing) up to float
    # before :erlang.float_to_binary/2, which raises on integer input.
    "$#{:erlang.float_to_binary(value * 1.0 * 1_000_000, decimals: 2)}"
  end
end
