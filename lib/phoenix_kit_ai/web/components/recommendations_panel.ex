defmodule PhoenixKitAI.Web.Components.RecommendationsPanel do
  @moduledoc """
  The collapsible block of model recommendations for an AI task
  (`PhoenixKitAI.Recommendations.for_task/2`): filters for images,
  documents and image generation (the task's own needs at first), then the
  models that already worked in the task, the ones that can do everything
  needed (verified), the ones that may (nothing they lack, something not
  verified), and the experimental-looking ones collapsed at the end. Price
  orders the rows inside each group.

  A live component, so that a click on a filter regroups the models here
  without the page that shows it handling an event: the regrouping reads
  the catalogues from the capability cache (`Recommendations.refilter/2`),
  not the journal. The person's filters outlive the page's re-renders.
  The recommendations it is given are kept in its state, so they hold no
  catalogue (`for_task/2` never puts one in).
  Rendered through `PhoenixKitAI.Web.Components.TaskModelPicker.recommendations/1`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitAI.Gettext

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Endpoint, Recommendations, Request, Tasks}
  alias PhoenixKitAI.Web.Components.CapabilityBadges
  alias PhoenixKitWeb.Components.Core.Icon

  @impl true
  def update(assigns, socket) do
    recs = assigns.recommendations

    socket =
      cond do
        socket.assigns[:base] == recs ->
          socket

        socket.assigns[:filters] in [nil, recs.filters] ->
          assign(socket, base: recs, recs: recs, filters: recs.filters)

        true ->
          assign(socket, base: recs, recs: Recommendations.refilter(recs, socket.assigns.filters))
      end

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:can_create?, can_create?(assigns[:scope]))}
  end

  @impl true
  def handle_event("filter", %{"capability" => capability}, socket) do
    case Enum.find(Recommendations.filterable(), &(Atom.to_string(&1) == capability)) do
      nil ->
        {:noreply, socket}

      flag ->
        filters =
          if flag in socket.assigns.filters,
            do: List.delete(socket.assigns.filters, flag),
            else: [flag | socket.assigns.filters]

        recs = Recommendations.refilter(socket.assigns.base, filters)
        {:noreply, assign(socket, recs: recs, filters: recs.filters)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :none?,
        assigns.recs.verified == [] and assigns.recs.possible == [] and
          assigns.recs.experimental == []
      )

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
      <div class="collapse-content flex min-w-0 flex-col gap-4 text-sm">
        <div id={@id <> "-filters"} class="flex flex-wrap items-center gap-2">
          <span class="text-base-content/70">{gettext("Must handle:")}</span>
          <button
            :for={flag <- Recommendations.filterable()}
            type="button"
            phx-click="filter"
            phx-value-capability={flag}
            phx-target={@myself}
            data-filter={flag}
            aria-pressed={to_string(flag in @filters)}
            title={CapabilityBadges.explain_text(flag)}
            class={[
              "btn btn-xs transition-colors",
              if(flag in @filters, do: "btn-primary", else: "btn-outline")
            ]}
          >
            {CapabilityBadges.label(flag)}
          </button>
        </div>

        <CapabilityBadges.glossary id={@id <> "-glossary"} />

        <section id={@id <> "-worked"} class="flex min-w-0 flex-col gap-2">
          <h4 class="font-semibold">{gettext("Models used in this task")}</h4>
          <p :if={@recs.worked == []} data-worked-empty class="text-base-content/60">
            {gettext("No calls in the last 30 days.")}
          </p>
          <div :if={@recs.worked != []} class="overflow-x-auto">
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
                <tr :for={row <- @recs.worked} data-worked-model={row.model}>
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

        <p class="text-base-content/70" data-estimate={@recs.estimate}>
          {estimate_text(@recs)}
        </p>
        <p :if={@none?} data-recommended-empty class="text-base-content/60">
          {gettext("No model of the connected catalogues is known to fit this task.")}
        </p>

        <section
          :if={@recs.verified != []}
          id={@id <> "-verified"}
          data-group="verified"
          class="flex min-w-0 flex-col gap-2"
        >
          <h4 class="font-semibold">{gettext("Can do everything needed (verified)")}</h4>
          <.model_table rows={@recs.verified} estimate={@recs.estimate} can_create?={@can_create?} />
        </section>

        <section
          :if={@recs.possible != []}
          id={@id <> "-possible"}
          data-group="possible"
          class="flex min-w-0 flex-col gap-2"
        >
          <h4 class="font-semibold">{gettext("May be able to (not verified)")}</h4>
          <.model_table rows={@recs.possible} estimate={@recs.estimate} can_create?={@can_create?} />
        </section>

        <details
          :if={@recs.experimental != []}
          id={@id <> "-experimental"}
          data-group="experimental"
          class="collapse collapse-arrow min-w-0 border border-base-300"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="collapse-title text-sm font-semibold">
            {gettext("Experimental (%{count})", count: length(@recs.experimental))}
          </summary>
          <div class="collapse-content flex min-w-0 flex-col gap-2">
            <p class="text-base-content/60">
              {gettext(
                "Previews, betas, free variants, aliases and models without a price: they can change or disappear."
              )}
            </p>
            <.model_table
              rows={@recs.experimental}
              estimate={@recs.estimate}
              can_create?={@can_create?}
            />
          </div>
        </details>
      </div>
    </details>
    """
  end

  attr(:rows, :list, required: true)
  attr(:estimate, :atom, required: true)
  attr(:can_create?, :boolean, required: true)

  defp model_table(assigns) do
    ~H"""
    <div class="min-w-0 overflow-x-auto">
      <table class="table table-xs">
        <thead>
          <tr>
            <th>{gettext("Model")}</th>
            <th>{gettext("Provider")}</th>
            <th class="text-right">{price_heading(@estimate)}</th>
            <th class="text-right" title={CapabilityBadges.explain_text(:context)}>
              {gettext("Context")}
            </th>
            <th :if={@can_create?}></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} data-recommended-model={row.model}>
            <td>
              <div class="font-medium">{row.name}</div>
              <code class="text-xs text-base-content/60">{row.model}</code>
              <div class="flex flex-wrap gap-1 mt-1">
                <span
                  :if={Map.get(row, :unverified, []) != []}
                  data-unverified
                  class="badge badge-ghost badge-xs h-auto"
                  title={CapabilityBadges.catalogue_hint()}
                >
                  ? {gettext("Not verified: %{needs}", needs: Tasks.need_labels(row.unverified))}
                </span>
                <CapabilityBadges.badges capabilities={row.capabilities} context={:catalogue} />
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
            <td class="text-right whitespace-nowrap">{price_cell(row, @estimate)}</td>
            <td class="text-right">{context_cell(row.context_length)}</td>
            <td :if={@can_create?} class="text-right">
              <.link navigate={create_path(row)} class="btn btn-xs btn-outline" data-create-endpoint>
                <Icon.icon name="hero-plus" class="w-3 h-3" />
                {gettext("Create endpoint with this model")}
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp can_create?(%Scope{} = scope),
    do: Scope.has_module_access?(scope, PhoenixKitAI.module_key())

  defp can_create?(_scope), do: false

  defp create_path(row) do
    query =
      [
        name: row.name,
        model: row.model,
        integration_uuid: row.integration_uuid,
        source_endpoint_uuid: row[:source_endpoint_uuid],
        provider: to_string(row.provider)
      ]
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
  defp provider_label(:deepseek), do: "DeepSeek"
  defp provider_label(:mistral), do: "Mistral"
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

  defp note_label(:manual_price), do: gettext("price entered by hand")

  defp note_label(:capabilities_not_reported),
    do: gettext("the operator does not report capabilities")

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
