defmodule PhoenixKitAI.Recommendations do
  @moduledoc """
  What to choose for an AI task, from live data only — there is no list of
  "best models" in the module. What a model can do comes first, its price
  second.

    * `ranked/2` — the models of the catalogues the endpoints use
      (`PhoenixKitAI.Capabilities.catalogue/1`) in groups: `verified` (the
      catalogue, or the endpoint's declaration, says the model has every
      need), `possible` (it lacks none, but at least one nobody verified —
      each row names those in `unverified`) and `experimental` (models of
      either kind that look experimental: an id with `preview`, `beta` or
      `exp`, a `:free` variant or a free price, an alias, or no price in a
      catalogue that prices its models), each ranked by the estimated price
      of one call.
    * The needs are the task's, with its images / documents / image
      generation needs replaced by the `filters` (`filterable/0`; the
      task's own by default). `refilter/2` regroups for other filters.
    * `cheapest/2` — the models fit for **all** of the task's hard needs,
      ranked by price, whatever they look like.
    * `worked/2` — the models that already worked in this task, from the
      usage journal over the last 30 days.
    * `for_task/2` — all of it, for the recommendations block.

  ## Ranking

  The price of one call is `input_tokens × prompt_price + output_tokens ×
  completion_price`, with the catalogue's dollars-per-token prices and the
  task's typical call size: `typical_tokens: {in, out}` from its
  declaration (`estimate: :declared`); else the median input and output
  tokens of its successful calls in the journal over 30 days
  (`estimate: :journal`); else nothing is known (`estimate: :rough`) and the
  rows are ranked by the input price alone, with no price per call.

  Inside each group the rows are ranked so. A model is in `verified` when
  `PhoenixKitAI.Tasks.assess/2` says `:fit`, in `possible` when it says
  `{:unknown, _}`, nowhere when it says `{:unfit, _}`; it must answer in
  text unless image generation is among the needs. Retired models are left
  out; deprecated ones are marked. The `/models` of
  Anthropic, DeepSeek and Mistral list no prices, so their models are
  unpriced (they are never mapped to an OpenRouter model by name), and no
  provider but OpenRouter reports what a call cost; they come after the
  priced ones, with one place kept for them among the rows.

  ## Journal

  `worked/2` leaves out the rows the guard refused before any HTTP
  (`metadata.refused`), so they count neither as calls nor as errors.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAI.{Capabilities, Endpoint, Request, Tasks, TaskSpec}

  @limit 5
  @worked_limit 10
  @window_days 30
  @filterable [:vision, :file_input, :image_output]
  # `preview`, `beta`, `exp` or `experimental` as a word of the model id.
  @experimental_id ~r/(^|[^a-z])(preview|beta|exp|experimental)([^a-z]|$)/i

  @type note :: :alias | :cost_not_reported | :json_schema_openrouter_only | :free
  @type estimate :: :declared | :journal | :rough

  @doc "The capabilities the recommendations can be filtered by: images, documents, image generation."
  @spec filterable() :: [TaskSpec.need()]
  def filterable, do: @filterable

  @doc """
  Everything for a task (a key or a `%TaskSpec{}`): the groups of
  `ranked/2` with its `filters`, `estimate` and `tokens`, and `worked`
  (`worked/2`). It also keeps `spec` for `refilter/2` — but not the
  catalogue: a panel keeps the result in its state.
  """
  @spec for_task(String.t() | TaskSpec.t(), keyword()) :: map()
  def for_task(task, opts \\ []) do
    spec = spec(task)
    Map.fetch!(for_tasks([spec], opts), spec.key)
  end

  @doc """
  `for_task/2` for several tasks at once, as a map by task key: the
  catalogues are read once and the journal is asked twice in all (the
  median call sizes and the models that worked, each grouped by task), not
  twice per task — for a page that lists every task.
  """
  @spec for_tasks([String.t() | TaskSpec.t()], keyword()) :: %{String.t() => map()}
  def for_tasks(tasks, opts \\ []) do
    specs = Enum.map(tasks, &spec/1)
    keys = Enum.map(specs, & &1.key)
    sources = sources_for(opts)
    medians = medians(keys, opts)
    worked = worked_by_task(keys, opts)

    Map.new(specs, fn spec ->
      {estimate, tokens} = estimate_tokens(spec, Map.get(medians, spec.key))

      recs =
        %{
          spec: spec,
          estimate: estimate,
          tokens: tokens,
          worked: Map.get(worked, spec.key, [])
        }
        |> Map.merge(groups(spec, sources, tokens, filters(spec, opts), opts))

      {spec.key, recs}
    end)
  end

  @doc """
  The models for the task in groups, `limit` (5) rows each:
  `%{verified, possible, experimental, filters, estimate, tokens}`. A row is
  as in `cheapest/2`, plus `unverified` — the needs nobody verified (`[]`
  in `verified`).

  Options: `:filters` (a subset of `filterable/0`; the task's own needs
  among them by default), `:limit`, `:days`, `:catalogue` (as in
  `cheapest/2`).
  """
  @spec ranked(String.t() | TaskSpec.t(), keyword()) :: map()
  def ranked(task, opts \\ []) do
    spec = spec(task)
    {estimate, tokens} = estimate_tokens(spec, Map.get(medians([spec.key], opts), spec.key))

    %{estimate: estimate, tokens: tokens}
    |> Map.merge(groups(spec, sources_for(opts), tokens, filters(spec, opts), opts))
  end

  @doc """
  The recommendations of `for_task/2` regrouped for other `filters`, from
  the catalogues as the cache holds them now (or `:catalogue`, as in
  `cheapest/2`); the journal part and the estimate are kept, nothing is
  asked of the journal.
  """
  @spec refilter(map(), [atom()], keyword()) :: map()
  def refilter(%{spec: spec, tokens: tokens} = recs, filters, opts \\ []) do
    Map.merge(
      recs,
      groups(spec, sources_for(opts), tokens, filters(spec, filters: filters), opts)
    )
  end

  @doc """
  The cheapest fit models, `limit` (5) rows at most, each
  `%{model, name, provider, base_url, integration_uuid, context_length,
  capabilities, source_endpoint_uuid, price_per_call, price_known?, input_price_per_million,
  deprecated?, notes}`. `price_per_call` is dollars, `nil` without a price
  or an estimate of the call; `input_price_per_million` is dollars.

  Options: `:limit`, `:days`, and `:catalogue` — the sources to rank instead
  of the cache's (`%{base_url, kind, integration_uuid, models: [{id, caps}]}`).
  """
  @spec cheapest(String.t() | TaskSpec.t(), keyword()) :: %{
          rows: [map()],
          estimate: estimate(),
          tokens: {non_neg_integer(), non_neg_integer()} | nil
        }
  def cheapest(task, opts \\ []) do
    spec = spec(task)
    rank_for(spec, sources_for(opts), Map.get(medians([spec.key], opts), spec.key), opts)
  end

  @doc """
  The models that worked in the task over the last 30 days (`:days`), most
  calls first, ten at most, one row per model and operator: `%{model,
  provider, calls, avg_cost, error_share, avg_latency_ms, cost_reported?,
  notes}`. `provider` is the endpoint's provider key, `nil` when the
  endpoint is gone. `avg_cost` is in the units of `cost_cents`
  (`Request.format_cost/1` shows it) and `nil` when no call reported a
  cost; `error_share` is 0.0–1.0. Refusals and cache hits are not calls.
  """
  @spec worked(String.t() | TaskSpec.t(), keyword()) :: [map()]
  def worked(task, opts \\ []) do
    key = spec(task).key
    opts |> then(&worked_by_task([key], &1)) |> Map.get(key, [])
  end

  @doc "Whether the model id is an alias that can move to another model."
  @spec alias?(String.t()) :: boolean()
  def alias?(model) when is_binary(model),
    do: String.starts_with?(model, "~") or String.ends_with?(model, "-latest")

  def alias?(_model), do: false

  # ===========================================
  # TASK AND TOKENS
  # ===========================================

  defp spec(%TaskSpec{} = spec), do: spec

  defp spec(key) when is_binary(key),
    do: Tasks.get(key) || %TaskSpec{key: key}

  # The task's needs with its filterable ones replaced by the filters; the
  # filters as given (only filterable ones, in their order), or the task's
  # own.
  defp filters(spec, opts) do
    case Keyword.fetch(opts, :filters) do
      {:ok, filters} -> Enum.filter(@filterable, &(&1 in List.wrap(filters)))
      :error -> Enum.filter(@filterable, &(&1 in spec.needs))
    end
  end

  defp groups(spec, sources, tokens, filters, opts) do
    needs = Enum.reject(spec.needs, &(&1 in @filterable)) ++ filters
    limit = Keyword.get(opts, :limit, @limit)

    rows =
      for source <- sources,
          {id, %Capabilities{} = caps} <- source.models,
          listed?(caps, needs),
          group = group(Tasks.assess(caps, needs)),
          group != nil do
        {group,
         source |> row(id, caps, tokens) |> Map.put(:unverified, unverified(group, caps, needs))}
      end

    {experimental, main} = Enum.split_with(rows, fn {_group, row} -> experimental?(row) end)

    %{
      filters: filters,
      verified: main |> of_group(:verified) |> rank(tokens, limit),
      possible: main |> of_group(:possible) |> rank(tokens, limit),
      experimental: experimental |> Enum.map(&elem(&1, 1)) |> rank(tokens, limit)
    }
  end

  defp group(:fit), do: :verified
  defp group({:unknown, _unclear}), do: :possible
  defp group({:unfit, _missing}), do: nil

  defp unverified(:verified, _caps, _needs), do: []

  defp unverified(:possible, caps, needs) do
    {:unknown, unclear} = Tasks.assess(caps, needs)
    unclear
  end

  defp of_group(rows, group), do: for({^group, row} <- rows, do: row)

  # A model that does not answer in text is listed only when images out are
  # what the task needs; retired ones never.
  defp listed?(caps, needs),
    do: (caps.text_output != false or :image_output in needs) and caps.lifecycle != :retired

  defp experimental?(%{model: id} = row) do
    alias?(id) or String.contains?(id, ":free") or Regex.match?(@experimental_id, id) or
      :free in row.notes or (row.provider == :openrouter and row.sort_price == nil)
  end

  defp rank_for(spec, sources, median, opts) do
    {estimate, tokens} = estimate_tokens(spec, median)

    rows =
      sources
      |> Enum.flat_map(&candidates(&1, spec.needs, tokens))
      |> rank(tokens, Keyword.get(opts, :limit, @limit))

    %{rows: rows, estimate: estimate, tokens: tokens}
  end

  defp estimate_tokens(%TaskSpec{typical_tokens: {input, output}}, _median)
       when is_integer(input) and is_integer(output),
       do: {:declared, {input, output}}

  defp estimate_tokens(_spec, {input, output}), do: {:journal, {input, output}}
  defp estimate_tokens(_spec, nil), do: {:rough, nil}

  # The median call size of each task's successful calls: one query for all.
  defp medians([], _opts), do: %{}

  defp medians(keys, opts) do
    from(r in journal(keys, opts),
      where: r.status == "success" and r.input_tokens > 0,
      group_by: fragment("?->>'task'", r.metadata),
      select: {
        fragment("?->>'task'", r.metadata),
        fragment("percentile_cont(0.5) within group (order by ?)", r.input_tokens),
        fragment("percentile_cont(0.5) within group (order by ?)", r.output_tokens)
      }
    )
    |> repo().all()
    |> Map.new(fn {key, input, output} -> {key, {round(input), round(output || 0)}} end)
  end

  # The models that worked, per task: one query for all.
  defp worked_by_task([], _opts), do: %{}

  defp worked_by_task(keys, opts) do
    from(r in journal(keys, opts),
      left_join: e in Endpoint,
      on: e.uuid == r.endpoint_uuid,
      where: not is_nil(r.model),
      group_by: [
        fragment("?->>'task'", r.metadata),
        r.model,
        fragment("split_part(?, ':', 1)", e.provider)
      ],
      select: %{
        task: fragment("?->>'task'", r.metadata),
        model: r.model,
        provider: fragment("split_part(?, ':', 1)", e.provider),
        calls: count(r.uuid),
        errors: filter(count(r.uuid), r.status != "success"),
        cost_rows: count(r.cost_cents),
        avg_cost: avg(r.cost_cents),
        avg_latency_ms: avg(r.latency_ms)
      }
    )
    |> repo().all()
    |> Enum.group_by(& &1.task, &worked_row/1)
    |> Map.new(fn {key, rows} ->
      {key,
       rows |> Enum.sort_by(&{-&1.calls, &1.model, &1.provider || ""}) |> Enum.take(@worked_limit)}
    end)
  end

  # The tasks' rows of the last `days` days, without the guard's refusals and
  # without cache hits (which cost nothing and take no time, so they are not
  # calls to a model).
  defp journal(keys, opts) do
    since = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days, @window_days) * 86_400)

    from(r in Request,
      where:
        r.inserted_at >= ^since and fragment("?->>'task'", r.metadata) in ^keys and
          fragment("coalesce(?->>'refused', 'false')", r.metadata) != "true" and
          fragment("coalesce(?->>'cached', 'false')", r.metadata) != "true"
    )
  end

  defp worked_row(row) do
    %{
      model: row.model,
      provider: row.provider,
      calls: row.calls,
      avg_cost: to_float(row.avg_cost),
      error_share: row.errors / row.calls,
      avg_latency_ms: to_float(row.avg_latency_ms),
      cost_reported?: row.cost_rows > 0,
      notes: if(alias?(row.model), do: [:alias], else: [])
    }
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value * 1.0

  # ===========================================
  # CATALOGUE
  # ===========================================

  defp sources_for(opts) do
    case Keyword.fetch(opts, :catalogue) do
      {:ok, sources} -> sources
      :error -> sources()
    end
  end

  @doc """
  The catalogues the endpoints use, as the sources `cheapest/2` ranks: one
  per base URL with a catalogue, `%{base_url, kind, endpoint_uuid,
  integration_uuid, models}`. Read once and passed as `:catalogue` when several tasks are
  listed together. The integration is the one of an endpoint there (enabled
  ones first), which the create button hands to the endpoint form.
  """
  @spec sources() :: [map()]
  def sources do
    from(e in Endpoint, order_by: [desc: e.enabled, asc: e.uuid])
    |> repo().all()
    |> Enum.group_by(&Capabilities.resolved_base_url/1)
    |> Enum.flat_map(fn
      {nil, _endpoints} ->
        []

      {base_url, [first | _] = endpoints} ->
        case Capabilities.catalogue_kind(first.provider, base_url) do
          nil ->
            []

          kind ->
            [
              %{
                base_url: base_url,
                kind: kind,
                endpoint_uuid: first.uuid,
                integration_uuid: Enum.find_value(endpoints, & &1.integration_uuid),
                models: Capabilities.catalogue(base_url)
              }
            ]
        end
    end)
  end

  defp candidates(%{models: models} = source, needs, tokens) do
    for {id, %Capabilities{} = caps} <- models,
        listed?(caps, needs),
        Tasks.assess(caps, needs) == :fit,
        do: row(source, id, caps, tokens)
  end

  defp row(source, id, caps, tokens) do
    %{
      model: id,
      name: caps.name || id,
      provider: source.kind,
      base_url: source.base_url,
      integration_uuid: source.integration_uuid,
      source_endpoint_uuid: source[:endpoint_uuid],
      context_length: caps.context_length,
      capabilities: caps,
      price_per_call: price_per_call(caps, tokens),
      price_known?: caps.prompt_price != nil,
      input_price_per_million: caps.prompt_price && caps.prompt_price * 1_000_000,
      deprecated?: caps.lifecycle == :deprecated,
      notes: notes(source.kind, id, caps),
      sort_price: sort_price(caps, tokens)
    }
  end

  defp notes(kind, id, caps) do
    [
      alias?(id) && :alias,
      free?(caps) && :free,
      kind != :openrouter && :cost_not_reported,
      kind == :anthropic && caps.json_schema == :no && :json_schema_openrouter_only
    ]
    |> Enum.filter(& &1)
  end

  # A model both of whose prices are zero (OpenRouter's `:free` variants):
  # rate-limited and on the operator's terms, so not a plain bargain.
  defp free?(%Capabilities{prompt_price: input, completion_price: output}),
    do: input == 0.0 and output == 0.0

  # The price of the estimated call needs both prices; a catalogue that
  # lists only the input price (or none) leaves the call unpriced.
  defp price_per_call(%Capabilities{prompt_price: input, completion_price: output}, {tin, tout})
       when is_number(input) and is_number(output),
       do: tin * input + tout * output

  defp price_per_call(_caps, _tokens), do: nil

  # Per call when the call's size is known, per token (the input price) only
  # when it is not: the two are never mixed in one ordering.
  defp sort_price(caps, nil), do: caps.prompt_price
  defp sort_price(caps, tokens), do: price_per_call(caps, tokens)

  # Priced rows by price (a tie by model id), with no more than one free model;
  # then the unpriced ones, Anthropic first, with one place kept for them. The
  # sort key is dropped.
  defp rank(_candidates, _tokens, limit) when is_integer(limit) and limit <= 0, do: []

  defp rank(candidates, _tokens, limit) do
    {priced, unpriced} = Enum.split_with(candidates, &(&1.sort_price != nil))
    priced = priced |> Enum.sort_by(&{&1.sort_price, &1.model}) |> one_free()
    unpriced = Enum.sort_by(unpriced, &{&1.provider != :anthropic, reverse_id(&1.model)})

    take_priced = min(length(priced), limit - min(length(unpriced), 1))

    (Enum.take(priced, take_priced) ++ Enum.take(unpriced, limit - take_priced))
    |> Enum.map(&Map.delete(&1, :sort_price))
  end

  defp one_free(rows) do
    {free, paid} = Enum.split_with(rows, &(:free in &1.notes))
    Enum.take(free, 1) ++ paid
  end

  # Sorts ids descending inside Enum.sort_by's ascending order.
  defp reverse_id(id), do: id |> String.to_charlist() |> Enum.map(&(-&1))

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
