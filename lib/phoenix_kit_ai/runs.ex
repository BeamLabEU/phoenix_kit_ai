defmodule PhoenixKitAI.Runs do
  @moduledoc """
  What one piece of multi-call work cost, read from the usage journal.

  Any verb takes `run:` (and optionally `step:`): a string the caller picks
  for one import, one nightly job, one pipeline pass. Every row the call
  writes carries it in `metadata` — successes, errors, refusals, cache hits
  and unparsed JSON answers alike — so `costs/2` can total the run by step,
  model and outcome afterwards. `PhoenixKitAI.vision_batch/3` tags its calls
  with a run of its own when the caller gives none.

  The journal has no index on the tag: a run is found by scanning rows, so
  pass `since:` (a `DateTime`, the run's start) on a large journal, which
  narrows the scan to the time range. Rows removed by journal retention are
  gone from the totals too.

  ## A ceiling for a run

  The spend caps (`PhoenixKitAI.Budget`) are the site's, an endpoint's or a
  user's. A job wants its own: "this nightly crawl may spend $2, then we are
  done for today". Any verb takes `run_budget:` (dollars, a `Decimal` or a
  decimal string) next to `run:`; before the call the run's spend so far —
  its successful rows' cost, from `run_since:` (a `DateTime`) on when given —
  is compared with it, and once it is reached the call is refused with
  `{:error, {:run_budget_reached, run}}` before any provider call (a refusal
  row, like the caps'; cached answers included). `ceiling_reached?/1` tells
  that answer apart from a failure, so a job loop ends with a clear result
  instead of an error:

      for page <- pages, reduce: {:cont, 0} do
        {:halt, _} = done -> done
        {:cont, n} ->
          case PhoenixKitAI.ask(ep, prompt(page), run: run, run_budget: "2.00") do
            {:ok, _} -> {:cont, n + 1}
            {:error, reason} ->
              if PhoenixKitAI.Runs.ceiling_reached?(reason), do: {:halt, n}, else: {:cont, n}
          end
      end

  `ceiling/3` answers the same question without a call (`remaining`,
  `reached?`), for a job that wants to stop before it starts a page. Like the
  caps it reads the journal before the call, so calls running at the same
  time overshoot by what they cost, and with `request_log_mode: :async` the
  last few rows may not be counted yet. `vision_batch/3` stops on it as on
  its own `budget:` (`stopped: :run_budget`).
  `{:error, :run_budget_without_run}` for a `run_budget:` without a usable
  `run:`, `{:error, {:invalid_run_budget, reason}}` for an amount that is not
  one.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias PhoenixKitAI.{Guard, Money, Request}

  @type bucket :: %{
          calls: non_neg_integer(),
          errors: non_neg_integer(),
          refused: non_neg_integer(),
          cached: non_neg_integer(),
          unparsed: non_neg_integer(),
          cost: Decimal.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @type t :: %{
          run: String.t(),
          total: bucket(),
          by_step: %{optional(String.t() | nil) => bucket()},
          by_model: %{optional(String.t() | nil) => bucket()},
          first_at: DateTime.t() | nil,
          last_at: DateTime.t() | nil
        }

  @doc """
  The totals of `run`: `%{run, total, by_step, by_model, first_at, last_at}`,
  each bucket `%{calls, errors, refused, cached, unparsed, cost,
  input_tokens, output_tokens}` with `cost` in dollars (a `Decimal`).
  `errors` includes `refused`. `unparsed` counts vision calls that were
  answered, and billed, but not with the JSON asked for: their rows are
  successful provider calls, so they are in `calls` and `cost` and not in
  `errors` (a chat call's unparsed JSON answer is not marked and counts as
  a plain success). Options: `since:` / `until:` (`DateTime`).

  `{:error, :invalid_run}` when `run` is not a usable tag.
  """
  @spec costs(term(), keyword()) :: {:ok, t()} | {:error, :invalid_run}
  def costs(run, opts \\ []) do
    case Guard.run_tag(run) do
      nil -> {:error, :invalid_run}
      tag -> {:ok, summarize(tag, rows(tag, opts))}
    end
  end

  @typedoc "A run's spend against its ceiling (`ceiling/3`)."
  @type ceiling_status :: %{
          run: String.t(),
          spent: Decimal.t(),
          ceiling: Decimal.t(),
          remaining: Decimal.t(),
          reached?: boolean()
        }

  @doc """
  What `run` has spent (its successful rows' cost, in dollars) against
  `ceiling` (dollars, a `Decimal` or a decimal string). Options: `since:`
  (a `DateTime`), as `run_since:` on a verb. `reached?` is true once
  `spent >= ceiling`; `remaining` is never negative.
  """
  @spec ceiling(term(), Decimal.t() | String.t(), keyword()) ::
          {:ok, ceiling_status()} | {:error, term()}
  def ceiling(run, ceiling, opts \\ []) do
    with {:ok, tag} <- tag(run), do: ceiling_of(tag, ceiling, opts[:since])
  end

  # `tag` is already a run tag: normalising it again could change it (a tag
  # cut at the length limit may end in a space the second pass trims), and
  # the rows carry the first normalisation.
  defp ceiling_of(tag, ceiling, since) do
    with {:ok, ceiling} <- ceiling_amount(ceiling) do
      spent = spent(tag, since)
      remaining = Decimal.sub(ceiling, spent)

      {:ok,
       %{
         run: tag,
         spent: spent,
         ceiling: ceiling,
         remaining: if(Decimal.negative?(remaining), do: Decimal.new(0), else: remaining),
         reached?: Decimal.compare(spent, ceiling) != :lt
       }}
    end
  end

  @doc """
  The check every verb runs before its call (see "A ceiling for a run"):
  `:ok` when the call names no `run_budget:` or the run has room,
  `{:error, {:run_budget_reached, run}}` once it has spent it.
  """
  @spec check_ceiling(keyword()) :: :ok | {:error, term()}
  def check_ceiling(opts) do
    case Keyword.get(opts, :run_budget) do
      nil ->
        :ok

      budget ->
        with {:ok, tag} <- ceiling_run(opts[:run]),
             {:ok, status} <- ceiling_of(tag, budget, since(opts)),
             do: reached(status)
    end
  end

  defp reached(%{reached?: true, run: tag}), do: {:error, {:run_budget_reached, tag}}
  defp reached(_status), do: :ok

  @doc """
  Whether a call's `run_budget:` is usable, before anything is checked or
  written: `:ok` without one, else `{:error, :run_budget_without_run}` or
  `{:error, {:invalid_run_budget, reason}}`. A call refused here writes no row
  (it is the caller's mistake, not a call turned away).
  """
  @spec validate_ceiling(keyword()) :: :ok | {:error, term()}
  def validate_ceiling(opts) do
    case Keyword.get(opts, :run_budget) do
      nil ->
        :ok

      budget ->
        with {:ok, _tag} <- ceiling_run(opts[:run]),
             {:ok, _amount} <- ceiling_amount(budget),
             do: :ok
    end
  end

  @doc """
  Whether an error is a run's ceiling (`{:run_budget_reached, run}`): the
  job is done for now, nothing failed.
  """
  @spec ceiling_reached?(term()) :: boolean()
  def ceiling_reached?({:run_budget_reached, _run}), do: true
  def ceiling_reached?({:error, {:run_budget_reached, _run}}), do: true
  def ceiling_reached?(_reason), do: false

  defp tag(run) do
    case Guard.run_tag(run) do
      nil -> {:error, :invalid_run}
      tag -> {:ok, tag}
    end
  end

  defp ceiling_run(run) do
    case Guard.run_tag(run) do
      nil -> {:error, :run_budget_without_run}
      tag -> {:ok, tag}
    end
  end

  defp since(opts) do
    case opts[:run_since] do
      %DateTime{} = since -> since
      _ -> nil
    end
  end

  defp ceiling_amount(value) do
    case Money.amount(value) do
      {:ok, amount} -> {:ok, amount}
      {:error, reason} -> {:error, {:invalid_run_budget, reason}}
      :error -> {:error, {:invalid_run_budget, :not_an_amount}}
    end
  end

  # Successful rows only, like the caps: a failure or a refusal costs nothing.
  # `"success"` stays a literal for the partial indexes (see `Budget`).
  defp spent(tag, since) do
    query =
      from(r in Request,
        where: fragment("?->>'run' = ?", r.metadata, ^tag) and r.status == "success",
        select: coalesce(sum(r.cost), 0)
      )

    query =
      case since do
        %DateTime{} -> where(query, [r], r.inserted_at >= ^since)
        nil -> query
      end

    query |> PhoenixKit.RepoHelper.repo().one() |> Money.sum()
  end

  defp rows(tag, opts) do
    query =
      from(r in Request,
        where: fragment("?->>'run' = ?", r.metadata, ^tag),
        group_by: [
          fragment("?->>'step'", r.metadata),
          r.model,
          r.status,
          fragment("coalesce(?->>'refused', 'false')", r.metadata),
          fragment("coalesce(?->>'cached', 'false')", r.metadata),
          fragment("coalesce(?->>'unparsed', 'false')", r.metadata)
        ],
        select: %{
          step: fragment("?->>'step'", r.metadata),
          model: r.model,
          status: r.status,
          refused: fragment("coalesce(?->>'refused', 'false')", r.metadata),
          cached: fragment("coalesce(?->>'cached', 'false')", r.metadata),
          unparsed: fragment("coalesce(?->>'unparsed', 'false')", r.metadata),
          calls: count(r.uuid),
          cost: sum(r.cost),
          input_tokens: sum(r.input_tokens),
          output_tokens: sum(r.output_tokens),
          first_at: min(r.inserted_at),
          last_at: max(r.inserted_at)
        }
      )

    query =
      case opts[:since] do
        %DateTime{} = since -> where(query, [r], r.inserted_at >= ^since)
        _ -> query
      end

    query =
      case opts[:until] do
        %DateTime{} = until -> where(query, [r], r.inserted_at < ^until)
        _ -> query
      end

    PhoenixKit.RepoHelper.repo().all(query)
  end

  defp summarize(tag, rows) do
    %{
      run: tag,
      total: Enum.reduce(rows, empty(), &add/2),
      by_step: group(rows, & &1.step),
      by_model: group(rows, & &1.model),
      first_at:
        rows
        |> Enum.map(& &1.first_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime, fn -> nil end),
      last_at:
        rows
        |> Enum.map(& &1.last_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)
    }
  end

  defp group(rows, key) do
    rows
    |> Enum.group_by(key)
    |> Map.new(fn {k, list} -> {k, Enum.reduce(list, empty(), &add/2)} end)
  end

  defp empty,
    do: %{
      calls: 0,
      errors: 0,
      refused: 0,
      cached: 0,
      unparsed: 0,
      cost: Decimal.new(0),
      input_tokens: 0,
      output_tokens: 0
    }

  defp add(row, acc) do
    %{
      calls: acc.calls + row.calls,
      errors: acc.errors + if(row.status == "success", do: 0, else: row.calls),
      refused: acc.refused + if(row.refused == "true", do: row.calls, else: 0),
      cached: acc.cached + if(row.cached == "true", do: row.calls, else: 0),
      unparsed: acc.unparsed + if(row.unparsed == "true", do: row.calls, else: 0),
      cost: Decimal.add(acc.cost, row.cost || Decimal.new(0)),
      input_tokens: acc.input_tokens + (row.input_tokens || 0),
      output_tokens: acc.output_tokens + (row.output_tokens || 0)
    }
  end
end
