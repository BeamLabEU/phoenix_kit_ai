defmodule PhoenixKitAI.JournalPruneWorker do
  @moduledoc """
  Applies the AI journal's retention (`PhoenixKitAI.Retention`): nightly,
  scheduled by the module's `oban_crons/0`, and by hand.

  **Nightly** (`args` without `"mode"`): reads the periods; a kind kept
  forever, or changed less than a day ago, is left alone. A night that
  already ran with `ok` less than 20 hours ago is skipped without a
  stamp, so a second crontab entry or the old worker's shim runs nothing
  twice. With the module off the run is stamped `skipped`.

  **By hand** (`manual_job/2`): the boundaries travel in the job and are
  held at the floor again here (`Retention.effective_cutoff/3`), so a
  forged job deletes nothing newer than it.

  A failed check (a boundary in the future, a foreign key that blocks,
  unreadable arguments) is `{:cancel, reason}`: nothing deleted, no retry,
  `failed` in the stamp.
  A chunk that fails is an error: Oban retries (3 attempts), each attempt
  counting from zero. Runs in core's `default` queue. One at a time: the
  nightly and the manual job conflict with each other in every state but
  done (no `:suspended`, which Oban's query refuses on a database migrated
  before Oban 14 — the cron inserts through `new/2`, so every nightly
  insert would fail). Options of the run (chunk sizes, pause, time slices)
  come from `config :phoenix_kit_ai, :journal_prune`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker],
      keys: [],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias PhoenixKitAI.Retention

  @once_per_night_hours 20
  @settle_hours 24

  @doc """
  A manual run's job: `cutoffs` per kind (`nil` or missing: not touched)
  and the person who asked. Insert it with `Oban.insert/1`; a
  `%Oban.Job{conflict?: true}` back means a run is already queued or
  running.
  """
  @spec manual_job(Retention.cutoffs(), String.t() | nil) :: Ecto.Changeset.t()
  def manual_job(cutoffs, actor_uuid) when is_map(cutoffs) do
    new(%{
      "mode" => "manual",
      "actor_uuid" => actor_uuid,
      "cutoffs" =>
        Map.new(Retention.kinds(), fn kind ->
          {Atom.to_string(kind), cutoffs[kind] && DateTime.to_iso8601(cutoffs[kind])}
        end)
    })
  end

  @impl Oban.Worker
  def timeout(_job), do: Retention.job_timeout_ms()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "manual"} = args} = job) do
    actor = if is_binary(args["actor_uuid"]), do: args["actor_uuid"]
    opts = Keyword.put(run_options(), :actor_uuid, actor)

    if PhoenixKitAI.enabled?() do
      case parse_cutoffs(args["cutoffs"]) do
        {:ok, cutoffs} ->
          run_manual(cutoffs, still_asked(cutoffs, job.inserted_at), opts)

        :error ->
          Retention.record_refused(:manual, "invalid_args", opts)
          {:cancel, :invalid_args}
      end
    else
      Retention.record_skipped(:manual, opts)
    end
  end

  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    cond do
      not PhoenixKitAI.enabled?() ->
        Retention.record_skipped(:scheduled)

      ran_tonight?(now) ->
        :ok

      true ->
        :scheduled |> Retention.run(nightly_cutoffs(now), [now: now] ++ run_options()) |> result()
    end
  end

  # The job's boundaries were confirmed against the periods of that moment and
  # stay in its arguments through every retry. A kind whose period changed while
  # the job waited is left out: the change is the newer decision, and a deletion
  # cannot be taken back. Nothing left means nothing to do.
  defp run_manual(cutoffs, kept, opts) do
    if any_cutoff?(cutoffs) and not any_cutoff?(kept) do
      Retention.record_refused(:manual, "periods_changed", opts)
      {:cancel, :periods_changed}
    else
      :manual |> Retention.run(kept, opts) |> result()
    end
  end

  defp any_cutoff?(cutoffs), do: Enum.any?(cutoffs, fn {_kind, at} -> at != nil end)

  defp still_asked(cutoffs, nil), do: cutoffs

  defp still_asked(cutoffs, queued_at) do
    changed_at = Retention.settings().changed_at

    Map.new(cutoffs, fn {kind, at} ->
      {kind, if(changed_since?(changed_at[kind], queued_at), do: nil, else: at)}
    end)
  end

  defp changed_since?(%DateTime{} = changed, queued_at),
    do: DateTime.compare(changed, queued_at) == :gt

  defp changed_since?(_changed, _queued_at), do: false

  defp result({:ok, _summary}), do: :ok
  defp result(other), do: other

  # The host's options for the run; never its moment or its person, which
  # are the job's own.
  defp run_options do
    case Application.get_env(:phoenix_kit_ai, :journal_prune, []) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts), do: Keyword.drop(opts, [:now, :actor_uuid]), else: ignored()

      _ ->
        ignored()
    end
  end

  defp ignored do
    Logger.warning(
      "[PhoenixKitAI.JournalPruneWorker] :journal_prune is not a keyword list; ignored"
    )

    []
  end

  defp ran_tonight?(now) do
    case Retention.last_run().scheduled do
      %{status: :ok, at: %DateTime{} = at} ->
        DateTime.diff(now, at, :second) < @once_per_night_hours * 3600

      _ ->
        false
    end
  end

  # A kind kept forever, or changed less than a day ago, has no boundary.
  defp nightly_cutoffs(now) do
    settings = Retention.settings()

    Map.new(Retention.kinds(), fn kind ->
      changed_at = settings.changed_at[kind]

      cutoff =
        with true <- settled?(changed_at, now),
             {:ok, cutoff} <- Retention.cutoff(kind, settings[kind], now) do
          cutoff
        else
          _ -> nil
        end

      {kind, cutoff}
    end)
  end

  defp settled?(%DateTime{} = changed_at, now),
    do: DateTime.diff(now, changed_at, :second) >= @settle_hours * 3600

  defp settled?(_changed_at, _now), do: false

  defp parse_cutoffs(%{} = cutoffs) do
    Enum.reduce_while(Retention.kinds(), {:ok, %{}}, fn kind, {:ok, acc} ->
      case parse_cutoff(cutoffs[Atom.to_string(kind)]) do
        {:ok, at} -> {:cont, {:ok, Map.put(acc, kind, at)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_cutoffs(_cutoffs), do: :error

  defp parse_cutoff(nil), do: {:ok, nil}

  defp parse_cutoff(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> :error
    end
  end

  defp parse_cutoff(_value), do: :error
end
