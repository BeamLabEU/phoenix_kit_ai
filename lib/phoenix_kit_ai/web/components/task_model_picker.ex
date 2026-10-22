defmodule PhoenixKitAI.Web.Components.TaskModelPicker do
  @moduledoc """
  The model picker a module's settings form shows for an AI task
  (`PhoenixKitAI.TaskSpec`): the enabled endpoints with a badge for whether
  each can do what the task needs, and a collapsible block of
  recommendations — the cheapest fit models and the ones that already
  worked in the task (`PhoenixKitAI.Recommendations`).

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
  a field (the AI → Tasks page).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Capabilities, Endpoint, Recommendations, Request, Tasks}
  alias PhoenixKitAI.Web.Components.CapabilityBadges
  alias PhoenixKitWeb.Components.Core.Icon
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
    assigns = assign(assigns, :can_create?, can_create?(assigns.scope))

    ~H"""
    <%!-- `open` is the browser's state; without this a re-render closes the panel. --%>
    <details
      id={@id}
      class="collapse collapse-arrow min-w-0 bg-base-200"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="collapse-title text-sm font-medium">
        {gettext("Recommended models")}
      </summary>
      <div class="collapse-content flex flex-col gap-4 text-sm">
        <section id={@id <> "-cheapest"} class="flex flex-col gap-2">
          <h4 class="font-semibold">{gettext("Fit and cheapest")}</h4>
          <p class="text-base-content/70" data-estimate={@recommendations.estimate}>
            {estimate_text(@recommendations)}
          </p>
          <p :if={@recommendations.cheapest == []} data-recommended-empty class="text-base-content/60">
            {gettext("No model of the connected catalogues is known to fit this task.")}
          </p>
          <div :if={@recommendations.cheapest != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>{gettext("Model")}</th>
                  <th>{gettext("Provider")}</th>
                  <th class="text-right">{price_heading(@recommendations.estimate)}</th>
                  <th class="text-right">{gettext("Context")}</th>
                  <th :if={@can_create?}></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @recommendations.cheapest}
                  data-recommended-model={row.model}
                >
                  <td>
                    <div class="font-medium">{row.name}</div>
                    <code class="text-xs text-base-content/60">{row.model}</code>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <CapabilityBadges.badges capabilities={row.capabilities} />
                      <span
                        :if={row.deprecated?}
                        data-lifecycle="deprecated"
                        class="badge badge-warning badge-xs h-auto"
                      >
                        {gettext("Retiring")}
                      </span>
                      <span
                        :for={note <- row.notes}
                        data-note={note}
                        class="badge badge-ghost badge-xs h-auto"
                      >
                        {note_label(note)}
                      </span>
                    </div>
                  </td>
                  <td>{provider_label(row.provider)}</td>
                  <td class="text-right whitespace-nowrap">{price_cell(row, @recommendations.estimate)}</td>
                  <td class="text-right">{context_cell(row.context_length)}</td>
                  <td :if={@can_create?} class="text-right">
                    <.link
                      navigate={create_path(row)}
                      class="btn btn-xs btn-outline"
                      data-create-endpoint
                    >
                      <Icon.icon name="hero-plus" class="w-3 h-3" />
                      {gettext("Create endpoint with this model")}
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section id={@id <> "-worked"} class="flex flex-col gap-2">
          <h4 class="font-semibold">{gettext("Already worked in this task")}</h4>
          <p :if={@recommendations.worked == []} data-worked-empty class="text-base-content/60">
            {gettext("No calls in the last 30 days.")}
          </p>
          <div :if={@recommendations.worked != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>{gettext("Model")}</th>
                  <th>{gettext("Provider")}</th>
                  <th class="text-right">{gettext("Calls")}</th>
                  <th class="text-right">{gettext("Average cost")}</th>
                  <th class="text-right">{gettext("Errors")}</th>
                  <th class="text-right">{gettext("Average latency")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @recommendations.worked} data-worked-model={row.model}>
                  <td>
                    <code class="text-xs">{row.model}</code>
                    <div :if={row.notes != [] or !row.cost_reported?} class="flex flex-wrap gap-1 mt-1">
                      <span
                        :for={note <- row.notes}
                        data-note={note}
                        class="badge badge-ghost badge-xs h-auto"
                      >
                        {note_label(note)}
                      </span>
                      <span
                        :if={!row.cost_reported?}
                        data-note="cost_not_reported"
                        class="badge badge-ghost badge-xs h-auto"
                      >
                        {note_label(:cost_not_reported)}
                      </span>
                    </div>
                  </td>
                  <td>{provider_label(row.provider)}</td>
                  <td class="text-right">{row.calls}</td>
                  <td class="text-right">{worked_cost(row)}</td>
                  <td class="text-right">{percent(row.error_share)}</td>
                  <td class="text-right">{latency(row.avg_latency_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </details>
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

  defp can_create?(%Scope{} = scope),
    do: Scope.has_module_access?(scope, PhoenixKitAI.module_key())

  defp can_create?(_scope), do: false

  defp create_path(row) do
    query =
      [name: row.name, model: row.model, integration_uuid: row.integration_uuid]
      |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
      |> URI.encode_query()

    PhoenixKitAI.Routes.ai_path() <> "/endpoints/new?" <> query
  end

  defp estimate_text(%{estimate: :declared, tokens: {input, output}}),
    do:
      gettext(
        "Price of a call of about %{input} input and %{output} output tokens, as the task declares.",
        input: format_number(input),
        output: format_number(output)
      )

  defp estimate_text(%{estimate: :journal, tokens: {input, output}}),
    do:
      gettext(
        "Price of a call of about %{input} input and %{output} output tokens, the median of this task's calls in the last 30 days.",
        input: format_number(input),
        output: format_number(output)
      )

  defp estimate_text(%{estimate: :rough}),
    do:
      gettext(
        "The size of a call is not known yet, so the models are ranked by the input price alone (rough)."
      )

  defp price_heading(:rough), do: gettext("Input, per 1M tokens")
  defp price_heading(_estimate), do: gettext("≈ Price per call")

  defp price_cell(%{price_per_call: price}, _estimate) when is_number(price),
    do: "≈ " <> format_price(price)

  defp price_cell(%{input_price_per_million: price}, :rough) when is_number(price),
    do: format_price(price)

  defp price_cell(_row, _estimate), do: gettext("price not known")

  # Dollars, through the usage tab's format (a millionth of a dollar is its
  # unit); a price below that says so instead of showing $0.00.
  defp format_price(dollars) do
    micro = round(dollars * 1_000_000)

    if micro == 0 and dollars > 0,
      do: "<$0.000001",
      else: Request.format_cost(micro)
  end

  defp worked_cost(%{avg_cost: nil}), do: "—"
  defp worked_cost(%{avg_cost: avg}), do: Request.format_cost(round(avg))

  defp percent(share), do: "#{round(share * 100)}%"

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{round(ms)} ms"

  defp context_cell(nil), do: "—"
  defp context_cell(length), do: format_number(length)

  defp provider_label(:openrouter), do: "OpenRouter"
  defp provider_label(:anthropic), do: "Anthropic"
  defp provider_label(nil), do: "—"

  defp provider_label(key) when is_binary(key) do
    case List.keyfind(Endpoint.provider_options(), key, 1) do
      {label, _key} -> label
      nil -> key
    end
  end

  defp provider_label(other), do: to_string(other)

  defp note_label(:free), do: gettext("free — the operator's limits and terms apply")
  defp note_label(:alias), do: gettext("alias model, may change")
  defp note_label(:cost_not_reported), do: gettext("cost is not counted")

  defp note_label(:json_schema_openrouter_only),
    do: gettext("JSON schema only through OpenRouter")

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
