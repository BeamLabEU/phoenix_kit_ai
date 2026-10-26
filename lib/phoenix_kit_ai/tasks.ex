defmodule PhoenixKitAI.Tasks do
  @moduledoc """
  The registry of AI tasks (`PhoenixKitAI.TaskSpec`) and whether an endpoint
  fits one.

  ## Discovery

  Every module in `PhoenixKit.ModuleRegistry.all_modules/0` that exports
  `ai_tasks/0` declares its tasks there (duck-typed, like
  `handle_ai_usage/1`); this module declares `ai.translation` and
  `ai.playground` itself. The registry is built on first use and again
  only when the set of registered modules changes — never per call. A task
  of a module that is switched off is listed with `enabled: false`.

  A host app that is not a kit module lists its own modules in
  `config :phoenix_kit_ai, task_providers: [MyApp.AI]` (read at run time);
  each exports `ai_tasks/0` like a kit module. Providers are read after the
  registered modules; a module listed both ways counts as a kit module. A
  provider has no module switch, so its tasks are always `enabled: true`
  (`provider?/1`). A listed provider that cannot be loaded or exports no
  `ai_tasks/0` is warned about; a bad config entry is ignored with a
  warning. A change to the registered modules or to the provider list
  rebuilds the registry. `PhoenixKitAI.Tasks.Builder` is the one writer:
  builds are serial and for the current config, each `ai_tasks/0` runs in
  its own task with a timeout, and a call from inside a build answers from
  the last cached registry. A module whose `ai_tasks/0` fails or times out
  keeps the tasks it last declared until it answers.

  Two declarations of one key: the first wins (kit modules before
  providers, providers in config order), with a warning naming both; the
  dropped one is listed by `collisions/0` and shown on AI → Tasks.

  ## Fitness

  `fitness/2` compares a task's hard needs (`:vision`, `:file_input`,
  `:image_output`, `:tools`, `:json_schema`) with `PhoenixKitAI.Capabilities.for_endpoint/1` (the
  catalogue, the endpoint's declaration filling what it does not know):
  `:fit`, `{:unfit, missing}` when the model says no to something, or
  `{:unknown, unclear}` when nobody knows. `:json` is soft — the module falls
  back to asking for JSON in the prompt — and never makes an endpoint unfit.

  Settings forms of consumers use `endpoint_options/1` (the enabled
  endpoints with their fitness) and `check_selection/2` before saving.
  """

  use Gettext, backend: PhoenixKitAI.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKitAI.{Capabilities, Endpoint, TaskSpec}
  alias PhoenixKitAI.Web.MessageShape

  @registry_key {__MODULE__, :registry}
  # How long a build in which a module's `ai_tasks/0` failed is kept before
  # the next access builds again (`:task_registry_retry_ms` app env).
  @retry_ms :timer.minutes(1)

  @type fitness ::
          :fit | {:unfit, [TaskSpec.need()]} | {:unknown, [TaskSpec.need()]}

  # ===========================================
  # REGISTRY
  # ===========================================

  @doc "Every declared task, by key, each marked whether its module is on."
  @spec list() :: [TaskSpec.t()]
  def list do
    state = state()

    state.specs
    |> Map.values()
    |> Enum.sort_by(& &1.key)
    |> Enum.map(&with_enabled(&1, state))
  end

  @doc """
  One consistent read for AI → Tasks: the tasks (as `list/0`), which of
  their declaring modules are app providers, and the dropped declarations
  (as `collisions/0`) — all from the same registry snapshot.
  """
  @spec overview() :: %{tasks: [TaskSpec.t()], providers: MapSet.t(), collisions: [map()]}
  def overview do
    state = state()

    tasks =
      state.specs
      |> Map.values()
      |> Enum.sort_by(& &1.key)
      |> Enum.map(&with_enabled(&1, state))

    %{tasks: tasks, providers: state.providers, collisions: state.collisions}
  end

  @doc "The task declared under `key`, or `nil`."
  @spec get(String.t()) :: TaskSpec.t() | nil
  def get(key) when is_binary(key) do
    state = state()

    case Map.get(state.specs, key) do
      nil -> nil
      spec -> with_enabled(spec, state)
    end
  end

  def get(_key), do: nil

  @doc false
  # The task a call names, for the call-time check: the declaration, or nil
  # for no task or an unknown key — the call goes on, and an unknown key is
  # logged once per key.
  @spec for_call(term()) :: TaskSpec.t() | nil
  def for_call(nil), do: nil

  def for_call(key) when is_binary(key) do
    case Map.get(state().specs, key) do
      nil ->
        warn_unknown_once(key)
        nil

      spec ->
        spec
    end
  end

  def for_call(_key), do: nil

  @doc """
  The declarations that lost a key collision and were dropped, as
  `%{key, kept: module, dropped: module}` — shown on AI → Tasks so a
  provider's task replaced by a kit module's (or an earlier provider's) is
  not a silent substitution.
  """
  @spec collisions() :: [%{key: String.t(), kept: module(), dropped: module()}]
  def collisions, do: state().collisions

  @doc """
  Whether `spec` comes from a host app's `config :phoenix_kit_ai,
  task_providers:` entry rather than a registered kit module. A provider
  has no module switch, so its tasks are always enabled.
  """
  @spec provider?(TaskSpec.t()) :: boolean()
  def provider?(%TaskSpec{module: module}), do: MapSet.member?(state().providers, module)

  # A build where a module's `ai_tasks/0` failed is kept only for the retry
  # interval; the next access after that builds again (at most once per
  # interval while the callback keeps failing). The cache key is the
  # registered modules AND the raw `task_providers` config, so a change to
  # either rebuilds; the config is validated (and warned about) only while
  # building, never per lookup.
  #
  # ONE writer. Reads are a lock-free `:persistent_term` hit; on a miss or a
  # due retry the caller asks `PhoenixKitAI.Tasks.Builder`, which works out
  # the CURRENT key itself, answers from the cache when it already fits and
  # otherwise builds — so builds are serial, always for the current config,
  # and the carry-forward always reads the builder's own last state. Each
  # `ai_tasks/0` runs in its own task with a timeout, so a hanging one costs
  # one timeout, never blocks the builder. A call from inside a build (the
  # builder, a callback task or anything it `Task.async`s) answers from the
  # last cached registry instead of asking the builder again.
  #
  # Without the builder (it is one of `PhoenixKitAI.children/0`; a host or a
  # test that does not start them) the caller builds a state for ITSELF ONLY
  # — never written to the cache, which only the builder writes — with the
  # same unlinked, time-bounded callback runner; a call from inside that
  # build (the caller or any `$callers` descendant) answers from the cache.
  @building {__MODULE__, :building}
  @callback_mark {__MODULE__, :callback}
  @callback_timeout 5_000
  @ensure_timeout 30_000

  defp state do
    key = cache_key()

    case current(key) do
      {:ok, state} -> state
      :rebuild -> ensure()
    end
  end

  defp ensure do
    builder = Process.whereis(PhoenixKitAI.Tasks.Builder)

    cond do
      reentry?(builder) ->
        last_cached()

      is_pid(builder) ->
        try do
          GenServer.call(builder, :ensure, ensure_timeout())
        catch
          :exit, _ -> last_cached()
        end

      true ->
        inline_build()
    end
  end

  # A call from inside a build: the builder itself, this process mid-inline
  # build, a callback process, or anything a callback started (a `$callers`
  # ancestor is a callback). Only CALLBACK processes are marked, so an
  # unrelated task the builder's caller started earlier reads normally.
  defp reentry?(builder) do
    (is_pid(builder) and builder == self()) or Process.get(@building) == true or
      Process.get(@callback_mark) == true or
      Enum.any?(List.wrap(Process.get(:"$callers")), &callback_process?/1)
  end

  # Callbacks always run on this node; `Process.info/2` raises on a remote pid.
  defp callback_process?(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> List.keyfind(dict, @callback_mark, 0) == {@callback_mark, true}
      _ -> false
    end
  end

  defp callback_process?(_other), do: false

  @doc false
  # Run by `PhoenixKitAI.Tasks.Builder`, the one writer: the current key's
  # state, built (callbacks isolated in tasks) when the cache does not fit.
  @spec ensure_built() :: map()
  def ensure_built do
    key = cache_key()

    case current(key) do
      {:ok, state} ->
        state

      :rebuild ->
        {state, failed_at} = build_state(key)
        :persistent_term.put(@registry_key, {key, state, failed_at})
        state
    end
  end

  # For this caller only: never stored.
  defp inline_build do
    Process.put(@building, true)

    try do
      {state, _failed_at} = build_state(cache_key())
      state
    after
      Process.delete(@building)
    end
  end

  # One module's callback in its own UNLINKED process, bounded by the
  # callback timeout: a crash (its own or a linked child's) or a timeout is
  # that module's failure (carry-forward, retry) and never reaches the
  # caller. The reply goes to a process alias, dropped once the caller
  # stops waiting, so a late answer never lands in anyone's mailbox. A
  # watchdog kills the callback when its deadline passes or its caller dies,
  # so it never outlives either. `$callers` is passed on and the process is
  # marked, so a call back into this module from it (or anything it
  # starts) is recognised as re-entry.
  defp isolated(fun) do
    parent = self()
    reply_to = Process.alias()
    callers = [parent | List.wrap(Process.get(:"$callers"))]
    timeout = callback_timeout()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        Process.put(@callback_mark, true)
        watchdog(self(), parent, timeout)
        send(reply_to, {reply_to, fun.()})
      end)

    receive do
      {^reply_to, result} ->
        Process.demonitor(monitor, [:flush])
        drop_alias(reply_to)
        result

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        drop_alias(reply_to)
        :error
    after
      timeout ->
        drop_alias(reply_to)
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end

  # No further reply can arrive after the unalias; one that arrived just
  # before it is taken out here.
  defp drop_alias(reply_to) do
    Process.unalias(reply_to)

    receive do
      {^reply_to, _late} -> :ok
    after
      0 -> :ok
    end
  end

  defp watchdog(callback, caller, timeout) do
    spawn(fn ->
      callback_ref = Process.monitor(callback)
      caller_ref = Process.monitor(caller)

      receive do
        {:DOWN, ^callback_ref, :process, _, _} -> :ok
        {:DOWN, ^caller_ref, :process, _, _} -> Process.exit(callback, :kill)
      after
        timeout -> Process.exit(callback, :kill)
      end
    end)
  end

  defp last_cached do
    case :persistent_term.get(@registry_key, nil) do
      {_key, state, _failed_at} -> state
      _ -> %{specs: %{}, collisions: [], providers: MapSet.new(), declared: %{}}
    end
  end

  defp cache_key,
    do: {discoverable_modules(), Application.get_env(:phoenix_kit_ai, :task_providers, [])}

  defp current(key) do
    case :persistent_term.get(@registry_key, nil) do
      {^key, state, nil} ->
        {:ok, state}

      {^key, state, failed_at} ->
        if now() - failed_at < retry_ms(), do: {:ok, state}, else: :rebuild

      _ ->
        :rebuild
    end
  end

  # The state for `key` and its failed_at (nil when every callback answered).
  defp build_state({modules, raw_providers}) do
    # A module listed both ways is a kit module: its switch, asked once.
    providers = configured_providers(raw_providers) -- modules
    previous = previous_declarations()
    {state, failed} = build(modules, providers, previous, &isolated/1)

    failed_at =
      if failed != [] do
        Logger.warning(
          "[PhoenixKitAI] ai_tasks/0 of #{Enum.map_join(failed, ", ", &inspect/1)} failed; " <>
            "their last known tasks are kept (none before a first answer) and they are " <>
            "asked again in #{div(retry_ms(), 1000)} s at the earliest"
        )

        now()
      end

    {state, failed_at}
  end

  # What each module answered the last time its `ai_tasks/0` worked.
  defp previous_declarations do
    case :persistent_term.get(@registry_key, nil) do
      {_key, %{declared: declared}, _failed_at} -> declared
      _ -> %{}
    end
  end

  defp callback_timeout,
    do:
      Application.get_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms, @callback_timeout)

  defp ensure_timeout,
    do: Application.get_env(:phoenix_kit_ai, :task_registry_build_timeout_ms, @ensure_timeout)

  defp retry_ms, do: Application.get_env(:phoenix_kit_ai, :task_registry_retry_ms, @retry_ms)

  defp now, do: System.monotonic_time(:millisecond)

  # This module's own tasks are always in, whether or not the host's module
  # registry lists it.
  defp discoverable_modules do
    Enum.uniq([PhoenixKitAI | PhoenixKit.ModuleRegistry.all_modules()])
  rescue
    _ -> [PhoenixKitAI]
  end

  # `config :phoenix_kit_ai, task_providers: [MyApp.AI]` — a host app's own
  # modules declaring tasks without being kit modules. Read at run time.
  defp configured_providers(list) when is_list(list) do
    {items, tail} = proper_prefix(list, [])

    if tail != [] do
      Logger.warning(
        "[PhoenixKitAI] :task_providers is not a proper list; its tail is ignored: " <>
          MessageShape.describe(tail)
      )
    end

    {atoms, others} = Enum.split_with(items, &(is_atom(&1) and not is_nil(&1)))

    if others != [] do
      Logger.warning(
        "[PhoenixKitAI] :task_providers entries that are not module names are ignored: " <>
          Enum.map_join(others, ", ", &MessageShape.describe/1)
      )
    end

    Enum.uniq(atoms)
  end

  defp configured_providers(other) do
    Logger.warning(
      "[PhoenixKitAI] :task_providers must be a list of modules; ignored: " <>
        MessageShape.describe(other)
    )

    []
  end

  # `[a, b | tail]` → `{[a, b], tail}`; `tail` is `[]` for a proper list.
  defp proper_prefix([head | rest], acc), do: proper_prefix(rest, [head | acc])
  defp proper_prefix(tail, acc), do: {Enum.reverse(acc), tail}

  # A module whose `ai_tasks/0` fails keeps the tasks it declared last time
  # it answered (`previous`), in its place in the order — so a transient
  # failure never hands its keys to a later declarer. Before a first answer
  # there is nothing to keep: its tasks are missing until the retry, and a
  # later declarer of the same key holds it meanwhile (the alternative,
  # holding back every later declaration, would let one broken module hide
  # every provider's tasks).
  defp build(modules, providers, previous, run) do
    declared =
      Enum.map(modules, &{&1, run_callback(run, &1, fn -> declared_by(&1) end)}) ++
        Enum.map(providers, &{&1, run_callback(run, &1, fn -> declared_by_provider(&1) end)})

    failed = for {module, :error} <- declared, do: module

    resolved =
      Enum.map(declared, fn
        {module, {:ok, specs}} -> {module, specs}
        {module, :error} -> {module, Map.get(previous, module, [])}
      end)

    {specs, collisions} = resolved |> Enum.flat_map(&elem(&1, 1)) |> unique_keys()

    state = %{
      specs: specs,
      collisions: collisions,
      providers: MapSet.new(providers),
      declared: Map.new(resolved)
    }

    {state, failed}
  end

  defp run_callback(run, module, fun) do
    case run.(fun) do
      :timeout ->
        Logger.warning(
          "[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 did not answer within " <>
            "#{callback_timeout()} ms"
        )

        :error

      result ->
        result
    end
  end

  # First declaration wins: kit modules come before providers, providers in
  # config order. The dropped one is warned about (naming both) and kept in
  # `collisions/0` for the Tasks page.
  defp unique_keys(specs) do
    {map, collisions} =
      Enum.reduce(specs, {%{}, []}, fn %TaskSpec{key: key} = spec, {acc, collisions} ->
        if Map.has_key?(acc, key) do
          kept = acc[key].module

          Logger.warning(
            "[PhoenixKitAI] AI task #{inspect(key)} declared again by #{inspect(spec.module)}; " <>
              "the declaration of #{inspect(kept)} is kept"
          )

          {acc, [%{key: key, kept: kept, dropped: spec.module} | collisions]}
        else
          {Map.put(acc, key, spec), collisions}
        end
      end)

    {map, Enum.reverse(collisions)}
  end

  # A configured provider, unlike a kit module (most declare no tasks), is
  # listed only to declare tasks: say why it declares none.
  defp declared_by_provider(module) do
    cond do
      not match?({:module, _}, Code.ensure_loaded(module)) ->
        Logger.warning(
          "[PhoenixKitAI] AI task provider #{inspect(module)} (config :task_providers) " <>
            "could not be loaded; its tasks are missing"
        )

        {:ok, []}

      not function_exported?(module, :ai_tasks, 0) ->
        Logger.warning(
          "[PhoenixKitAI] AI task provider #{inspect(module)} (config :task_providers) " <>
            "does not export ai_tasks/0; it declares no tasks"
        )

        {:ok, []}

      true ->
        declared_by(module)
    end
  end

  defp declared_by(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :ai_tasks, 0) do
      {:ok, module.ai_tasks() |> List.wrap() |> Enum.flat_map(&valid_spec(&1, module))}
    else
      {:ok, []}
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 failed: #{inspect(error.__struct__)}"
      )

      :error
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 failed: #{kind}")

      :error
  end

  defp valid_spec(entry, module) do
    case entry do
      %TaskSpec{key: key} = spec when is_binary(key) and key != "" ->
        [
          %{
            spec
            | module: module,
              needs: Enum.filter(List.wrap(spec.needs), &(&1 in TaskSpec.needs())),
              user_limits: spec.user_limits != false
          }
        ]

      other ->
        Logger.warning(
          "[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 returned an entry that is not a " <>
            "%PhoenixKitAI.TaskSpec{} with a key: #{MessageShape.describe(other)}"
        )

        []
    end
  end

  # A provider's tasks are always on: it has no module switch, and a host
  # module may define an `enabled?/0` of its own for another purpose.
  defp with_enabled(%TaskSpec{module: module} = spec, state) do
    enabled? = MapSet.member?(state.providers, module) or module_enabled?(module)
    %{spec | enabled: enabled?}
  end

  defp module_enabled?(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :enabled?, 0),
      do: module.enabled?() == true,
      else: true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Once per key per node: the flags table of the request cache holds the
  # keys already reported (persistent_term would GC globally on every new key).
  defp warn_unknown_once(key) do
    first? =
      try do
        :ets.insert_new(PhoenixKitAI.RequestCache.flags_table(), {{:unknown_ai_task, key}, true})
      rescue
        # No flags table (the request cache is not running): stay quiet
        # rather than warn on every call.
        ArgumentError -> false
      end

    if first? do
      Logger.warning(
        "[PhoenixKitAI] a call names the AI task #{inspect(key)}, which no module declares; " <>
          "the call goes on without the task's requirements"
      )
    end

    :ok
  end

  @doc "A requirement in words: images, documents, image generation, tools, JSON schema, JSON."
  @spec need_label(TaskSpec.need()) :: String.t()
  def need_label(:vision), do: gettext("images")
  def need_label(:file_input), do: gettext("documents")
  def need_label(:image_output), do: gettext("image generation")
  def need_label(:tools), do: gettext("tools")
  def need_label(:json_schema), do: gettext("JSON schema")
  def need_label(:json), do: gettext("JSON")
  def need_label(other), do: to_string(other)

  @doc "Several requirements in words, comma-separated."
  @spec need_labels([TaskSpec.need()]) :: String.t()
  def need_labels(needs), do: Enum.map_join(needs, ", ", &need_label/1)

  # ===========================================
  # FITNESS
  # ===========================================

  @doc """
  Whether `endpoint` can do what the task needs: `:fit`, `{:unfit, missing}`
  or `{:unknown, unclear}`. Takes a task key or a `%TaskSpec{}`; a key no
  module declares has no needs.
  """
  @spec fitness(String.t() | TaskSpec.t(), Endpoint.t()) :: fitness()
  def fitness(%TaskSpec{needs: needs}, %Endpoint{} = endpoint),
    do: assess(Capabilities.for_endpoint(endpoint), needs)

  def fitness(key, %Endpoint{} = endpoint) when is_binary(key) do
    case for_call(key) do
      nil -> :fit
      spec -> fitness(spec, endpoint)
    end
  end

  @doc false
  # The fitness of a model with `caps` for `needs`; only the hard needs count.
  @spec assess(Capabilities.t() | :unknown, [TaskSpec.need()]) :: fitness()
  def assess(caps, needs) do
    hard = Enum.filter(TaskSpec.hard_needs(), &(&1 in needs))

    {missing, unclear} =
      Enum.reduce(hard, {[], []}, fn need, {missing, unclear} ->
        case flag(caps, need) do
          :yes -> {missing, unclear}
          :no -> {missing ++ [need], unclear}
          :unknown -> {missing, unclear ++ [need]}
        end
      end)

    cond do
      missing != [] -> {:unfit, missing}
      unclear != [] -> {:unknown, unclear}
      true -> :fit
    end
  end

  @doc false
  @spec flag(Capabilities.t() | :unknown, TaskSpec.need()) :: :yes | :no | :unknown
  def flag(%Capabilities{} = caps, need), do: Map.fetch!(caps, need)
  def flag(_caps, _need), do: :unknown

  @doc """
  The enabled endpoints, each with its fitness for the task — for a
  consumer's settings form to show which can be chosen.
  """
  @spec endpoint_options(String.t() | TaskSpec.t()) :: [
          %{endpoint: Endpoint.t(), fitness: fitness()}
        ]
  def endpoint_options(task) do
    from(e in Endpoint, where: e.enabled == true, order_by: [asc: e.sort_order, asc: e.uuid])
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.map(&%{endpoint: &1, fitness: fitness(task, &1)})
  end

  @doc """
  Whether a consumer's settings form may save `endpoint` for the task:
  `:ok` for a fit endpoint; `{:error, {:model_unfit, missing}}` when its
  model lacks a requirement; `{:error, {:model_unverified, unclear}}` when
  nobody knows whether it has one — an admin marks the capabilities on the
  endpoint first. Takes an endpoint or its uuid.
  """
  @spec check_selection(String.t() | TaskSpec.t(), Endpoint.t() | String.t()) ::
          :ok | {:error, term()}
  def check_selection(task, %Endpoint{} = endpoint) do
    case fitness(task, endpoint) do
      :fit -> :ok
      {:unfit, missing} -> {:error, {:model_unfit, missing}}
      {:unknown, unclear} -> {:error, {:model_unverified, unclear}}
    end
  end

  def check_selection(task, endpoint_uuid) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint -> check_selection(task, endpoint)
      nil -> {:error, :endpoint_not_found}
    end
  end

  @doc """
  The endpoints the task uses now, from its `endpoints` callback; `[]` when
  it has none or the callback fails.
  """
  @spec endpoints(TaskSpec.t()) :: [Endpoint.t()]
  def endpoints(%TaskSpec{endpoints: {module, function, args}}) do
    module
    |> apply(function, args)
    |> case do
      {:ok, value} -> value
      value -> value
    end
    |> List.wrap()
    |> Enum.flat_map(fn
      %Endpoint{} = endpoint -> [endpoint]
      uuid when is_binary(uuid) -> List.wrap(PhoenixKitAI.get_endpoint(uuid))
      _ -> []
    end)
    |> Enum.uniq_by(& &1.uuid)
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] endpoints callback failed: #{inspect(error.__struct__)}")
      []
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAI] endpoints callback failed: #{kind}")

      []
  end

  def endpoints(%TaskSpec{}), do: []
end
