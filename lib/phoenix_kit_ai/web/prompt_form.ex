defmodule PhoenixKitAI.Web.PromptForm do
  @moduledoc """
  LiveView for creating and editing AI prompts.

  A prompt is a reusable text template with variable substitution support.
  Variables use the `{{VariableName}}` syntax.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.Prompt
  alias PhoenixKitAI.Web.AuthHelpers

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount/3 — they run twice. The `enabled?` check
    # and the prompt load both happen in `handle_params/3`.
    socket =
      socket
      |> assign(:project_title, nil)
      |> assign(:current_path, Routes.path("/admin/ai"))
      |> assign(:extracted_variables, [])
      |> assign(:prompt, nil)
      |> assign(:form, to_form(AI.change_prompt(%Prompt{})))
      |> assign(:page_title, "AI Prompt")
      |> assign(:loaded_id, :unloaded)

    {:ok, socket}
  end

  defp load_prompt(socket, nil) do
    changeset = AI.change_prompt(%Prompt{})

    socket
    |> assign(:page_title, "New AI Prompt")
    |> assign(:prompt, nil)
    |> assign(:form, to_form(changeset))
  end

  defp load_prompt(socket, id) do
    case AI.get_prompt(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Prompt not found"))
        |> push_navigate(to: Routes.ai_path() <> "/prompts")

      prompt ->
        changeset = AI.change_prompt(prompt)

        socket
        |> assign(:page_title, "Edit AI Prompt")
        |> assign(:prompt, prompt)
        |> assign(:form, to_form(changeset))
        |> assign(:extracted_variables, prompt.variables || [])
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    # `:loaded_id` tracks which `params["id"]` the LV currently has data
    # for. `:unloaded` is the initial sentinel from `mount/3`; `nil`
    # means "loaded as the new-prompt form"; a binary UUID means "loaded
    # for that prompt". Re-loads only when the id actually changes —
    # safe under `push_patch` between two edit URLs in the same LV
    # process (no caller does this today, but cheap insurance).
    if socket.assigns.loaded_id == params["id"] do
      {:noreply, socket}
    else
      handle_initial_params(params, socket)
    end
  end

  defp handle_initial_params(params, socket) do
    if AI.enabled?() do
      socket =
        socket
        |> assign(:project_title, Settings.get_project_title())
        |> load_prompt(params["id"])
        |> assign(:loaded_id, params["id"])

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("AI module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  # ===========================================
  # EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("validate", %{"prompt" => params}, socket) do
    changeset =
      (socket.assigns.prompt || %Prompt{})
      |> AI.change_prompt(params)

    # Extract variables from content for preview
    content = params["content"] || ""
    extracted_variables = Prompt.extract_variables(content)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:extracted_variables, extracted_variables)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"prompt" => params}, socket) do
    save_prompt(socket, params)
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp save_prompt(socket, params) do
    opts = actor_opts(socket)

    result =
      if socket.assigns.prompt do
        AI.update_prompt(socket.assigns.prompt, params, opts)
      else
        AI.create_prompt(params, opts)
      end

    case result do
      {:ok, _prompt} ->
        message =
          if socket.assigns.prompt,
            do: gettext("Prompt updated successfully"),
            else: gettext("Prompt created successfully")

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Routes.ai_path() <> "/prompts")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "Prompt save failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  defp actor_opts(socket), do: AuthHelpers.actor_opts(socket)

  # Catch-all so an unexpected PubSub message or deferred-task reply
  # from a future code path can't crash the form silently. The LV
  # doesn't subscribe today, but the catch-all matches the endpoints
  # LV's defensive coverage.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
