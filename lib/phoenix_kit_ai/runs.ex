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
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias PhoenixKitAI.{Guard, Request}

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
