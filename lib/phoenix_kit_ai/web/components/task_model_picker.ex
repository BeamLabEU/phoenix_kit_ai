defmodule PhoenixKitAI.Web.Components.TaskModelPicker do
  @moduledoc """
  The model picker a module's settings form shows for an AI task
  (`PhoenixKitAI.TaskSpec`): the enabled endpoints with a badge for whether
  each can do what the task needs, and a collapsible block of
  recommendations (`PhoenixKitAI.Web.Components.RecommendationsPanel`) —
  filtered by images, documents and image generation, the models that
  already worked in the task, then those that can do everything needed,
  those that may, and the experimental ones (`PhoenixKitAI.Recommendations`).

      <TaskModelPicker.picker
        task="warehouse.inventory_photo"
        field={@form[:endpoint_uuid]}
        scope={@phoenix_kit_current_scope}
      />

  The badges: ✓ the endpoint's model has everything the task needs, ✗ it
  lacks something (named), ? the catalogue and the endpoint's declaration
  do not say. The picker only shows; refusing an unfit choice on save is the
  form's job (`PhoenixKitAI.Tasks.check_selection/2`).

  Each recommended model has a «Create endpoint with this model» link to the
  AI module's endpoint form with the name, the model and the same operator's
  integration filled in; the person saves it. The link is shown only to a
  scope holding the `ai` permission (`scope`).

  A function component: it reads the endpoints and, unless `recommendations`
  is passed, the recommendations (3–4 queries) every time it renders. **In a
  form with `phx-change`, pass `recommendations`** — compute
  `PhoenixKitAI.Recommendations.for_task/2` once (in `mount` or when the
  catalogues change) — or each keystroke pays for them. The element ids
  derive from the field's id, so give each picker on a page its own field.

  `recommendations/1` is the panel alone, for pages that list a task without
  a field (the AI → Tasks page). It is a live component (its filters are
  its own state), so it needs a LiveView around it.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  alias PhoenixKitAI.{Capabilities, Recommendations, Tasks}
  alias PhoenixKitAI.Web.Components.{CapabilityBadges, RecommendationsPanel}
  alias PhoenixKitWeb.Components.Core.Select

  attr(:task, :any, required: true, doc: "the task's key or its `%TaskSpec{}`")
  attr(:field, Phoenix.HTML.FormField, required: true, doc: "holds the chosen endpoint uuid")
  attr(:scope, :any, default: nil, doc: "the current scope; the create link needs `ai`")
  attr(:recommendations, :map, default: nil, doc: "`Recommendations.for_task/2`, else computed")
  attr(:id, :string, default: nil, doc: "defaults to the field's id")
  attr(:label, :string, default: nil)
  attr(:prompt, :string, default: nil)

  def picker(assigns) do
    options =
      assigns.task
      |> Tasks.endpoint_options()
      |> Enum.map(&Map.put(&1, :capabilities, Capabilities.for_endpoint(&1.endpoint)))

    id = assigns.id || assigns.field.id

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:options, options)
      |> assign(:select_options, Enum.map(options, &option/1))
      |> assign(:selected, Enum.find(options, &(&1.endpoint.uuid == assigns.field.value)))
      |> assign(:recs, assigns.recommendations || Recommendations.for_task(assigns.task))

    ~H"""
    <div id={@id <> "-picker"} class="flex flex-col gap-2" data-task-model-picker>
      <Select.select
        field={@field}
        id={@id}
        label={@label}
        prompt={@prompt}
        options={@select_options}
      />
      <div :if={@selected} class="flex flex-wrap items-center gap-1 text-sm">
        <.fitness_badge fitness={@selected.fitness} />
        <CapabilityBadges.badges capabilities={@selected.capabilities} />
      </div>
      <.recommendations id={@id <> "-recommendations"} recommendations={@recs} scope={@scope} />
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:recommendations, :map, required: true, doc: "`Recommendations.for_task/2`")
  attr(:scope, :any, default: nil)

  def recommendations(assigns) do
    ~H"""
    <.live_component
      module={RecommendationsPanel}
      id={@id}
      recommendations={@recommendations}
      scope={@scope}
    />
    """
  end

  attr(:fitness, :any, required: true)

  defp fitness_badge(%{fitness: :fit} = assigns) do
    ~H"""
    <span class="badge badge-success badge-sm" data-selected-fitness="fit">
      ✓ {gettext("Fits")}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unfit, missing}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(missing))

    ~H"""
    <span class="badge badge-error badge-sm" data-selected-fitness="unfit">
      ✗ {gettext("Lacks: %{needs}", needs: @needs)}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unknown, unclear}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(unclear))

    ~H"""
    <span class="badge badge-warning badge-sm" data-selected-fitness="unknown">
      ? {gettext("Not verified: %{needs}", needs: @needs)}
    </span>
    """
  end

  # `<option>` text is plain text, so the badge is a mark in the label.
  defp option(%{endpoint: endpoint, fitness: fitness, capabilities: caps}),
    do: {"#{endpoint.name} — #{endpoint.model}  #{mark(fitness)}#{can_do(caps)}", endpoint.uuid}

  defp can_do(%Capabilities{} = caps) do
    case Enum.filter(Capabilities.declarable(), &(Map.fetch!(caps, &1) == :yes)) do
      [] -> ""
      flags -> " · " <> Tasks.need_labels(flags)
    end
  end

  defp can_do(_caps), do: ""

  defp mark(:fit), do: "✓"

  defp mark({:unfit, missing}),
    do: "✗ " <> gettext("no %{needs}", needs: Tasks.need_labels(missing))

  defp mark({:unknown, _unclear}), do: "? " <> gettext("not verified")
end
