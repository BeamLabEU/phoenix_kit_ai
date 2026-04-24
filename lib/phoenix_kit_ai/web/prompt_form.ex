defmodule PhoenixKitAI.Web.PromptForm do
  @moduledoc """
  LiveView for creating and editing AI prompts.

  A prompt is a reusable text template with variable substitution support.
  Variables use the `{{VariableName}}` syntax.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.Prompt

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(params, _session, socket) do
    if AI.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:current_path, Routes.path("/admin/ai"))
        |> assign(:extracted_variables, [])
        |> load_prompt(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("AI module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
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
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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

  defp actor_opts(socket) do
    role = if admin?(socket), do: "admin", else: "user"

    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> [actor_uuid: uuid, actor_role: role]
      _ -> [actor_role: role]
    end
  end

  defp admin?(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.admin?(scope)
    end
  end
end
