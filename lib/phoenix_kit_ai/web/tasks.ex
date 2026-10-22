defmodule PhoenixKitAI.Web.Tasks do
  @moduledoc """
  LiveView for the AI tasks the installed modules declare
  (`PhoenixKitAI.Tasks`): what each is for, what its model has to be able
  to do, the endpoints it uses now and whether each of them fits.

  Read-only. The fitness is recomputed when the capability cache changes
  (`{:capabilities_refreshed, _}`), and the "Refresh catalogues" button
  asks `PhoenixKitAI.Capabilities.refresh/0` for a fresh read of the
  providers' model lists.

  Mounted at `{prefix}/admin/ai/tasks`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitAI.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitAI.{Capabilities, Recommendations, Tasks, TaskSpec}
  alias PhoenixKitAI.Web.Components.TaskModelPicker
  alias PhoenixKitAI.Web.MessageShape

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Capabilities.subscribe()

    socket =
      socket
      |> assign(:current_path, PhoenixKitAI.Routes.ai_path() <> "/tasks")
      |> assign(:page_section, gettext("AI"))
      |> assign(:page_section_path, PhoenixKitAI.Routes.ai_path())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, gettext("Tasks"))
      |> assign(:page_subtitle, gettext("What each AI task needs and whether its endpoints fit"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:refreshing, false)
      |> assign(:tasks, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     socket
     |> assign(:current_path, URI.parse(uri).path)
     |> load_tasks()}
  end

  @impl true
  def handle_event("refresh_catalogues", _params, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, true)
     |> start_async(:refresh_catalogues, fn -> Capabilities.refresh() end)}
  end

  @impl true
  def handle_async(:refresh_catalogues, result, socket) do
    socket = socket |> assign(:refreshing, false) |> load_tasks()

    case result do
      {:ok, :ok} ->
        {:noreply, put_flash(socket, :info, gettext("Model catalogues refreshed"))}

      _failed ->
        {:noreply, put_flash(socket, :error, gettext("Some model catalogues could not be read"))}
    end
  end

  @impl true
  def handle_info({:capabilities_refreshed, _base_urls}, socket),
    do: {:noreply, load_tasks(socket)}

  # Catch-all for messages from other topics: shape only, never content.
  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.Tasks] unhandled handle_info: #{MessageShape.describe(msg)}"
    end)

    {:noreply, socket}
  end

  defp load_tasks(socket) do
    # The catalogues and the journal are read once for all the tasks.
    specs = Tasks.list()
    recommendations = Recommendations.for_tasks(specs)

    tasks =
      for spec <- specs do
        %{
          spec: spec,
          dom_id: dom_id(spec.key),
          recommendations: Map.fetch!(recommendations, spec.key),
          endpoints:
            spec
            |> Tasks.endpoints()
            |> Enum.map(&%{endpoint: &1, fitness: Tasks.fitness(spec, &1)})
        }
      end

    assign(socket, :tasks, tasks)
  end

  # Readable, and unique: `a.b` and `a-b` slug alike, the hash tells them apart.
  defp dom_id(key) do
    hash = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "ai-task-" <> String.replace(key, ~r/[^A-Za-z0-9_-]/, "-") <> "-" <> hash
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <div class="flex items-center justify-between gap-2">
        <p class="text-sm text-base-content/70">
          {gettext(
            "Each task is declared by a module. A call with a task is refused before it reaches the provider when the model lacks something the task needs."
          )}
        </p>
        <button
          id="ai-tasks-refresh"
          type="button"
          class="btn btn-sm btn-outline"
          phx-click="refresh_catalogues"
          disabled={@refreshing}
        >
          <.icon name="hero-arrow-path" class={if(@refreshing, do: "w-4 h-4 animate-spin", else: "w-4 h-4")} />
          {gettext("Refresh catalogues")}
        </button>
      </div>

      <%= if @tasks == [] do %>
        <div id="ai-tasks-empty" class="alert">
          {gettext("No module declares an AI task.")}
        </div>
      <% end %>

      <div id="ai-tasks" class="grid gap-4">
        <div
          :for={task <- @tasks}
          id={task.dom_id}
          data-task-key={task.spec.key}
          class={["card bg-base-200", !task.spec.enabled && "opacity-60"]}
        >
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="card-title text-base">{TaskSpec.label(task.spec)}</h2>
              <code class="text-xs text-base-content/60">{task.spec.key}</code>
              <span :if={!task.spec.enabled} class="badge badge-ghost badge-sm" data-module-off>
                {gettext("Module off")}
              </span>
            </div>

            <p :if={TaskSpec.purpose(task.spec)} class="text-sm">{TaskSpec.purpose(task.spec)}</p>

            <div class="flex flex-wrap items-center gap-1 text-sm">
              <span class="text-base-content/70">{gettext("Needs:")}</span>
              <%= if task.spec.needs == [] do %>
                <span class="badge badge-ghost badge-sm">{gettext("text only")}</span>
              <% else %>
                <span
                  :for={need <- task.spec.needs}
                  class="badge badge-outline badge-sm"
                  data-need={need}
                >
                  {Tasks.need_label(need)}
                </span>
              <% end %>
            </div>

            <div class="flex flex-col gap-1 text-sm">
              <span class="text-base-content/70">{gettext("Endpoints in use:")}</span>
              <%= if task.endpoints == [] do %>
                <span class="text-base-content/60">
                  {gettext("None chosen; the caller names an endpoint per call.")}
                </span>
              <% end %>
              <div
                :for={row <- task.endpoints}
                class="flex flex-wrap items-center gap-2"
                data-endpoint-uuid={row.endpoint.uuid}
              >
                <.link
                  navigate={PhoenixKitAI.Routes.ai_path() <> "/endpoints/#{row.endpoint.uuid}/edit"}
                  class="link link-hover"
                >
                  {row.endpoint.name}
                </.link>
                <code class="text-xs text-base-content/60">{row.endpoint.model}</code>
                <.fitness_badge fitness={row.fitness} />
              </div>
            </div>

            <TaskModelPicker.recommendations
              id={task.dom_id <> "-recommendations"}
              recommendations={task.recommendations}
              scope={assigns[:phoenix_kit_current_scope]}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:fitness, :any, required: true)

  defp fitness_badge(%{fitness: :fit} = assigns) do
    ~H"""
    <span class="badge badge-success badge-sm" data-fitness="fit">
      <.icon name="hero-check" class="w-3 h-3" /> {gettext("Fits")}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unfit, missing}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(missing))

    ~H"""
    <span class="badge badge-error badge-sm" data-fitness="unfit">
      <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Lacks: %{needs}", needs: @needs)}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unknown, unclear}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(unclear))

    ~H"""
    <span class="badge badge-warning badge-sm" data-fitness="unknown">
      ? {gettext("Not verified: %{needs}", needs: @needs)}
    </span>
    """
  end
end
