defmodule PhoenixKitAI.TranslationSweep do
  @moduledoc """
  The background top-up of AI translations a module can switch on: a
  self-rescheduling Oban chain that, every few minutes, enqueues
  `PhoenixKitAI.TranslateWorker` jobs for the translations its resources
  are missing or have let go stale.

  A module keeps its own Oban worker (its name is what already-scheduled
  jobs point at) and implements this module's callbacks on it; the
  worker's `perform/1` hands over to `perform/1` here, and every other
  operation — scheduling, a manual run, the last outcome — takes the
  worker module:

      defmodule MyModule.Workers.TranslationSweepWorker do
        use Oban.Worker, queue: :default, max_attempts: 1
        @behaviour PhoenixKitAI.TranslationSweep

        @impl Oban.Worker
        def perform(_job), do: PhoenixKitAI.TranslationSweep.perform(__MODULE__)

        @impl PhoenixKitAI.TranslationSweep
        def sweep_key, do: "my_module"
        # … the other callbacks
      end

  ## A tick

  1. Schedule the next tick — first, so a tick that crashes later still
     leaves the chain alive. At most one tick waits per worker
     (`unique` on the worker, `available`/`scheduled` only: a running tick
     must be able to schedule its successor).
  2. Stop, recording why, when the source is not ready (`sweep_ready/1`),
     the automatic sweep is off (a manual run skips only this check), AI
     is unavailable or its default endpoint is gone, no target language
     is set, or a cap is below 1 (`:sweep_stalled` — nothing could ever
     be admitted).
  3. Stop at `:ceiling_reached` when the source's incomplete
     `TranslateWorker` jobs already fill `max_in_flight`.
  4. Take the candidates in the source's order, drop each language that
     already has a job in flight (admitting it would spend both budgets on
     a job the enqueue then skips) or whose latest job for that resource
     was discarded in the last 24 hours (a pair that keeps failing would
     otherwise be re-enqueued every tick), and admit the rest within both
     caps — `batch` resources, and the job room left under
     `max_in_flight`. A candidate that does not fit whole is admitted for
     the languages that do; the rest wait for the next tick.
  5. Enqueue each admitted resource's languages
     (`Translations.enqueue_all_missing/2`, which skips a pair already in
     flight) and record the outcome.

  The outcome is kept as the source's last run (`last_run/1`) — written
  only when it differs from the one stored, with the time it first
  happened: the record is a setting, every settings change is a permanent
  history entry, and a tick an hour that ends the same way would otherwise
  add one forever. `status/1` adds when the next tick fires and whether
  one is running.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitAI.Translations

  @translate_worker "PhoenixKitAI.TranslateWorker"
  # The job states that mean "still to happen"; `:suspended` is left out on
  # purpose — it is missing from `oban_job_state` on some hosts and a query
  # naming it raises 22P02 (see `PhoenixKitAI.Translations`).
  @incomplete_states ~w(available scheduled executing retryable)
  @unique [period: :infinity, states: [:available, :scheduled]]
  @backoff_hours 24
  @unlimited 1_000_000_000

  @type trigger :: :interval | :manual
  @type candidate :: %{
          required(:resource_type) => String.t(),
          required(:uuid) => String.t(),
          required(:languages) => [String.t()]
        }
  @type settings :: %{
          required(:enabled?) => boolean(),
          required(:interval_minutes) => pos_integer(),
          required(:languages) => [String.t()],
          optional(:batch) => non_neg_integer() | :infinity,
          optional(:max_in_flight) => non_neg_integer() | :infinity,
          optional(:source_language) => String.t()
        }

  @doc "Names the source: its last run is kept under this key."
  @callback sweep_key() :: String.t()

  @doc """
  The source's settings, read fresh on every tick: whether the automatic
  sweep is on, minutes between ticks, the target languages, and the two
  caps (`batch` resources per tick, `max_in_flight` incomplete jobs —
  both `:infinity` when absent). `source_language` defaults to the site's
  primary language.
  """
  @callback sweep_settings() :: settings()

  @doc """
  Source-specific gates checked before anything else, told whether the
  tick is automatic or a manual run: `:ok` or `{:stop, reason}`.
  """
  @callback sweep_ready(trigger()) :: :ok | {:stop, atom()}

  @doc "The `ai_translatables/0` resource types this source translates."
  @callback sweep_resource_types() :: [String.t()]

  @doc """
  Resources with translations missing or stale, each with the target
  languages it needs, **in the order they should be taken** — the budget
  admits from the front and stops at the first that does not fit.
  """
  @callback sweep_candidates(source_lang :: String.t(), target_langs :: [String.t()]) ::
              [candidate()]

  @doc "The prompt to translate each resource type with."
  @callback sweep_prompts() :: {:ok, %{String.t() => String.t()}} | {:error, term()}

  @optional_callbacks sweep_ready: 1

  # ── The chain ──────────────────────────────────────────────────────

  @doc """
  A tick: schedules the next one, then sweeps. For the worker's
  `perform/1`; always `:ok` — a failed tick is not worth a retry when its
  successor is already waiting.
  """
  @spec perform(module()) :: :ok
  def perform(source) do
    _ = ensure_scheduled(source)
    _ = run_tick(source, :interval)
    :ok
  end

  @doc """
  Makes sure one tick is waiting for `source`, at its current interval.
  Safe to call any number of times, from anywhere — the worker's
  uniqueness keeps it to one.
  """
  @spec ensure_scheduled(module()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled(source) do
    seconds = settings(source).interval_minutes * 60

    %{}
    |> source.new(schedule_in: seconds, unique: @unique)
    |> Oban.insert()
  rescue
    error -> schedule_failed(source, error)
  catch
    :exit, reason -> schedule_failed(source, {:exit, reason})
  end

  @doc """
  Moves the waiting tick to the current interval from now — call it after
  the interval is saved, or a shortened interval would wait out the old
  one — and schedules one if none is waiting. A tick already due or
  running is left alone: it schedules its successor at the new interval.

  The move is one `UPDATE` guarded on the job still being `scheduled`,
  which Postgres re-checks on the row it locks; cancelling instead would
  kill a tick that started between reading the job and cancelling it.
  """
  @spec reschedule(module()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def reschedule(source) do
    at = DateTime.add(DateTime.utc_now(), settings(source).interval_minutes * 60, :second)

    from(j in Oban.Job, where: j.worker == ^worker_name(source) and j.state == "scheduled")
    |> repo().update_all(set: [scheduled_at: at])

    ensure_scheduled(source)
  rescue
    error -> schedule_failed(source, error)
  catch
    :exit, reason -> schedule_failed(source, {:exit, reason})
  end

  @doc "When the waiting tick fires, or `nil` when none is waiting."
  @spec next_tick_at(module()) :: DateTime.t() | nil
  def next_tick_at(source) do
    from(j in Oban.Job,
      where: j.worker == ^worker_name(source) and j.state in ["available", "scheduled"],
      order_by: [asc: j.scheduled_at],
      limit: 1,
      select: j.scheduled_at
    )
    |> repo().one()
  end

  @doc "Whether a tick of `source` is running right now."
  @spec running?(module()) :: boolean()
  def running?(source) do
    from(j in Oban.Job, where: j.worker == ^worker_name(source) and j.state == "executing")
    |> repo().exists?()
  end

  # ── A tick's work ──────────────────────────────────────────────────

  @doc """
  The tick's work without the scheduling. `:manual` is an operator's run:
  it skips only the automatic-sweep switch. Answers and records
  `{reason, info}` — `reason` is `:ok` (it swept; `info` counts
  candidates, enqueued, conflicts, errors, backed_off, in_flight) or why
  it stopped: the source's own reason, `:sweep_disabled`,
  `:ai_unavailable`, `:no_target_languages`, `:sweep_stalled`,
  `:ceiling_reached`, `:prompts_unavailable`.
  """
  @spec run_tick(module(), trigger()) :: {atom(), map()}
  def run_tick(source, trigger \\ :interval) do
    settings = settings(source)

    with :ok <- ready(source, trigger),
         :ok <- automatic_on(settings, trigger),
         :ok <- ai_available(),
         :ok <- has_languages(settings),
         :ok <- caps_admit(settings),
         {:ok, busy, room} <- room(source, settings) do
      sweep(source, settings, busy, room)
    else
      {:stop, reason, info} -> finish(source, reason, info)
    end
  end

  defp ready(source, trigger) do
    if function_exported?(source, :sweep_ready, 1) do
      case source.sweep_ready(trigger) do
        :ok -> :ok
        {:stop, reason} -> {:stop, reason, %{}}
      end
    else
      :ok
    end
  end

  defp automatic_on(%{enabled?: true}, _trigger), do: :ok
  defp automatic_on(_settings, :manual), do: :ok
  defp automatic_on(_settings, :interval), do: {:stop, :sweep_disabled, %{}}

  defp ai_available do
    if Translations.available?() and is_binary(Translations.default_endpoint_uuid()),
      do: :ok,
      else: {:stop, :ai_unavailable, %{}}
  end

  defp has_languages(%{languages: []}), do: {:stop, :no_target_languages, %{}}
  defp has_languages(_settings), do: :ok

  defp caps_admit(%{batch: batch, max_in_flight: max}) when batch < 1 or max < 1,
    do: {:stop, :sweep_stalled, %{batch: batch, max_in_flight: max}}

  defp caps_admit(_settings), do: :ok

  # `busy` is one {type, uuid, lang} per incomplete job: its length is what
  # presses on the ceiling, its pairs are what the sweep must not re-admit.
  defp room(source, %{max_in_flight: max}) do
    busy = in_flight(source.sweep_resource_types())
    in_flight = length(busy)

    if in_flight >= max,
      do: {:stop, :ceiling_reached, %{in_flight: in_flight}},
      else: {:ok, busy, max - in_flight}
  end

  defp sweep(source, settings, busy, room) do
    targets = settings.languages

    {candidates, _in_flight} =
      settings.source_language
      |> source.sweep_candidates(targets)
      |> merge_repeats()
      |> Enum.map(&only_targets(&1, targets))
      |> without_pairs(Map.new(busy, &{&1, true}))

    failed = recently_failed(source.sweep_resource_types())
    {kept, backed_off} = without_pairs(candidates, failed)
    selected = take_within_budget(kept, settings.batch, room)

    case prompts(source, selected) do
      {:ok, prompts} ->
        counts = enqueue(selected, prompts, settings.source_language)

        finish(
          source,
          :ok,
          Map.merge(counts, %{
            candidates: length(selected),
            backed_off: backed_off,
            in_flight: length(busy)
          })
        )

      {:error, reason} ->
        finish(source, :prompts_unavailable, %{error: failure_shape(reason)})
    end
  end

  # A resource listed twice would take two batch slots for one resource:
  # its languages join its first entry, in order.
  defp merge_repeats(candidates) do
    {order, by_key} =
      Enum.reduce(candidates, {[], %{}}, fn c, {order, by_key} ->
        key = {c.resource_type, c.uuid}

        case by_key do
          %{^key => first} ->
            {order, %{by_key | key => %{first | languages: first.languages ++ c.languages}}}

          _ ->
            {[key | order], Map.put(by_key, key, c)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_key, &1))
  end

  defp only_targets(candidate, targets) do
    %{candidate | languages: candidate.languages |> Enum.filter(&(&1 in targets)) |> Enum.uniq()}
  end

  # Leaves out every language whose {type, uuid, lang} is a key of `pairs`; a
  # candidate left with none is dropped. Answers the rest and how many
  # (resource, language) pairs were left out.
  defp without_pairs(candidates, pairs) do
    Enum.flat_map_reduce(candidates, 0, fn c, held ->
      {skipped, kept} =
        Enum.split_with(c.languages, &Map.has_key?(pairs, {c.resource_type, c.uuid, &1}))

      if kept == [],
        do: {[], held + length(skipped)},
        else: {[%{c | languages: kept}], held + length(skipped)}
    end)
  end

  @doc """
  Admits candidates in order while both budgets last: `resources` of
  them, and `jobs` languages in all. A candidate whose languages do not
  all fit is admitted for those that do; admission stops when either
  budget runs out. `:infinity` is no limit.
  """
  @spec take_within_budget(
          [candidate()],
          non_neg_integer() | :infinity,
          non_neg_integer() | :infinity
        ) :: [candidate()]
  def take_within_budget(candidates, resources, jobs) do
    candidates
    |> Enum.reduce_while({[], limit(resources), limit(jobs)}, fn c, {acc, res, job} ->
      if res <= 0 or job <= 0 do
        {:halt, {acc, res, job}}
      else
        langs = Enum.take(c.languages, job)
        {:cont, {[%{c | languages: langs} | acc], res - 1, job - length(langs)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp limit(:infinity), do: @unlimited
  defp limit(n) when is_integer(n), do: n

  defp prompts(_source, []), do: {:ok, %{}}

  defp prompts(source, _selected) do
    case source.sweep_prompts() do
      {:ok, %{} = prompts} -> {:ok, prompts}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_answer, other}}
    end
  end

  # Errors are counted per language, whichever way a language failed.
  defp enqueue(selected, prompts, source_lang) do
    endpoint_uuid = Translations.default_endpoint_uuid()

    Enum.reduce(selected, %{enqueued: 0, conflicts: 0, errors: 0}, fn c, acc ->
      case Map.get(prompts, c.resource_type) do
        nil -> %{acc | errors: acc.errors + length(c.languages)}
        prompt_uuid -> enqueue_one(c, prompt_uuid, endpoint_uuid, source_lang, acc)
      end
    end)
  end

  defp enqueue_one(candidate, prompt_uuid, endpoint_uuid, source_lang, acc) do
    params = %{
      resource_type: candidate.resource_type,
      resource_uuid: candidate.uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: source_lang,
      # A system run: nobody started this job.
      actor_uuid: nil
    }

    case Translations.enqueue_all_missing(params, candidate.languages) do
      {:ok, result} ->
        %{
          acc
          | enqueued: acc.enqueued + result.enqueued,
            conflicts: acc.conflicts + result.conflicts,
            errors: acc.errors + length(result.errors)
        }

      {:error, _reason} ->
        %{acc | errors: acc.errors + length(candidate.languages)}
    end
  end

  # {type, uuid, lang} of each of the source's incomplete TranslateWorker
  # jobs — its own resource types only, so two sources do not throttle each
  # other. Fails open (none): a query error must not stop the sweep for
  # good, and `enqueue_all_missing/2` still skips a pair in flight.
  defp in_flight([]), do: []

  defp in_flight(types) do
    from(j in "oban_jobs",
      where: j.worker == ^@translate_worker and j.state in ^@incomplete_states,
      where: fragment("?->>'resource_type'", j.args) in ^types,
      select:
        {fragment("?->>'resource_type'", j.args), fragment("?->>'resource_uuid'", j.args),
         fragment("?->>'target_lang'", j.args)}
    )
    |> repo().all()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # {resource_type, uuid, lang} of every pair whose LATEST job was
  # discarded inside the window — a later job (a success, or one still
  # running) clears it. Fails open (none).
  defp recently_failed([]), do: %{}

  defp recently_failed(types) do
    since = DateTime.add(DateTime.utc_now(), -@backoff_hours * 3600, :second)

    from(j in "oban_jobs",
      where: j.worker == ^@translate_worker,
      where: j.inserted_at > ^since or j.discarded_at > ^since,
      where: fragment("?->>'resource_type'", j.args) in ^types,
      distinct: [
        fragment("?->>'resource_type'", j.args),
        fragment("?->>'resource_uuid'", j.args),
        fragment("?->>'target_lang'", j.args)
      ],
      order_by: [desc: j.id],
      select:
        {fragment("?->>'resource_type'", j.args), fragment("?->>'resource_uuid'", j.args),
         fragment("?->>'target_lang'", j.args), j.state,
         fragment("coalesce(? > ?, false)", j.discarded_at, ^since)}
    )
    |> repo().all()
    |> Enum.filter(fn {_t, _u, _l, state, recent?} -> state == "discarded" and recent? end)
    |> Map.new(fn {t, u, l, _state, _recent?} -> {{t, u, l}, true} end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # ── The outcome ────────────────────────────────────────────────────

  defp finish(source, reason, info) do
    outcome =
      info
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("reason", to_string(reason))

    stored = last_run(source)

    if is_nil(stored) or Map.delete(stored, "since") != outcome do
      record = Map.put(outcome, "since", DateTime.to_iso8601(now()))

      case Settings.update_json_setting_with_module(last_run_key(source), record, "ai") do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "[TranslationSweep] could not record #{source.sweep_key()}'s last run: #{failure_shape(error)}"
          )
      end
    end

    {reason, info}
  rescue
    error ->
      Logger.warning("[TranslationSweep] could not record the last run: #{failure_shape(error)}")
      {reason, info}
  end

  @doc """
  The last tick's outcome — `%{"reason" => …, "since" => iso8601,
  …counts}`, `since` being when ticks began ending this way — or `nil`
  before the first.
  """
  @spec last_run(module()) :: map() | nil
  def last_run(source) do
    case Settings.get_json_setting(last_run_key(source), nil) do
      %{"reason" => reason} = record when is_binary(reason) -> record
      _ -> nil
    end
  end

  @doc "The last outcome, the waiting tick and whether one is running, for a status panel."
  @spec status(module()) :: %{
          last_run: map() | nil,
          next_tick_at: DateTime.t() | nil,
          running?: boolean()
        }
  def status(source) do
    %{last_run: last_run(source), next_tick_at: next_tick_at(source), running?: running?(source)}
  end

  @doc "The setting a source's last run is kept under."
  @spec last_run_key(module()) :: String.t()
  def last_run_key(source), do: "ai_translation_sweep_last_run_" <> source.sweep_key()

  # ── Helpers ────────────────────────────────────────────────────────

  # The source's settings with the optional ones filled in.
  defp settings(source) do
    settings = source.sweep_settings()

    settings
    |> Map.put_new(:batch, :infinity)
    |> Map.put_new(:max_in_flight, :infinity)
    |> Map.update!(:batch, &limit/1)
    |> Map.update!(:max_in_flight, &limit/1)
    |> Map.put_new_lazy(:source_language, &Multilang.primary_language/0)
  end

  defp schedule_failed(source, error) do
    Logger.warning(
      "[TranslationSweep] could not schedule #{inspect(source)}'s next tick: #{failure_shape(error)}"
    )

    {:error, :schedule_failed}
  end

  defp failure_shape({:exit, _reason}), do: "exit"
  defp failure_shape(%{__struct__: mod}), do: inspect(mod)
  defp failure_shape(reason) when is_atom(reason), do: inspect(reason)

  defp failure_shape(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: inspect(elem(reason, 0))

  defp failure_shape(_reason), do: "an error"

  defp worker_name(source), do: inspect(source)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp repo, do: PhoenixKit.RepoHelper.repo()
end
