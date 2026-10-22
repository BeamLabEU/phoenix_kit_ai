defmodule PhoenixKitAI.GuardWatch do
  @moduledoc """
  Notices when a task's model stops fitting it, and signals it
  (`PhoenixKitAI.GuardEvents.model_unfit/4`: one event a day per task and
  endpoint).

  The process (started by `PhoenixKitAI.children/0`) keeps, for every
  enabled task and every endpoint it uses now (`Tasks.endpoints/1`), the last
  fitness that was known (`:fit` or `:unfit`; not knowing leaves the last
  known one as it was). It looks again when the capability cache changes
  (`{:capabilities_refreshed, _}`: a catalogue refresh, a model alias that
  moved) and when an endpoint is created, saved or deleted. A pair that was
  `:fit` and is unfit now is signalled. A pair first seen unfit — at start,
  or an endpoint a task has just begun to use — is not: it is shown on the
  Tasks page, and a consumer's form refuses to save an unfit choice.

  Each node runs its own; the event's dedupe key keeps the signal to one.

  After every look it emits `[:phoenix_kit_ai, :guard_watch, :look]`
  (measurement `pairs`, metadata `trigger`: `:first_look`, `:capabilities`
  or `:endpoint`), so whoever needs to know that a change has been looked at
  can wait for it.
  """

  use GenServer

  require Logger

  alias PhoenixKitAI.{Capabilities, GuardEvents, Tasks}
  alias PhoenixKitAI.Web.MessageShape

  @endpoint_events [:endpoint_created, :endpoint_updated, :endpoint_deleted]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Capabilities.subscribe()
    PhoenixKitAI.subscribe_endpoints()
    {:ok, %{last: %{}}, {:continue, :first_look}}
  end

  @impl true
  def handle_continue(:first_look, state),
    do: {:noreply, %{state | last: look(state.last, :first_look)}}

  @impl true
  def handle_info({:capabilities_refreshed, _base_urls}, state),
    do: {:noreply, %{state | last: look(state.last, :capabilities)}}

  def handle_info({event, _uuid}, state) when event in @endpoint_events,
    do: {:noreply, %{state | last: look(state.last, :endpoint)}}

  def handle_info(msg, state) do
    Logger.debug(fn -> "[PhoenixKitAI.GuardWatch] unhandled: #{MessageShape.describe(msg)}" end)
    {:noreply, state}
  end

  defp look(last, trigger) do
    last = compare(last, trigger)

    :telemetry.execute(
      [:phoenix_kit_ai, :guard_watch, :look],
      %{pairs: map_size(last)},
      %{trigger: trigger}
    )

    last
  end

  # The first look only records what is known; later ones signal fit → unfit.
  defp compare(last, trigger) do
    now = fitness_now()

    if trigger != :first_look do
      for {pair, {spec, endpoint, {:unfit, missing}}} <- now,
          last[pair] == :fit,
          do: GuardEvents.model_unfit(spec, endpoint, missing)
    end

    now
    |> Map.new(fn {pair, {_spec, _endpoint, fitness}} -> {pair, known(fitness) || last[pair]} end)
    |> Map.reject(fn {_pair, fitness} -> is_nil(fitness) end)
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI.GuardWatch] fitness not checked: #{inspect(error.__struct__)}"
      )

      last
  end

  defp fitness_now do
    for spec <- Tasks.list(),
        spec.enabled,
        endpoint <- Tasks.endpoints(spec),
        into: %{},
        do: {{spec.key, endpoint.uuid}, {spec, endpoint, Tasks.fitness(spec, endpoint)}}
  end

  defp known(:fit), do: :fit
  defp known({:unfit, _missing}), do: :unfit
  defp known(_unknown), do: nil
end
