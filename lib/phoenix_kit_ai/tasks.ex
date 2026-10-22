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
  Two declarations of one key: the first wins, with a warning.

  ## Fitness

  `fitness/2` compares a task's hard needs (`:vision`, `:tools`,
  `:json_schema`) with `PhoenixKitAI.Capabilities.for_endpoint/1` (the
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

  @registry_key {__MODULE__, :registry}

  @type fitness ::
          :fit | {:unfit, [TaskSpec.need()]} | {:unknown, [TaskSpec.need()]}

  # ===========================================
  # REGISTRY
  # ===========================================

  @doc "Every declared task, by key, each marked whether its module is on."
  @spec list() :: [TaskSpec.t()]
  def list do
    registry()
    |> Map.values()
    |> Enum.sort_by(& &1.key)
    |> Enum.map(&with_enabled/1)
  end

  @doc "The task declared under `key`, or `nil`."
  @spec get(String.t()) :: TaskSpec.t() | nil
  def get(key) when is_binary(key) do
    case Map.get(registry(), key) do
      nil -> nil
      spec -> with_enabled(spec)
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
    case Map.get(registry(), key) do
      nil ->
        warn_unknown_once(key)
        nil

      spec ->
        spec
    end
  end

  def for_call(_key), do: nil

  defp registry do
    modules = discoverable_modules()

    case :persistent_term.get(@registry_key, nil) do
      {^modules, specs} ->
        specs

      _ ->
        specs = build(modules)
        :persistent_term.put(@registry_key, {modules, specs})
        specs
    end
  end

  # This module's own tasks are always in, whether or not the host's module
  # registry lists it.
  defp discoverable_modules do
    Enum.uniq([PhoenixKitAI | PhoenixKit.ModuleRegistry.all_modules()])
  rescue
    _ -> [PhoenixKitAI]
  end

  defp build(modules) do
    modules
    |> Enum.flat_map(&declared_by/1)
    |> Enum.reduce(%{}, fn %TaskSpec{key: key} = spec, acc ->
      if Map.has_key?(acc, key) do
        Logger.warning(
          "[PhoenixKitAI] AI task #{inspect(key)} declared again by #{inspect(spec.module)}; " <>
            "the declaration of #{inspect(acc[key].module)} is kept"
        )

        acc
      else
        Map.put(acc, key, spec)
      end
    end)
  end

  defp declared_by(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :ai_tasks, 0) do
      module.ai_tasks()
      |> List.wrap()
      |> Enum.flat_map(fn
        %TaskSpec{key: key} = spec when is_binary(key) and key != "" ->
          [
            %{
              spec
              | module: module,
                needs: Enum.filter(List.wrap(spec.needs), &(&1 in TaskSpec.needs()))
            }
          ]

        other ->
          Logger.warning(
            "[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 returned an entry that is not a " <>
              "%PhoenixKitAI.TaskSpec{} with a key: #{inspect(other, limit: 3)}"
          )

          []
      end)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] #{inspect(module)}.ai_tasks/0 failed: #{Exception.message(error)}"
      )

      []
  end

  defp with_enabled(%TaskSpec{module: module} = spec),
    do: %{spec | enabled: module_enabled?(module)}

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
        ArgumentError -> true
      end

    if first? do
      Logger.warning(
        "[PhoenixKitAI] a call names the AI task #{inspect(key)}, which no module declares; " <>
          "the call goes on without the task's requirements"
      )
    end

    :ok
  end

  @doc "A requirement in words: images, tools, JSON schema, JSON."
  @spec need_label(TaskSpec.need()) :: String.t()
  def need_label(:vision), do: gettext("images")
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
      Logger.warning("[PhoenixKitAI] endpoints callback failed: #{Exception.message(error)}")
      []
  end

  def endpoints(%TaskSpec{}), do: []
end
