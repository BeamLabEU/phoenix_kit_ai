defmodule PhoenixKitAI.Recommendations do
  @moduledoc """
  What to choose for an AI task, from live data only — there is no list of
  "best models" in the module.

    * `cheapest/2` — the models of the catalogues the endpoints use
      (`PhoenixKitAI.Capabilities.catalogue/1`) that are fit for **all** of
      the task's hard needs, ranked by the estimated price of one call.
    * `worked/2` — the models that already worked in this task, from the
      usage journal over the last 30 days.
    * `for_task/2` — both, for the recommendations block.

  ## Ranking

  The price of one call is `input_tokens × prompt_price + output_tokens ×
  completion_price`, with the catalogue's dollars-per-token prices and the
  task's typical call size: `typical_tokens: {in, out}` from its
  declaration (`estimate: :declared`); else the median input and output
  tokens of its successful calls in the journal over 30 days
  (`estimate: :journal`); else nothing is known (`estimate: :rough`) and the
  rows are ranked by the input price alone, with no price per call.

  A model fits when `PhoenixKitAI.Tasks.assess/2` says `:fit` — a model
  that is only unverified does not — and it answers in text. Retired
  models are left out; deprecated ones are marked. Anthropic's `/models`
  lists no prices, so its models are unpriced (they are never mapped to an
  OpenRouter model by name); they come after the priced ones, with one place
  kept for them among the rows.

  ## Journal

  `worked/2` leaves out the rows the guard refused before any HTTP
  (`metadata.refused`), so they count neither as calls nor as errors.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAI.{Capabilities, Endpoint, Request, Tasks, TaskSpec}

  @limit 5
  @worked_limit 10
  @window_days 30

  @type note :: :alias | :cost_not_reported | :json_schema_openrouter_only
  @type estimate :: :declared | :journal | :rough

  @doc """
  Both lists for a task (a key or a `%TaskSpec{}`):
  `%{cheapest: rows, estimate: estimate, tokens: {in, out} | nil, worked: rows}`.
  """
  @spec for_task(String.t() | TaskSpec.t(), keyword()) :: map()
  def for_task(task, opts \\ []) do
    spec = spec(task)
    %{rows: rows, estimate: estimate, tokens: tokens} = cheapest(spec, opts)
    %{cheapest: rows, estimate: estimate, tokens: tokens, worked: worked(spec, opts)}
  end

  @doc """
  The cheapest fit models, `limit` (5) rows at most, each
  `%{model, name, provider, base_url, integration_uuid, context_length,
  price_per_call, price_known?, input_price_per_million, deprecated?, notes}`.
  `price_per_call` is dollars, `nil` without a price or an estimate of the
  call; `input_price_per_million` is dollars.

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
    {estimate, tokens} = estimate_tokens(spec, opts)
    limit = Keyword.get(opts, :limit, @limit)

    rows =
      opts
      |> sources()
      |> Enum.flat_map(&candidates(&1, spec.needs, tokens))
      |> rank(limit)

    %{rows: rows, estimate: estimate, tokens: tokens}
  end

  @doc """
  The models that worked in the task over the last 30 days (`:days`), most
  calls first, ten at most: `%{model, calls, avg_cost, error_share,
  avg_latency_ms, cost_reported?, notes}`. `avg_cost` is in the units of
  `cost_cents` (`Request.format_cost/1` shows it) and `nil` when no call
  reported a cost; `error_share` is 0.0–1.0.
  """
  @spec worked(String.t() | TaskSpec.t(), keyword()) :: [map()]
  def worked(task, opts \\ []) do
    key = spec(task).key

    from(r in journal(key, opts),
      where: not is_nil(r.model),
      group_by: r.model,
      order_by: [desc: count(r.uuid), asc: r.model],
      limit: ^@worked_limit,
      select: %{
        model: r.model,
        calls: count(r.uuid),
        errors: filter(count(r.uuid), r.status != "success"),
        cost_rows: count(r.cost_cents),
        avg_cost: avg(r.cost_cents),
        avg_latency_ms: avg(r.latency_ms)
      }
    )
    |> repo().all()
    |> Enum.map(&worked_row/1)
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

  defp estimate_tokens(%TaskSpec{typical_tokens: {input, output}}, _opts)
       when is_integer(input) and is_integer(output),
       do: {:declared, {input, output}}

  defp estimate_tokens(%TaskSpec{key: key}, opts) do
    from(r in journal(key, opts),
      where: r.status == "success" and r.input_tokens > 0,
      select: {
        count(r.uuid),
        fragment("percentile_cont(0.5) within group (order by ?)", r.input_tokens),
        fragment("percentile_cont(0.5) within group (order by ?)", r.output_tokens)
      }
    )
    |> repo().one()
    |> case do
      {count, input, output} when count > 0 and not is_nil(input) ->
        {:journal, {round(input), round(output || 0)}}

      _ ->
        {:rough, nil}
    end
  end

  # The task's rows of the last `days` days, without the guard's refusals.
  defp journal(key, opts) do
    since = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days, @window_days) * 86_400)

    from(r in Request,
      where:
        r.inserted_at >= ^since and fragment("?->>'task'", r.metadata) == ^key and
          fragment("coalesce(?->>'refused', 'false')", r.metadata) != "true"
    )
  end

  defp worked_row(row) do
    %{
      model: row.model,
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

  # One source per base URL the endpoints use that has a catalogue; the
  # integration is the one of an endpoint there (enabled ones first), which
  # the create button hands to the endpoint form.
  defp sources(opts) do
    case Keyword.fetch(opts, :catalogue) do
      {:ok, sources} -> sources
      :error -> cache_sources()
    end
  end

  defp cache_sources do
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
                integration_uuid: Enum.find_value(endpoints, & &1.integration_uuid),
                models: Capabilities.catalogue(base_url)
              }
            ]
        end
    end)
  end

  defp candidates(%{models: models} = source, needs, tokens) do
    for {id, %Capabilities{} = caps} <- models,
        caps.text_output != false,
        caps.lifecycle != :retired,
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
      context_length: caps.context_length,
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
      kind == :anthropic && :cost_not_reported,
      kind == :anthropic && caps.json_schema == :no && :json_schema_openrouter_only
    ]
    |> Enum.filter(& &1)
  end

  # The price of the estimated call needs both prices; a catalogue that
  # lists only the input price (or none) leaves the call unpriced, and the
  # ranking then falls back on what it has.
  defp price_per_call(%Capabilities{prompt_price: input, completion_price: output}, {tin, tout})
       when is_number(input) and is_number(output),
       do: tin * input + tout * output

  defp price_per_call(_caps, _tokens), do: nil

  defp sort_price(caps, tokens), do: price_per_call(caps, tokens) || caps.prompt_price

  # Priced rows by price (a tie by model id), then the unpriced ones, with
  # one place kept for them; the sort key is dropped.
  defp rank(candidates, limit) do
    {priced, unpriced} = Enum.split_with(candidates, &(&1.sort_price != nil))
    priced = Enum.sort_by(priced, &{&1.sort_price, &1.model})
    unpriced = Enum.sort_by(unpriced, & &1.model, :desc)

    take_priced = min(length(priced), limit - min(length(unpriced), 1))

    (Enum.take(priced, take_priced) ++ Enum.take(unpriced, limit - take_priced))
    |> Enum.map(&Map.delete(&1, :sort_price))
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
