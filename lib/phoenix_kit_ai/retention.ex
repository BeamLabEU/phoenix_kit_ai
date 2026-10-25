defmodule PhoenixKitAI.Retention do
  @moduledoc """
  How long the AI journal is kept, and the cleanup that applies it.

  Three kinds, each with its own period (`:forever`, or N days, months or
  years):

    * `:content` — the request rows older than the period lose their
      content (`content_keys/0`) and get `metadata.content_pruned_at`; the
      row, its cost, tokens and the small keys stay. The `reason` of an
      `off_purpose` guard event older than the period is cleared too.
    * `:requests` — the request rows (`phoenix_kit_ai_requests`) older than
      the period are deleted.
    * `:guard_events` — the guard's events (`phoenix_kit_ai_guard_events`)
      older than the period are deleted.

  Nothing is deleted by default. A period's boundary is a local midnight
  or the start of a local month in the site time zone (`cutoff/3`). One
  technical guard sits under every boundary, whatever its origin: the
  floor (`floor/2`). Journal rows and guard events newer than local
  midnight two days before the current month began are never deleted —
  the day and month limits, the 24-hour spend cap and the month's forgiven
  limits read them — and content newer than 24 hours is never cleared. A
  shorter period is clamped to the floor (`effective_cutoff/3`). The event
  an active block was set from is never deleted nor cleared while the
  block stands.

  The periods are the JSON setting `ai_journal_retention`, read without the
  settings cache; the outcome of each run is `ai_journal_retention_last_run`,
  written without settings history. The cleanup itself runs in
  `PhoenixKitAI.JournalPruneWorker`, in short chunks (`run/3`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAI.{Guard, GuardBlock, GuardEvent, JournalPruneWorker, Request}

  # ===========================================
  # POLICY
  # ===========================================
  #
  # The owner's decisions, kept here and nowhere else: every other function
  # and the tests read them through the functions below. Default: keep each
  # kind forever. Any period, in days, months or years, up to the largest N
  # (which keeps the boundary inside PostgreSQL's timestamp range). Who may
  # set and run each kind: `ai.manage` or an Owner, unless the kind is in
  # the owner-only list (empty: every kind is `ai.manage`'s).

  @kinds [:content, :requests, :guard_events]
  @defaults %{content: :forever, requests: :forever, guard_events: :forever}
  @owner_only_kinds []
  @max_n %{day: 36_500, month: 1_200, year: 100}

  # The floor of journal rows and guard events: local midnight this many
  # days before the first of the current month; of content, this many hours
  # before now.
  @floor_days_before_month 2
  @content_floor_hours 24

  @setting_key "ai_journal_retention"
  @last_run_key "ai_journal_retention_last_run"

  # Written under the `capture_request_content?` gate (the content), kept
  # from older versions (`raw_response`), or debug context written outside
  # the gate but carrying the call's stack, process and, with
  # `capture_request_memory`, its memory (`stacktrace`, `caller_context`),
  # and the failure's reason, which carries a payload on an image call.
  @content_keys ~w(messages request_payload response response_reasoning response_tool_calls input raw_response stacktrace caller_context error_reason)

  # What a run counts: the three kinds and the cleared off-purpose reasons.
  @counters [:content, :requests, :guard_events, :guard_reasons]

  @job_timeout_ms :timer.minutes(25)

  @default_opts [
    request_batch: 1_000,
    content_batch: 500,
    content_min_batch: 50,
    event_batch: 1_000,
    pause_ms: 50,
    max_rows: 1_000_000,
    statement_timeout_ms: 30_000,
    lock_timeout_ms: 5_000,
    time_limits: %{
      requests: 10 * 60_000,
      content: 6 * 60_000,
      guard_reasons: 60_000,
      guard_events: 2 * 60_000
    }
  ]

  # The client waits this much longer than the statement may run, so the
  # database's own timeout (a clean, recordable error) always comes first.
  @client_margin_ms 5_000
  @preview_timeout_ms 60_000
  # Each counter may run past its slice by one chunk and then one probe
  # (two statements, each with the client's margin); this is the room left
  # in the job's timeout besides those: the checks before, the stamp after.
  @run_margin_ms 60_000
  @failure_log_hours 20

  @type kind :: :content | :requests | :guard_events
  @type unit :: :day | :month | :year
  @type period :: :forever | {pos_integer(), unit()}
  @type cutoffs :: %{optional(kind()) => DateTime.t() | nil}
  @type mode :: :scheduled | :manual

  @doc "The three kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The period of each kind when nothing is set."
  @spec defaults() :: %{kind() => period()}
  def defaults, do: @defaults

  @doc "The kinds only an Owner may set or run (none: every kind is `ai.manage`'s)."
  @spec owner_only_kinds() :: [kind()]
  def owner_only_kinds, do: @owner_only_kinds

  @doc "The units a period is counted in."
  @spec units() :: [unit()]
  def units, do: [:day, :month, :year]

  @doc "The largest N of a period in `unit`."
  @spec max_n(unit()) :: pos_integer()
  def max_n(unit) when is_map_key(@max_n, unit), do: Map.fetch!(@max_n, unit)

  @doc """
  Whether `scope` may change the period of `kind` (and see its preview):
  an Owner for the kinds in `owner_only_kinds/0`, `ai.manage` or an Owner
  for the others.
  """
  @spec may_set?(term(), kind()) :: boolean()
  def may_set?(scope, kind) when kind in @kinds do
    if Enum.member?(owner_only_kinds(), kind),
      do: owner?(scope),
      else: PhoenixKitAI.Guard.may_manage?(scope)
  end

  @doc "Whether `scope` may run a cleanup of `kind` by hand; the same rule as `may_set?/2`."
  @spec may_run?(term(), kind()) :: boolean()
  def may_run?(scope, kind), do: may_set?(scope, kind)

  defp owner?(%Scope{} = scope), do: Scope.owner?(scope)
  defp owner?(_scope), do: false

  @doc "The setting holding the periods."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @doc "The setting holding the outcome of the last runs."
  @spec last_run_key() :: String.t()
  def last_run_key, do: @last_run_key

  @doc false
  # The job's timeout; the time slices of a run stay inside it.
  @spec job_timeout_ms() :: pos_integer()
  def job_timeout_ms, do: @job_timeout_ms

  @doc """
  The metadata keys the content step removes from a request row.

  The content written under `capture_request_content?`, `raw_response` of
  rows from older versions, and the debug context (`stacktrace`,
  `caller_context`, `error_reason`). Every other key stays: the money and
  limit readers rely on the small ones (`task`, `refused`, `cached`, …).
  """
  @spec content_keys() :: [String.t()]
  def content_keys, do: @content_keys

  # ===========================================
  # PERIODS
  # ===========================================

  @doc """
  Reads a period in its stored form: `"forever"` or
  `%{"n" => N, "unit" => "day" | "month" | "year"}` with
  `1 <= N <= max_n(unit)`. Anything else is `:error`.
  """
  @spec parse_period(term()) :: {:ok, period()} | :error
  def parse_period("forever"), do: {:ok, :forever}

  def parse_period(%{"n" => n, "unit" => unit}) when is_integer(n) and is_binary(unit) do
    case Enum.find(units(), &(Atom.to_string(&1) == unit)) do
      nil -> :error
      unit -> if n >= 1 and n <= max_n(unit), do: {:ok, {n, unit}}, else: :error
    end
  end

  def parse_period(_value), do: :error

  @doc "A period in its stored form; the inverse of `parse_period/1`."
  @spec period_to_json(period()) :: String.t() | map()
  def period_to_json(:forever), do: "forever"
  def period_to_json({n, unit}), do: %{"n" => n, "unit" => Atom.to_string(unit)}

  # ===========================================
  # SETTINGS
  # ===========================================

  @doc """
  The periods in force: `%{content:, requests:, guard_events:}`, each
  `:forever` or `{n, unit}`, plus `changed_at` (each kind's last change,
  `nil` when unknown) and `unconfirmed` (the kinds stored with a period but
  no `changed_at`, read as `:forever` until saved again).

  Read without the cache. Anything in doubt reads as `:forever`, with a
  warning in the log: a database error, a value of the wrong form or out of
  range, a period without its `changed_at`.
  """
  @spec settings() :: %{
          required(kind()) => period(),
          required(:changed_at) => %{kind() => DateTime.t() | nil},
          required(:unconfirmed) => [kind()]
        }
  def settings do
    @setting_key |> Settings.get_json_setting() |> parse_settings()
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI.Retention] periods unreadable, kept forever: #{inspect(error.__struct__)}"
      )

      forever()
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI.Retention] periods unreadable (exit), kept forever")
      forever()
  end

  defp forever do
    @kinds
    |> Map.new(&{&1, :forever})
    |> Map.merge(%{changed_at: Map.new(@kinds, &{&1, nil}), unconfirmed: []})
  end

  @doc """
  `settings/0` read from a stored document instead of the database: the
  value core broadcasts in `{:setting_changed, key, value}` for
  `setting_key/0`, read with the same rules (anything in doubt is
  `:forever`).
  """
  @spec settings_from(term()) :: map()
  def settings_from(doc), do: parse_settings(doc)

  defp parse_settings(nil), do: forever()

  defp parse_settings(%{} = doc) do
    changed = if is_map(doc["changed_at"]), do: doc["changed_at"], else: %{}

    Enum.reduce(@kinds, forever(), fn kind, acc ->
      name = Atom.to_string(kind)
      changed_at = parse_datetime(changed[name])
      acc = put_in(acc, [:changed_at, kind], changed_at)
      put_period(acc, kind, name, Map.fetch(doc, name), changed_at)
    end)
  end

  defp parse_settings(_other) do
    Logger.warning(
      "[PhoenixKitAI.Retention] the periods setting is not a JSON object; kept forever"
    )

    forever()
  end

  defp put_period(acc, kind, _name, :error, _changed_at),
    do: Map.put(acc, kind, Map.fetch!(@defaults, kind))

  defp put_period(acc, kind, name, {:ok, value}, changed_at) do
    case parse_period(value) do
      {:ok, :forever} ->
        acc

      {:ok, period} when is_struct(changed_at, DateTime) ->
        Map.put(acc, kind, period)

      {:ok, _period} ->
        Logger.warning(
          "[PhoenixKitAI.Retention] #{name} has a period but no changed_at; kept forever until saved again"
        )

        Map.update!(acc, :unconfirmed, &(&1 ++ [kind]))

      :error ->
        Logger.warning("[PhoenixKitAI.Retention] #{name} holds an invalid period; kept forever")
        acc
    end
  end

  @doc false
  # Writes the periods document as it is; `put_settings/3` (rights,
  # merging, the stale check) is built on it. `opts` go to core's writer
  # (`actor_uuid:`, `source:`).
  @spec write_settings(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def write_settings(%{} = doc, opts \\ []) do
    Settings.update_json_setting_with_module(@setting_key, doc, "ai", opts)
  end

  @doc """
  Saves the periods a person changed: `{:ok, settings}` in the form of
  `settings/0`.

  `attrs` maps kinds — `:content` or `"content"`, and so on — to periods:
  `:forever` or `{n, unit}`, or their stored form (`"forever"`,
  `%{"n" => n, "unit" => "day"}`). Any other key is
  `{:error, {:unknown_kind, key}}`, a kind given twice (atom and string)
  `{:invalid_retention, kind}`. A kind left out, or given as `loaded` has
  it, is not changed. `loaded` is what `settings/0` gave the form when it
  was loaded (from the page's assigns, never from the form's parameters);
  its periods are read the same way as `attrs`. A kind `loaded` lacks, or
  holds in no form a period has, is unknown: given the period stored it
  is unchanged, given another it is `:stale_retention` — what the form saw
  cannot be checked. A kind stored with a period but no `changed_at`
  (`unconfirmed` in `settings/0`, read as `:forever`) counts as changed
  whenever it is given, so saving it confirms it — `:forever` included.

  In one transaction (lock timeout 5 s, statement timeout 10 s): the
  setting's row is locked and read again; only the changed kinds are
  merged, each with `changed_at` set here. A changed kind whose stored
  period is no longer what the form loaded is `{:error, :stale_retention}`,
  and so is a first write that meets another's (the setting's unique
  key). A row held elsewhere past the lock timeout is
  `{:error, :retention_busy}`. Core's writer comes last and records
  `setting.changed` with the actor (`source: "settings"`); it broadcasts
  the document before the transaction commits, so subscribers render from
  the message rather than reading the setting again. Core's writer
  refusing the write is `{:error, :settings_write_failed}`, logged with
  the failing fields only.

  `{:error, :forbidden}` without `may_set?/2` for a changed kind (or for
  every kind); `{:error, {:invalid_retention, kind}}` for a period of the
  wrong form, N out of range or an unknown unit. Nothing is written then,
  nor when nothing changed.
  """
  @spec put_settings(term(), map(), map()) ::
          {:ok, map()}
          | {:error,
             :forbidden
             | :stale_retention
             | :retention_busy
             | :settings_write_failed
             | {:invalid_retention, kind()}
             | {:unknown_kind, term()}}
  def put_settings(scope, attrs, loaded) when is_map(attrs) and is_map(loaded) do
    with :ok <- authorize(scope, [], &may_set?/2),
         {:ok, given} <- by_kind(attrs),
         {:ok, periods} <- attr_periods(given),
         seen = Map.new(@kinds, &{&1, loaded_period(loaded, &1)}),
         touched = Enum.filter(@kinds, &touched?(periods, seen, &1)),
         :ok <- authorize(scope, touched, &may_set?/2) do
      if periods == %{},
        do: {:ok, settings()},
        else: write_changes(scope, periods, seen)
    end
  end

  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})

  # `attrs` keyed by kind: atoms or their strings, nothing else, once each.
  defp by_kind(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case kind_of(key) do
        nil -> {:halt, {:error, {:unknown_kind, key}}}
        kind when is_map_key(acc, kind) -> {:halt, {:error, {:invalid_retention, kind}}}
        kind -> {:cont, {:ok, Map.put(acc, kind, value)}}
      end
    end)
  end

  defp kind_of(key) when key in @kinds, do: key
  defp kind_of(key) when is_binary(key), do: Map.get(@kind_names, key)
  defp kind_of(_key), do: nil

  defp attr_periods(given) do
    Enum.reduce_while(@kinds, {:ok, %{}}, fn kind, {:ok, acc} ->
      case given |> Map.fetch(kind) |> attr_period() do
        :absent -> {:cont, {:ok, acc}}
        {:ok, period} -> {:cont, {:ok, Map.put(acc, kind, period)}}
        :error -> {:halt, {:error, {:invalid_retention, kind}}}
      end
    end)
  end

  defp attr_period(:error), do: :absent
  defp attr_period({:ok, :forever}), do: {:ok, :forever}

  defp attr_period({:ok, {_n, _unit} = period}),
    do: if(valid_period?(period), do: {:ok, period}, else: :error)

  defp attr_period({:ok, value}), do: parse_period(value)

  # What the form loaded for `kind`: `{:ok, period}`, or `:unknown`.
  defp loaded_period(loaded, kind) do
    found =
      case Map.fetch(loaded, kind) do
        :error -> Map.fetch(loaded, Atom.to_string(kind))
        found -> found
      end

    case attr_period(found) do
      {:ok, period} -> {:ok, period}
      _absent_or_invalid -> :unknown
    end
  end

  # Given, and not as loaded: the rights are checked for these before the
  # transaction; what is written is decided in it, against the stored row.
  defp touched?(periods, seen, kind),
    do: Map.has_key?(periods, kind) and seen[kind] != {:ok, periods[kind]}

  @settings_statement_ms 10_000
  @settings_lock_ms 5_000

  defp write_changes(scope, periods, seen) do
    query_opts = [timeout: @settings_statement_ms + @client_margin_ms]

    repo().transaction(
      fn ->
        set_timeouts(@settings_statement_ms, @settings_lock_ms, query_opts)
        raw = locked_document(query_opts)
        stored = parse_settings(raw)

        changed =
          Enum.filter(@kinds, fn kind ->
            Map.has_key?(periods, kind) and changes?(seen[kind], stored, kind, periods[kind])
          end)

        if Enum.any?(changed, &stale?(seen[&1], stored[&1], periods[&1])),
          do: repo().rollback(:stale_retention)

        # A stored period read as forever until saved again, saved: decided
        # here, so checked here.
        with {:error, reason} <- authorize(scope, changed, &may_set?/2),
             do: repo().rollback(reason)

        # The last statement of the transaction: core's writer announces
        # the change before the commit.
        if changed == [],
          do: stored,
          else: write_merged(raw, periods, changed, Guard.actor_uuid(scope))
      end,
      query_opts
    )
  rescue
    error ->
      if timed_out?(error), do: {:error, :retention_busy}, else: reraise(error, __STACKTRACE__)
  end

  # A kind given is written when the stored period has no changed_at (read
  # as forever until saved again: saving it confirms it, forever
  # included), when it is not what the form loaded, or — the loaded value
  # unknown — when it is not what is stored.
  defp changes?(seen, stored, kind, given) do
    kind in stored.unconfirmed or
      case seen do
        {:ok, loaded} -> given != loaded
        :unknown -> given != stored[kind]
      end
  end

  # Loaded and stored differ; or unknown what was loaded, and the period
  # given is not the stored one.
  defp stale?({:ok, loaded}, stored, _given), do: stored != loaded
  defp stale?(:unknown, stored, given), do: stored != given

  defp write_merged(raw, periods, changed, actor_uuid) do
    doc = merge_changes(raw, periods, changed)

    case write_settings(doc, actor_uuid: actor_uuid, source: "settings") do
      {:ok, _setting} -> parse_settings(doc)
      {:error, changeset} -> repo().rollback(write_error(changeset))
    end
  end

  defp locked_document(query_opts) do
    query =
      from(s in Setting, where: s.key == ^@setting_key, lock: "FOR UPDATE", select: s.value_json)

    case repo().one(query, [log: false] ++ query_opts) do
      %{} = doc -> doc
      _ -> %{}
    end
  end

  # The stored document with the changed kinds replaced and stamped; a kind
  # missing from it is written out as its default, so a later change of the
  # default does not move it.
  defp merge_changes(raw, periods, changed) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    changed_at = if is_map(raw["changed_at"]), do: raw["changed_at"], else: %{}

    @kinds
    |> Enum.reduce(raw, fn kind, doc ->
      name = Atom.to_string(kind)

      cond do
        kind in changed -> Map.put(doc, name, period_to_json(periods[kind]))
        Map.has_key?(doc, name) -> doc
        true -> Map.put(doc, name, period_to_json(Map.fetch!(@defaults, kind)))
      end
    end)
    |> Map.put(
      "changed_at",
      Map.merge(changed_at, Map.new(changed, &{Atom.to_string(&1), stamp}))
    )
  end

  # Another first write got in between: the setting's unique key. Anything
  # else core refused is logged by its fields, never their values.
  defp write_error(%Ecto.Changeset{errors: errors} = changeset) do
    case Keyword.get(errors, :key) do
      {_message, details} when is_list(details) ->
        if details[:constraint] == :unique, do: :stale_retention, else: write_failed(changeset)

      _other ->
        write_failed(changeset)
    end
  end

  defp write_failed(changeset) do
    Logger.warning(
      "[PhoenixKitAI.Retention] the periods could not be saved: #{inspect(error_fields(changeset))}"
    )

    :settings_write_failed
  end

  # A changeset's failing fields with the constraint or validation named,
  # without messages (they can quote values).
  defp error_fields(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {field, {_message, details}} ->
      {field, Keyword.take(details, [:constraint, :constraint_name, :validation])}
    end)
  end

  # `scope` may act on each of `kinds`, and on at least one kind at all.
  defp authorize(scope, kinds, may?) do
    if Enum.any?(@kinds, &may?.(scope, &1)) and Enum.all?(kinds, &may?.(scope, &1)),
      do: :ok,
      else: {:error, :forbidden}
  end

  @doc """
  The outcome of the last runs: `%{scheduled: entry | nil, manual: entry |
  nil, content_done_before: DateTime.t() | nil}`. An entry is `%{at:,
  status: :ok | :failed | :skipped, error:, counts:, more_left:,
  actor_uuid:, content_batch:, failure_logged_at:}`; `counts` has the three
  kinds and `guard_reasons` (the off-purpose reasons cleared).
  `content_done_before` is the boundary below which content is already
  cleared; `content_resume` (`%{lower:, upper:}` or `nil`) an interval
  above it already cleared, which a stopped content step skips next time.
  `rows_deleted_before` is the earliest boundary below which a run, nightly
  or manual, deleted journal rows (`nil` while none has): written by every
  run that deleted some, never cleared, so a later run that deletes none
  does not hide that rows are gone.
  Read without the cache; a database error reads as no runs.
  """
  @spec last_run() :: %{
          scheduled: map() | nil,
          manual: map() | nil,
          content_done_before: DateTime.t() | nil,
          content_resume: %{lower: DateTime.t() | nil, upper: DateTime.t()} | nil,
          rows_deleted_before: DateTime.t() | nil
        }
  def last_run do
    @last_run_key |> Settings.get_json_setting() |> last_run_from()
  rescue
    _error -> no_runs()
  catch
    :exit, _reason -> no_runs()
  end

  @doc """
  `last_run/0` read from a stored document instead of the database: the
  value core broadcasts in `{:setting_changed, key, value}` for
  `last_run_key/0`. Anything but a map reads as no runs.
  """
  @spec last_run_from(term()) :: map()
  def last_run_from(%{} = doc) do
    %{
      scheduled: parse_entry(doc["scheduled"]),
      manual: parse_entry(doc["manual"]),
      content_done_before: parse_datetime(doc["content_done_before"]),
      content_resume: parse_resume(doc["content_resume"]),
      rows_deleted_before: parse_datetime(doc["rows_deleted_before"])
    }
  end

  def last_run_from(_doc), do: no_runs()

  @pending_states ~w(available scheduled executing retryable)

  @doc """
  The cleanup job not finished yet, if any: `%{state: "available" |
  "scheduled" | "executing" | "retryable", inserted_at:, attempted_at:}`
  of the newest such `PhoenixKitAI.JournalPruneWorker` job in Oban's
  table, else `nil`. A job stuck in `executing` (a host without Lifeline)
  shows here instead of only refusing the next run. `nil` too when Oban
  or the database cannot be read.
  """
  @spec pending_job() :: map() | nil
  def pending_job do
    worker = JournalPruneWorker |> Module.split() |> Enum.join(".")

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker and j.state in @pending_states,
        order_by: [desc: j.id],
        limit: 1,
        select: %{state: j.state, inserted_at: j.inserted_at, attempted_at: j.attempted_at}
      )

    repo().one(query, prefix: Oban.config(Oban).prefix, log: false)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc """
  When the oldest journal row was written, or `nil` with an empty journal
  (or a database error): where the totals "for all time" start once rows
  are deleted.
  """
  @spec oldest_request_at() :: DateTime.t() | nil
  def oldest_request_at do
    repo().one(from(r in Request, select: min(r.inserted_at)), log: false)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp no_runs,
    do: %{
      scheduled: nil,
      manual: nil,
      content_done_before: nil,
      content_resume: nil,
      rows_deleted_before: nil
    }

  defp parse_resume(%{"upper" => upper} = resume) do
    case parse_datetime(upper) do
      nil -> nil
      upper -> %{lower: parse_datetime(resume["lower"]), upper: upper}
    end
  end

  defp parse_resume(_resume), do: nil

  defp parse_entry(%{} = entry) do
    counts = if is_map(entry["counts"]), do: entry["counts"], else: %{}

    %{
      at: parse_datetime(entry["at"]),
      status: parse_status(entry["status"]),
      error: if(is_binary(entry["error"]), do: entry["error"]),
      counts: Map.new(@counters, &{&1, count_value(counts[Atom.to_string(&1)])}),
      more_left: entry["more_left"] == true,
      actor_uuid: if(is_binary(entry["actor_uuid"]), do: entry["actor_uuid"]),
      content_batch: if(is_integer(entry["content_batch"]), do: entry["content_batch"]),
      failure_logged_at: parse_datetime(entry["failure_logged_at"])
    }
  end

  defp parse_entry(_entry), do: nil

  defp parse_status("ok"), do: :ok
  defp parse_status("failed"), do: :failed
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_status), do: nil

  defp count_value(n) when is_integer(n) and n >= 0, do: n
  defp count_value(_n), do: 0

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  # ===========================================
  # BOUNDARIES
  # ===========================================

  @doc """
  The boundary of a period as chosen, before the floor: in the site time
  zone (an empty or unusable zone is UTC), N days is local midnight N days
  before today, N months the start of the local month N months before the
  current one, N years the same with 12·N months.

      # 25.10.2026 in Europe/Tallinn
      cutoff(:requests, {3, :month}, ~U[2026-10-25 12:00:00Z])
      #=> {:ok, ~U[2026-06-30 21:00:00Z]}

  `:forever` is `:keep`; a period `parse_period/1` would refuse (N out of
  range, an unknown unit) is `{:error, {:invalid_retention, kind}}`.
  `effective_cutoff/3` applies the floor.
  """
  @spec cutoff(kind(), period(), DateTime.t()) ::
          {:ok, DateTime.t()} | :keep | {:error, {:invalid_retention, kind()}}
  def cutoff(kind, period, now \\ DateTime.utc_now())

  def cutoff(kind, :forever, _now) when kind in @kinds, do: :keep

  def cutoff(kind, {n, unit} = period, %DateTime{} = now) when kind in @kinds do
    if valid_period?(period),
      do: {:ok, period_start(n, unit, now)},
      else: {:error, {:invalid_retention, kind}}
  end

  def cutoff(kind, _period, _now) when kind in @kinds, do: {:error, {:invalid_retention, kind}}

  defp valid_period?({n, unit}) when is_atom(unit) and is_map_key(@max_n, unit),
    do: match?({:ok, _}, parse_period(period_to_json({n, unit})))

  defp valid_period?(_period), do: false

  defp period_start(n, unit, now) do
    zone = zone()
    today = TimeZone.local_date(now, zone)

    date =
      case unit do
        :day -> Date.add(today, -n)
        :month -> today |> Date.beginning_of_month() |> Date.shift(month: -n)
        :year -> today |> Date.beginning_of_month() |> Date.shift(month: -12 * n)
      end

    TimeZone.date_start(date, zone)
  end

  @doc """
  The floor of `kind` at `now`: nothing newer is ever deleted or cleared.
  Journal rows and guard events: local midnight two days before the first
  of the current local month. Content: 24 hours before `now`.
  """
  @spec floor(kind(), DateTime.t()) :: DateTime.t()
  def floor(kind, now \\ DateTime.utc_now())

  def floor(:content, %DateTime{} = now), do: DateTime.add(now, -@content_floor_hours * 3600)

  def floor(kind, %DateTime{} = now) when kind in [:requests, :guard_events] do
    zone = zone()

    now
    |> TimeZone.local_date(zone)
    |> Date.beginning_of_month()
    |> Date.add(-@floor_days_before_month)
    |> TimeZone.date_start(zone)
  end

  @doc """
  The boundary a cleanup of `kind` uses: `cutoff`, or the floor when that
  is earlier. A boundary after `now` is `{:error, {:cutoff_in_future,
  kind}}`. Every entry to a cleanup applies it: the night, the preview, a
  manual run, the job.
  """
  @spec effective_cutoff(kind(), DateTime.t(), DateTime.t()) ::
          {:ok, DateTime.t()}
          | {:error, {:cutoff_in_future, kind()} | {:invalid_cutoff, kind()}}
  def effective_cutoff(kind, cutoff, now \\ DateTime.utc_now())

  def effective_cutoff(kind, %DateTime{} = cutoff, %DateTime{} = now) when kind in @kinds do
    if DateTime.compare(cutoff, now) == :gt,
      do: {:error, {:cutoff_in_future, kind}},
      else: {:ok, earlier(cutoff, floor(kind, now))}
  end

  # Not a moment: refused, never guessed.
  def effective_cutoff(kind, _cutoff, _now), do: {:error, {:invalid_cutoff, kind}}

  @doc """
  Whether `period` keeps `kind` for less than `saved` does: its boundary
  (`cutoff/3`, before the floor) at `now` is later than the saved one's.
  Equal boundaries, a first finite period and anything in doubt (a period
  `cutoff/3` refuses) count as shorter; `:forever` never is. Saving a
  shorter period goes through the preview.
  """
  @spec shorter?(kind(), term(), term(), DateTime.t()) :: boolean()
  def shorter?(kind, period, saved, now \\ DateTime.utc_now()) when kind in @kinds do
    case {cutoff(kind, period, now), cutoff(kind, saved, now)} do
      {:keep, _saved} -> false
      {{:ok, new}, {:ok, old}} -> DateTime.compare(new, old) != :lt
      _in_doubt -> true
    end
  end

  @doc """
  What the form warns of for `period` of `kind` at `now`, in this order
  (a list of atoms; the page words them):

    * `:previous_months_deleted` — journal rows kept less than 3 months;
    * `:short_windows` — any kind kept less than 30 days (the 30-day
      windows see less);
    * `:guard_history_deleted` — guard events kept less than 3 months;
    * `:content_outlives_row` — content kept longer than the rows
      (`requests_period`, `:forever` by default), or forever while the rows
      are not: it lives as long as its row.

  "Less than" compares the boundaries before the floor (`cutoff/3`). A
  period `cutoff/3` refuses has no warnings.
  """
  @spec warnings(kind(), term(), DateTime.t(), term()) :: [atom()]
  def warnings(kind, period, %DateTime{} = now, requests_period \\ :forever)
      when kind in @kinds do
    case cutoff(kind, period, now) do
      {:ok, cut} ->
        [
          previous_months_deleted: kind == :requests and later_than?(cut, kind, {3, :month}, now),
          short_windows: later_than?(cut, kind, {30, :day}, now),
          guard_history_deleted:
            kind == :guard_events and later_than?(cut, kind, {3, :month}, now),
          content_outlives_row: kind == :content and outlives_rows?(cut, requests_period, now)
        ]
        |> Enum.filter(fn {_warning, on?} -> on? end)
        |> Enum.map(fn {warning, _on?} -> warning end)

      :keep ->
        if kind == :content and match?({:ok, _}, cutoff(:requests, requests_period, now)),
          do: [:content_outlives_row],
          else: []

      {:error, _reason} ->
        []
    end
  end

  defp later_than?(cut, kind, reference, now) do
    {:ok, reference_cut} = cutoff(kind, reference, now)
    DateTime.compare(cut, reference_cut) == :gt
  end

  defp outlives_rows?(content_cut, requests_period, now) do
    case cutoff(:requests, requests_period, now) do
      {:ok, requests_cut} -> DateTime.compare(content_cut, requests_cut) == :lt
      _keep_or_invalid -> false
    end
  end

  # The moment a cleanup takes its floor at: the one given if it is not
  # later than now, else now — a later one would move the floor forward.
  defp clamp_now(%DateTime{} = given), do: earlier(given, DateTime.utc_now())
  defp clamp_now(_given), do: DateTime.utc_now()

  # The effective boundaries of `cutoffs`, and the kinds clamped to the floor.
  defp effective_cutoffs(cutoffs, now) do
    Enum.reduce_while(@kinds, {:ok, %{}, []}, fn kind, {:ok, acc, clamped} ->
      case effective_or_nil(kind, cutoffs[kind], now) do
        {:ok, nil} -> {:cont, {:ok, Map.put(acc, kind, nil), clamped}}
        {:ok, cut, false} -> {:cont, {:ok, Map.put(acc, kind, cut), clamped}}
        {:ok, cut, true} -> {:cont, {:ok, Map.put(acc, kind, cut), clamped ++ [kind]}}
        error -> {:halt, error}
      end
    end)
  end

  defp effective_or_nil(_kind, nil, _now), do: {:ok, nil}

  defp effective_or_nil(kind, cut, now) do
    with {:ok, effective} <- effective_cutoff(kind, cut, now) do
      {:ok, effective, DateTime.compare(effective, cut) == :lt}
    end
  end

  defp zone, do: Settings.get_setting("time_zone", "0")

  # ===========================================
  # FOREIGN KEYS
  # ===========================================

  @doc """
  Checks the foreign keys pointing at the tables `kinds` delete from
  (`:requests` → the journal, `:guard_events` → the events). Each must be
  `ON DELETE SET NULL`, on one nullable column, with a valid index leading
  with that column (no predicate, or `col IS NOT NULL`). Anything else —
  `RESTRICT` / `NO ACTION` would fail every chunk, `CASCADE` would delete
  another module's rows, `SET NULL` on a `NOT NULL` column would fail, no
  index means a scan of the other table per deleted row — is
  `{:error, {:foreign_key_blocks, table}}`, naming the referencing table.
  """
  @spec check_foreign_keys([kind()]) :: :ok | {:error, {:foreign_key_blocks, String.t()}}
  def check_foreign_keys(kinds \\ [:requests, :guard_events]) do
    referenced =
      Enum.flat_map(kinds, fn
        :requests -> [table(Request)]
        :guard_events -> [table(GuardEvent)]
        :content -> []
      end)

    in_transaction(
      @default_opts[:statement_timeout_ms],
      @default_opts[:lock_timeout_ms],
      &first_blocking(referenced, &1)
    )
  end

  defp first_blocking(referenced, query_opts) do
    Enum.find_value(referenced, :ok, fn table ->
      case blocking_reference(table, query_opts) do
        nil -> nil
        blocking -> {:error, {:foreign_key_blocks, blocking}}
      end
    end)
  end

  @fk_sql """
  SELECT c.conrelid::regclass::text,
         c.confdeltype = 'n'
           AND array_length(c.conkey, 1) = 1
           AND NOT a.attnotnull
           AND EXISTS (
             SELECT 1 FROM pg_index i
             WHERE i.indrelid = c.conrelid
               AND i.indisvalid AND i.indisready
               AND i.indkey[0] = c.conkey[1]
               AND (i.indpred IS NULL
                    OR pg_get_expr(i.indpred, i.indrelid) = format('(%s IS NOT NULL)', quote_ident(a.attname)))
           )
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
  WHERE c.contype = 'f' AND c.confrelid = to_regclass($1)
  ORDER BY 1
  """

  defp blocking_reference(referenced, query_opts) do
    %{rows: rows} = repo().query!(@fk_sql, [referenced], query_opts)
    Enum.find_value(rows, fn [table, fine?] -> if fine?, do: nil, else: table end)
  end

  defp deleting_kinds(cutoffs), do: Enum.filter([:requests, :guard_events], &cutoffs[&1])

  # ===========================================
  # PREVIEW
  # ===========================================

  @doc """
  What a run with `cutoffs` would do now: `{:ok, %{content:, requests:,
  guard_events:, clamped:, cutoffs:}}`.

  Each boundary goes through `effective_cutoff/3` first; `clamped` names
  the kinds held at the floor and `cutoffs` holds the boundaries used.
  `requests` and `guard_events` are the rows and events older than their
  boundaries (an active block's event left out); `content` is "up to": the
  rows in the range the content step would walk that stay (from the
  requests boundary or the point already cleared, to the content
  boundary), counted by the time index without reading the metadata. A
  kind without a boundary counts 0. The foreign keys are checked first; a
  count over 60 s (`preview_timeout_ms:` of `config :phoenix_kit_ai,
  :journal_prune`) is `{:error, :preview_timeout}`. No rights are checked:
  `preview/2` is the same for a person.
  """
  @spec preview(cutoffs()) ::
          {:ok, map()}
          | {:error,
             {:foreign_key_blocks, String.t()} | {:cutoff_in_future, kind()} | :preview_timeout}
  def preview(cutoffs) when is_map(cutoffs),
    do: preview_counts(cutoffs, timeout_ms: preview_timeout_ms())

  @doc """
  `preview/1` for a person: `{:error, :forbidden}` unless `scope` may run
  each kind given a boundary (`may_run?/2`), and some kind at all.
  """
  @spec preview(term(), cutoffs()) ::
          {:ok, map()}
          | {:error,
             :forbidden
             | {:foreign_key_blocks, String.t()}
             | {:cutoff_in_future, kind()}
             | {:invalid_cutoff, kind()}
             | :preview_timeout}
  def preview(scope, cutoffs) when is_map(cutoffs) do
    with :ok <- authorize(scope, requested_kinds(cutoffs), &may_run?/2),
         do: preview_counts(cutoffs, timeout_ms: preview_timeout_ms())
  end

  # The counts' statement timeout: `preview_timeout_ms:` of
  # `config :phoenix_kit_ai, :journal_prune` when it is a positive integer,
  # else 60 s.
  defp preview_timeout_ms do
    with opts when is_list(opts) <- Application.get_env(:phoenix_kit_ai, :journal_prune, []),
         true <- Keyword.keyword?(opts),
         ms when is_integer(ms) and ms > 0 <- opts[:preview_timeout_ms] do
      ms
    else
      _ -> @preview_timeout_ms
    end
  end

  defp requested_kinds(cutoffs), do: Enum.filter(@kinds, &(cutoffs[&1] != nil))

  @doc """
  Queues a manual cleanup with `cutoffs` (`nil` or a missing kind: not
  touched) for `scope`'s person: `{:ok, job}`.

  Refused, nothing queued: `{:error, :module_disabled}` with the module
  off (checked first: the rights of a holder of `ai.manage` lapse with
  it); `:forbidden` unless `scope` may run each kind given a boundary
  (`may_run?/2`); `:nothing_to_run` without any; `{:cutoff_in_future,
  kind}` / `{:invalid_cutoff, kind}` from `effective_cutoff/3`;
  `{:foreign_key_blocks, table}` from `check_foreign_keys/1`, and
  `{:prune_failed, class}` when the database fails that check;
  `:prune_running` while a cleanup, nightly or manual, is queued or
  running; `:enqueue_failed` when the job cannot be inserted (logged by
  class). The boundaries are queued held at the
  floor, and the job holds them at the floor again when it runs.
  """
  @spec run_now(term(), cutoffs()) ::
          {:ok, Oban.Job.t()}
          | {:error,
             :forbidden
             | :module_disabled
             | :nothing_to_run
             | :prune_running
             | :enqueue_failed
             | {:cutoff_in_future, kind()}
             | {:invalid_cutoff, kind()}
             | {:foreign_key_blocks, String.t()}
             | {:prune_failed, String.t()}}
  def run_now(scope, cutoffs) when is_map(cutoffs) do
    requested = requested_kinds(cutoffs)

    with :ok <- module_enabled(),
         :ok <- authorize(scope, requested, &may_run?/2),
         :ok <- if(requested == [], do: {:error, :nothing_to_run}, else: :ok),
         {:ok, effective, _clamped} <- effective_cutoffs(cutoffs, DateTime.utc_now()),
         :ok <- foreign_keys_for_run(deleting_kinds(effective)) do
      enqueue(JournalPruneWorker.manual_job(effective, Guard.actor_uuid(scope)))
    end
  end

  defp module_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :module_disabled})

  # As in `run/3`: a database error during the check is the run failing,
  # by its class.
  defp foreign_keys_for_run(kinds) do
    check_foreign_keys(kinds)
  rescue
    error -> {:error, {:prune_failed, error_class(error)}}
  catch
    :exit, _reason -> {:error, {:prune_failed, "exit"}}
  end

  defp enqueue(changeset) do
    case Oban.insert(changeset) do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :prune_running}
      {:ok, job} -> {:ok, job}
      {:error, reason} -> enqueue_failed(reason)
    end
  rescue
    error -> enqueue_failed(error)
  catch
    :exit, _reason -> enqueue_failed(:exit)
  end

  defp enqueue_failed(reason) do
    detail =
      case reason do
        %Ecto.Changeset{} = changeset -> inspect(error_fields(changeset))
        %{__struct__: module} -> inspect(module)
        other when is_atom(other) -> inspect(other)
        _other -> "error"
      end

    Logger.warning("[PhoenixKitAI.Retention] the cleanup could not be queued: #{detail}")
    {:error, :enqueue_failed}
  end

  @doc false
  # `preview/1` with `now:` and `timeout_ms:` (the statement timeout of the
  # counts, 60 s by default).
  @spec preview_counts(cutoffs(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_counts(cutoffs, opts) when is_map(cutoffs) do
    now = clamp_now(Keyword.get(opts, :now))
    timeout = Keyword.get(opts, :timeout_ms, @preview_timeout_ms)

    with {:ok, effective, clamped} <- effective_cutoffs(cutoffs, now),
         :ok <- check_foreign_keys(deleting_kinds(effective)) do
      done_before = last_run().content_done_before

      counts =
        in_transaction(timeout, timeout, fn qo ->
          %{
            requests: count_requests(effective.requests, qo),
            content: count_content(effective.content, effective.requests, done_before, qo),
            guard_events: count_events(effective.guard_events, qo)
          }
        end)

      {:ok, Map.merge(counts, %{clamped: clamped, cutoffs: effective})}
    end
  rescue
    error ->
      if timed_out?(error), do: {:error, :preview_timeout}, else: reraise(error, __STACKTRACE__)
  end

  defp timed_out?(%Postgrex.Error{} = error),
    do: pg_code(error) in [:query_canceled, :lock_not_available]

  defp timed_out?(%DBConnection.ConnectionError{}), do: true
  defp timed_out?(_error), do: false

  defp count_requests(nil, _qo), do: 0

  defp count_requests(cut, qo) do
    scalar("SELECT count(*) FROM #{table(Request)} WHERE inserted_at < $1", [cut], qo)
  end

  defp count_content(nil, _requests_cut, _done_before, _qo), do: 0

  defp count_content(cut, requests_cut, done_before, qo) do
    case later(requests_cut, done_before) do
      nil ->
        scalar("SELECT count(*) FROM #{table(Request)} WHERE inserted_at < $1", [cut], qo)

      lower ->
        scalar(
          "SELECT count(*) FROM #{table(Request)} WHERE inserted_at >= $1 AND inserted_at < $2",
          [lower, cut],
          qo
        )
    end
  end

  defp count_events(nil, _qo), do: 0

  defp count_events(cut, qo) do
    scalar(
      "SELECT count(*) FROM #{table(GuardEvent)} e WHERE e.inserted_at < $1 AND #{not_active_origin("e")}",
      [naive(cut)],
      qo
    )
  end

  defp scalar(sql, params, qo) do
    %{rows: [[n]]} = repo().query!(sql, params, qo)
    n
  end

  # ===========================================
  # RUN
  # ===========================================

  @doc """
  One cleanup with `cutoffs` (`nil` or a missing kind: not touched), as
  `mode` — what `PhoenixKitAI.JournalPruneWorker` calls.

  Each boundary goes through `effective_cutoff/3` (held at the floor; one
  after now is `{:cancel, {:cutoff_in_future, kind}}`), then the foreign
  keys are checked (`{:cancel, {:foreign_key_blocks, table}}`); a refusal
  deletes nothing. Then the journal rows, the content and the guard events
  are handled in chunks, each its own short transaction. The outcome is
  written to `last_run_key/0` and to the Activity feed (`journal.pruned` /
  `journal.prune_failed`, permanent); a failure — a chunk, or the database
  during the checks — stops the run with `{:error, {:prune_failed, class}}`,
  the counts done so far recorded.

  Options: `actor_uuid:` (a manual run's person), `now:` (the moment the
  floor is taken at), and the run's own — the chunk sizes `request_batch:`
  / `content_batch:` / `content_min_batch:` / `event_batch:`, `pause_ms:`,
  `max_rows:` (per counter), `time_limits:` (`%{requests:, content:,
  guard_reasons:, guard_events:}` in ms), `statement_timeout_ms:`,
  `lock_timeout_ms:`. A value that is not a fitting integer, or time slices
  that would not fit in the job's timeout, are replaced by the defaults
  with a warning; a statement timeout too long for even the default slices
  is lowered, with a warning, to the largest that fits.
  """
  @spec run(mode(), cutoffs(), keyword()) ::
          {:ok, map()} | {:cancel, term()} | {:error, {:prune_failed, String.t()}}
  def run(mode, cutoffs, opts \\ []) when mode in [:scheduled, :manual] and is_map(cutoffs) do
    opts = keyword_or_empty(opts)
    now = clamp_now(Keyword.get(opts, :now))
    raw = Map.new(@kinds, &{&1, cutoffs[&1]})
    prune_opts = run_options(opts)

    case checks(raw, now) do
      {:ok, effective} ->
        %{content_done_before: done_before, content_resume: resume} = last_run()

        case prune(effective, {done_before, resume}, prune_opts) do
          {:ok, state} ->
            finish(mode, effective, state, nil, opts)
            {:ok, Map.take(state, [:counts, :more_left, :content_done_before])}

          {:error, class, state} ->
            finish(mode, effective, state, class, opts)
            {:error, {:prune_failed, class}}
        end

      {:refused, {tag, _detail} = reason} ->
        state = initial_state(nil, prune_opts)
        finish(mode, raw, state, Atom.to_string(tag), [{:refusal, true} | opts])
        {:cancel, reason}

      {:failed, class} ->
        finish(mode, raw, initial_state(nil, prune_opts), class, opts)
        {:error, {:prune_failed, class}}
    end
  end

  defp checks(cutoffs, now) do
    with {:ok, effective, _clamped} <- effective_cutoffs(cutoffs, now),
         :ok <- check_foreign_keys(deleting_kinds(effective)) do
      {:ok, effective}
    else
      {:error, reason} -> {:refused, reason}
    end
  rescue
    error -> {:failed, error_class(error)}
  catch
    :exit, _reason -> {:failed, "exit"}
  end

  @doc false
  # Writes a skipped run (the module is off) into the last-run stamp.
  @spec record_skipped(mode(), keyword()) :: :ok
  def record_skipped(mode, opts \\ []) do
    record(mode, entry("skipped", nil, initial_state(nil, []), opts, nil), nil)
  end

  @doc false
  # Writes a run refused before any check (a job's unreadable arguments)
  # into the last-run stamp, as failed with `class`.
  @spec record_refused(mode(), String.t(), keyword()) :: :ok
  def record_refused(mode, class, opts \\ []) when is_binary(class) do
    record(mode, entry("failed", class, initial_state(nil, []), opts, nil), nil)
  end

  defp finish(mode, cutoffs, state, nil = _error, opts) do
    record(mode, entry("ok", nil, state, opts, nil), state, deleted_before(cutoffs, state))

    if mode == :manual or Enum.any?(state.counts, fn {_counter, n} -> n > 0 end),
      do: log_activity("journal.pruned", mode, cutoffs, state, %{}, opts)

    :ok
  end

  defp finish(mode, cutoffs, state, error, opts) do
    log? = log_failure?(mode, error, opts)
    logged_at = if log?, do: DateTime.utc_now(), else: previous_logged_at(mode, error)

    record(
      mode,
      entry("failed", error, state, opts, logged_at),
      state,
      deleted_before(cutoffs, state)
    )

    if log?,
      do: log_activity("journal.prune_failed", mode, cutoffs, state, %{"error" => error}, opts)

    :ok
  end

  # A nightly refusal (the same check failing night after night) is logged
  # once a night per class; the stamp records every one.
  defp log_failure?(:scheduled, class, opts) do
    with true <- Keyword.get(opts, :refusal, false),
         %{failure_logged_at: %DateTime{} = at, error: ^class} <- last_run().scheduled do
      DateTime.diff(DateTime.utc_now(), at, :second) >= @failure_log_hours * 3600
    else
      _ -> true
    end
  end

  defp log_failure?(:manual, _class, _opts), do: true

  defp previous_logged_at(mode, class) when is_binary(class) do
    case Map.get(last_run(), mode) do
      %{error: ^class, failure_logged_at: at} -> at
      _ -> nil
    end
  end

  defp previous_logged_at(_mode, _class), do: nil

  defp entry(status, error, state, opts, logged_at) do
    %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "status" => status,
      "error" => error,
      "counts" => Map.new(state.counts, fn {counter, n} -> {Atom.to_string(counter), n} end),
      "more_left" => state.more_left,
      "content_batch" => state.content_batch,
      "failure_logged_at" => logged_at && iso(DateTime.truncate(logged_at, :second))
    }
    |> put_actor(opts[:actor_uuid])
  end

  # The journal boundary of a run that deleted rows (a failed one too: its
  # chunks are committed one by one), else nil.
  defp deleted_before(%{requests: %DateTime{} = cut}, %{counts: %{requests: n}}) when n > 0,
    do: cut

  defp deleted_before(_cutoffs, _state), do: nil

  defp put_actor(entry, actor) when is_binary(actor), do: Map.put(entry, "actor_uuid", actor)
  defp put_actor(entry, _actor), do: entry

  # The stamp is a machine's own (`history: false`: no settings history,
  # no actor or source in core's options); the actor is inside the JSON.
  # From a run's state: `content_done_before` only moves forward (`nil`
  # keeps the stored one); `content_resume` is replaced when the content
  # step ran (`:keep` otherwise). Without a state both stay.
  # `rows_deleted_before` only moves back, and only when rows were deleted.
  defp record(mode, entry, state, deleted_before \\ nil) do
    {done_before, resume} =
      case state do
        %{content_done_before: done_before, content_resume: resume} -> {done_before, resume}
        nil -> {nil, :keep}
      end

    doc =
      case Settings.get_json_setting(@last_run_key) do
        %{} = doc -> doc
        _ -> %{}
      end

    doc =
      doc
      |> Map.put(Atom.to_string(mode), entry)
      |> Map.put("content_done_before", iso(done_before) || doc["content_done_before"])
      |> put_resume(resume)
      |> put_deleted_before(deleted_before)

    case Settings.update_json_setting_with_module(@last_run_key, doc, "ai", history: false) do
      {:ok, _setting} ->
        :ok

      {:error, _changeset} ->
        Logger.warning("[PhoenixKitAI.Retention] the last-run stamp could not be written")
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI.Retention] the last-run stamp could not be written: #{inspect(error.__struct__)}"
      )

      :ok
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI.Retention] the last-run stamp could not be written (exit)")
      :ok
  end

  defp put_deleted_before(doc, nil), do: doc

  defp put_deleted_before(doc, %DateTime{} = cut) do
    case parse_datetime(doc["rows_deleted_before"]) do
      nil -> Map.put(doc, "rows_deleted_before", iso(cut))
      stored -> Map.put(doc, "rows_deleted_before", iso(earlier(stored, cut)))
    end
  end

  defp put_resume(doc, :keep), do: doc
  defp put_resume(doc, nil), do: Map.delete(doc, "content_resume")

  defp put_resume(doc, %{lower: lower, upper: upper}),
    do: Map.put(doc, "content_resume", %{"lower" => iso(lower), "upper" => iso(upper)})

  defp log_activity(action, mode, cutoffs, state, extra, opts) do
    metadata =
      Map.merge(
        %{
          "content_cleared" => state.counts.content,
          "requests_deleted" => state.counts.requests,
          "guard_events_deleted" => state.counts.guard_events,
          "guard_reasons_cleared" => state.counts.guard_reasons,
          "content_before" => iso(cutoffs.content),
          "requests_before" => iso(cutoffs.requests),
          "guard_events_before" => iso(cutoffs.guard_events),
          "more_left" => state.more_left
        },
        extra
      )

    PhoenixKit.Activity.log("ai", action,
      mode: if(mode == :manual, do: "manual", else: "cron"),
      actor_uuid: opts[:actor_uuid],
      metadata: metadata,
      permanent: true
    )
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_other), do: nil

  # ===========================================
  # OPTIONS
  # ===========================================

  @positive_opts [
    :request_batch,
    :content_batch,
    :content_min_batch,
    :event_batch,
    :max_rows,
    :statement_timeout_ms,
    :lock_timeout_ms
  ]

  @doc false
  # The run's options: each one that is not a fitting integer falls back to
  # its default, and time slices (with a chunk's and a probe's overrun
  # each) that would not fit in the job's timeout fall back as a whole; if
  # even the default slices do not fit, the statement timeout is lowered to
  # the largest that does. Either way `run_budget_ms/1` of the result stays
  # under the job's timeout. The last of a repeated option wins.
  @spec run_options(keyword()) :: keyword()
  def run_options(opts) do
    opts = Keyword.new(opts)

    base =
      Enum.map(@positive_opts, fn key ->
        {key, checked(opts, key, &(is_integer(&1) and &1 > 0))}
      end)

    base = [{:pause_ms, checked(opts, :pause_ms, &(is_integer(&1) and &1 >= 0))} | base]
    base = Keyword.update!(base, :content_min_batch, &min(&1, base[:content_batch]))

    base
    |> Keyword.put(:time_limits, time_limits(opts[:time_limits], base[:statement_timeout_ms]))
    |> fit_statement_timeout()
  end

  @doc false
  # The longest a run with `opts` may take: every counter's time slice,
  # plus per counter one chunk and one probe past it (each a statement
  # with the client's margin), plus the room for the checks and the stamp.
  @spec run_budget_ms(keyword()) :: non_neg_integer()
  def run_budget_ms(opts),
    do: budget_ms(opts[:time_limits], opts[:statement_timeout_ms])

  defp budget_ms(limits, statement_ms) do
    Enum.sum(Map.values(limits)) +
      length(@counters) * 2 * (statement_ms + @client_margin_ms) + @run_margin_ms
  end

  # The default slices with a statement timeout too long for them: the
  # largest statement timeout that fits instead.
  defp fit_statement_timeout(opts) do
    if run_budget_ms(opts) < @job_timeout_ms do
      opts
    else
      room = @job_timeout_ms - Enum.sum(Map.values(opts[:time_limits])) - @run_margin_ms
      statement_ms = div(room - 1, length(@counters) * 2) - @client_margin_ms

      Logger.warning(
        "[PhoenixKitAI.Retention] option statement_timeout_ms does not fit in the job's timeout with the time limits; #{statement_ms} is used"
      )

      Keyword.put(opts, :statement_timeout_ms, statement_ms)
    end
  end

  # Options that are not a keyword list are none, with a warning.
  defp keyword_or_empty(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      opts
    else
      Logger.warning("[PhoenixKitAI.Retention] the options are not a keyword list; ignored")
      []
    end
  end

  defp checked(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      :error ->
        @default_opts[key]

      {:ok, value} ->
        if valid?.(value), do: value, else: invalid_option(key)
    end
  end

  defp invalid_option(key) do
    warn_invalid(key)
    @default_opts[key]
  end

  defp invalid_limit(default) do
    warn_invalid(:time_limits)
    default
  end

  defp warn_invalid(key),
    do: Logger.warning("[PhoenixKitAI.Retention] option #{key} is invalid; the default is used")

  defp time_limits(nil, statement_ms), do: fit_limits(@default_opts[:time_limits], statement_ms)

  defp time_limits(given, statement_ms) when is_map(given) do
    limits =
      Map.new(@default_opts[:time_limits], fn {counter, default} ->
        case Map.get(given, counter) do
          nil -> {counter, default}
          ms when is_integer(ms) and ms >= 0 -> {counter, ms}
          _ -> {counter, invalid_limit(default)}
        end
      end)

    fit_limits(limits, statement_ms)
  end

  defp time_limits(_given, statement_ms) do
    invalid_option(:time_limits)
    fit_limits(@default_opts[:time_limits], statement_ms)
  end

  # Already the defaults: nothing to fall back to (`fit_statement_timeout/1`
  # lowers the statement timeout instead).
  defp fit_limits(limits, statement_ms) do
    if limits == @default_opts[:time_limits] or budget_ms(limits, statement_ms) < @job_timeout_ms do
      limits
    else
      Logger.warning(
        "[PhoenixKitAI.Retention] the time limits do not fit in the job's timeout; the defaults are used"
      )

      @default_opts[:time_limits]
    end
  end

  # ===========================================
  # PASSES
  # ===========================================

  # The three passes, without the checks `run/3` makes first. Returns
  # `{:ok, state}` or `{:error, class, state}`, the state holding what was
  # done (`counts`, `more_left`, `content_done_before`, `content_batch`).
  defp prune(cutoffs, {done_before, resume}, opts) do
    state = %{initial_state(done_before, opts) | content_resume: resume}

    with {:ok, state, requests} <- prune_requests(state, cutoffs.requests, opts),
         {:ok, state} <- prune_content(state, cutoffs.content, cutoffs.requests, requests, opts) do
      prune_events(state, cutoffs.guard_events, opts)
    end
  end

  defp initial_state(done_before, opts) do
    %{
      counts: Map.new(@counters, &{&1, 0}),
      more_left: false,
      content_done_before: done_before,
      content_resume: :keep,
      content_batch: Keyword.get(opts, :content_batch, @default_opts[:content_batch])
    }
  end

  # --- journal rows ---

  # The third element says how the step ended: `:not_run`, `:complete`
  # (by the probe, no row older than the boundary is left) or `:tail`.
  defp prune_requests(state, nil, _opts), do: {:ok, state, :not_run}

  defp prune_requests(state, cut, opts) do
    chunk = fn cursor, limit, st ->
      with {:ok, rows} <-
             execute(delete_requests_sql(cursor), keyset_params([cut, limit], cursor), opts) do
        {:ok, length(rows), length(rows), last_key(rows, cursor), st}
      end
    end

    case chunks(:requests, state, opts, nil, chunk, deadline(opts, :requests)) do
      {:error, class, state} ->
        {:error, class, state}

      {_ended, state, _cursor} ->
        probe = "SELECT 1 FROM #{table(Request)} WHERE inserted_at < $1 LIMIT 1"

        case exists?(probe, [cut], opts) do
          {:ok, false} -> {:ok, state, :complete}
          {:ok, true} -> {:ok, %{state | more_left: true}, :tail}
          {:error, class} -> {:error, class, state}
        end
    end
  end

  defp delete_requests_sql(cursor) do
    t = table(Request)

    # The chunk is materialized once: as `uuid IN (subquery)` the planner
    # may run a `LIMIT … SKIP LOCKED` subquery again and delete more rows
    # than the limit.
    """
    WITH chunk AS MATERIALIZED (
      SELECT uuid FROM #{t}
      WHERE inserted_at < $1#{keyset_clause(cursor, 3)}
      ORDER BY inserted_at, uuid
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM #{t} r USING chunk WHERE r.uuid = chunk.uuid
    RETURNING r.inserted_at, r.uuid
    """
  end

  defp keyset_params(params, nil), do: params
  defp keyset_params(params, {at, uuid}), do: params ++ [at, uuid]

  defp keyset_clause(nil, _n), do: ""
  defp keyset_clause(_cursor, n), do: " AND (inserted_at, uuid) > ($#{n}, $#{n + 1})"

  defp last_key([], cursor), do: cursor

  defp last_key(rows, _cursor) do
    [at, uuid] =
      Enum.max_by(rows, fn [at, uuid] -> {DateTime.to_unix(at, :microsecond), uuid} end)

    {at, uuid}
  end

  # --- content ---

  defp prune_content(state, nil, _requests_cut, _requests, _opts), do: {:ok, state}

  defp prune_content(state, cut, requests_cut, requests, opts) do
    deadline = deadline(opts, :content)
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ranges =
      content_ranges(cut, requests_cut, requests, state.content_done_before)
      |> Enum.map(&skip_cleared(&1, state.content_resume))
      |> Enum.reject(fn %{lower: lower, upper: upper} ->
        lower && DateTime.compare(lower, upper) != :lt
      end)

    outcome =
      Enum.reduce_while(ranges, {:done, state}, fn range, {:done, st} ->
        case content_range(range, stamp, st, opts, deadline) do
          {:done, st} -> {:cont, {:done, st}}
          other -> {:halt, other}
        end
      end)

    with {done, state} when done in [:done, :stopped] <- outcome,
         {:ok, state} <- clear_reasons(state, cut, opts) do
      # Every range done: everything below the boundary is cleared.
      if done == :stopped,
        do: {:ok, %{state | more_left: true}},
        else:
          {:ok,
           %{
             state
             | content_done_before: later(state.content_done_before, cut),
               content_resume: nil
           }}
    end
  end

  # The ranges the content step walks, in order. With the journal step
  # complete, rows below its boundary are gone; with a tail left, the rows
  # that stay come first, then the tail; without a journal step, all from
  # the point already cleared. `below_clear` says that nothing below the
  # range's lower bound has content left, so a stop inside it may move the
  # point already cleared up to where it stopped; the first range of a tail
  # has the tail below it, so its progress is kept as `content_resume`.
  defp content_ranges(cut, _requests_cut, :not_run, done_before),
    do: [range(done_before, cut, true)]

  defp content_ranges(cut, requests_cut, :complete, done_before),
    do: [range(later(requests_cut, done_before), cut, true)]

  defp content_ranges(cut, requests_cut, :tail, done_before) do
    [
      range(later(requests_cut, done_before), cut, false),
      range(done_before, earlier(requests_cut, cut), true)
    ]
  end

  defp range(lower, upper, below_clear?),
    do: %{lower: lower, upper: upper, clear_from: lower, below_clear: below_clear?}

  # A range starting inside an interval already cleared starts at its end;
  # `clear_from` keeps where the cleared stretch began.
  defp skip_cleared(%{lower: lower} = range, %{lower: from, upper: to}) do
    if starts_within?(lower, from, to),
      do: %{range | lower: earlier(to, range.upper), clear_from: from},
      else: range
  end

  defp skip_cleared(range, _resume), do: range

  defp starts_within?(lower, from, to) do
    (from == nil or (lower != nil and DateTime.compare(from, lower) != :gt)) and
      (lower == nil or DateTime.compare(lower, to) == :lt)
  end

  # One range, to its end or until stopped. Stopped with no row with
  # content after the cursor is done; otherwise what the range cleared is
  # kept for the next run (`stopped_at/3`).
  defp content_range(%{lower: lower, upper: upper} = range, stamp, state, opts, deadline) do
    chunk = &content_chunk(lower, upper, stamp, &1, &2, &3, opts)

    case chunks(:content, state, opts, nil, chunk, deadline) do
      {:done, state, _cursor} ->
        {:done, range_done(range, state)}

      {:stopped, state, cursor} ->
        case content_left?(lower, upper, cursor, opts) do
          {:ok, false} -> {:done, range_done(range, state)}
          {:ok, true} -> {:stopped, stopped_at(range, cursor, state)}
          {:error, class} -> {:error, class, state}
        end

      error ->
        error
    end
  end

  # A range above uncleared rows, done: the whole of it is kept as cleared.
  defp range_done(%{below_clear: true}, state), do: state

  defp range_done(%{clear_from: from, upper: upper}, state),
    do: %{state | content_resume: %{lower: from, upper: upper}}

  # Where a stopped range got to: below the cursor's time everything is
  # cleared (rows at that very time with a later uuid may not be, so the
  # point is that time, and the next walk starts at it again).
  defp stopped_at(_range, nil, state), do: state

  defp stopped_at(%{below_clear: true}, {at, _uuid}, state),
    do: %{state | content_done_before: later(state.content_done_before, at)}

  defp stopped_at(%{clear_from: from}, {at, _uuid}, state),
    do: %{state | content_resume: %{lower: from, upper: at}}

  # Is there a row with content left in the range after the cursor? A probe
  # that runs out of time answers yes.
  defp content_left?(lower, upper, cursor, opts) do
    {sql, params} = content_left_sql(lower, upper, cursor)

    case exists?(sql, params, opts) do
      {:error, "query_canceled"} -> {:ok, true}
      other -> other
    end
  end

  # A chunk is a window of the next `limit` rows of the range by
  # `(inserted_at, uuid)`; of those, the ones with content are cleared (the
  # update waits for a row another transaction holds), and the cursor moves
  # to the last row looked at.
  defp content_chunk(lower, upper, stamp, cursor, limit, state, opts) do
    {sql, params} = content_sql(lower, upper, stamp, limit, cursor)

    case execute(sql, params, opts) do
      {:ok, [[_cleared, 0, nil, nil]]} ->
        {:ok, 0, 0, cursor, state}

      {:ok, [[cleared, looked_at, at, uuid]]} ->
        {:ok, cleared, looked_at, {at, uuid}, state}

      {:error, "query_canceled"} = error ->
        min = opts[:content_min_batch]

        if state.content_batch > min,
          do: {:retry, %{state | content_batch: max(div(state.content_batch, 2), min)}},
          else: error

      error ->
        error
    end
  end

  defp content_sql(lower, upper, stamp, limit, cursor) do
    t = table(Request)
    lower_clause = if lower, do: " AND inserted_at >= $5", else: ""
    keyset = keyset_clause(cursor, if(lower, do: 6, else: 5))
    params = [upper, @content_keys, stamp, limit] ++ List.wrap(lower)

    sql = """
    WITH scan AS MATERIALIZED (
      SELECT uuid, inserted_at FROM #{t}
      WHERE inserted_at < $1#{lower_clause}#{keyset}
      ORDER BY inserted_at, uuid
      LIMIT $4
    ), cleared AS (
      UPDATE #{t} r
      SET metadata = (r.metadata - $2::text[]) || jsonb_build_object('content_pruned_at', $3::text)
      FROM scan WHERE r.uuid = scan.uuid AND r.metadata ?| $2::text[]
      RETURNING 1
    ), last AS (
      SELECT inserted_at, uuid FROM scan ORDER BY inserted_at DESC, uuid DESC LIMIT 1
    )
    SELECT (SELECT count(*) FROM cleared), (SELECT count(*) FROM scan),
           (SELECT inserted_at FROM last), (SELECT uuid FROM last)
    """

    {sql, keyset_params(params, cursor)}
  end

  defp content_left_sql(lower, upper, cursor) do
    lower_clause = if lower, do: " AND inserted_at >= $3", else: ""
    keyset = keyset_clause(cursor, if(lower, do: 4, else: 3))

    {"SELECT 1 FROM #{table(Request)} WHERE inserted_at < $1 AND metadata ?| $2::text[]#{lower_clause}#{keyset} LIMIT 1",
     keyset_params([upper, @content_keys | List.wrap(lower)], cursor)}
  end

  # The reason of an off-purpose flag can echo the user's words.
  defp clear_reasons(state, cut, opts) do
    t = table(GuardEvent)

    where =
      "e.kind = 'off_purpose' AND e.reason IS NOT NULL AND e.inserted_at < $1 AND #{not_active_origin("e")}"

    sql =
      "WITH chunk AS MATERIALIZED (SELECT e.uuid FROM #{t} e WHERE #{where} LIMIT $2) " <>
        "UPDATE #{t} r SET reason = NULL FROM chunk WHERE r.uuid = chunk.uuid"

    unordered(
      :guard_reasons,
      state,
      sql,
      "SELECT 1 FROM #{t} e WHERE #{where} LIMIT 1",
      cut,
      opts
    )
  end

  # --- guard events ---

  defp prune_events(state, nil, _opts), do: {:ok, state}

  defp prune_events(state, cut, opts) do
    t = table(GuardEvent)
    where = "e.inserted_at < $1 AND #{not_active_origin("e")}"

    sql =
      "WITH chunk AS MATERIALIZED (SELECT e.uuid FROM #{t} e WHERE #{where} LIMIT $2) " <>
        "DELETE FROM #{t} r USING chunk WHERE r.uuid = chunk.uuid"

    unordered(:guard_events, state, sql, "SELECT 1 FROM #{t} e WHERE #{where} LIMIT 1", cut, opts)
  end

  # Chunks of a small table without an order: until a chunk comes back
  # short, or stopped. Either way more is left only if the probe finds
  # some: a short chunk is not proof (a row another transaction deleted or
  # changed in the meantime makes it short too).
  defp unordered(counter, state, sql, probe, cut, opts) do
    cut = naive(cut)

    chunk = fn cursor, limit, st ->
      with {:ok, n} <- execute_count(sql, [cut, limit], opts), do: {:ok, n, n, cursor, st}
    end

    case chunks(counter, state, opts, nil, chunk, deadline(opts, counter)) do
      {ended, state, _cursor} when ended in [:done, :stopped] ->
        case exists?(probe, [cut], opts) do
          {:ok, left?} -> {:ok, %{state | more_left: state.more_left or left?}}
          {:error, class} -> {:error, class, state}
        end

      error ->
        error
    end
  end

  defp not_active_origin(alias) do
    "NOT EXISTS (SELECT 1 FROM #{table(GuardBlock)} b WHERE b.origin_event_uuid = #{alias}.uuid AND b.lifted_at IS NULL)"
  end

  # --- chunk loop ---

  # Runs `chunk` until one looks at fewer rows than asked (`:done`), or the
  # counter's time slice or row cap is used up (`:stopped`), with the
  # cursor reached. At least one chunk runs. `chunk.(cursor, limit, state)`
  # answers `{:ok, counted, looked_at, cursor, state}`, `{:retry, state}`
  # (again, with a smaller chunk) or `{:error, class}`.
  defp chunks(counter, state, opts, cursor, chunk, deadline) do
    left = opts[:max_rows] - state.counts[counter]

    if left <= 0 do
      {:stopped, state, cursor}
    else
      limit = min(batch(counter, state, opts), left)

      case chunk.(cursor, limit, state) do
        {:ok, counted, looked_at, cursor, state} ->
          state = update_in(state, [:counts, counter], &(&1 + counted))
          next_chunk(looked_at < limit, counter, state, opts, cursor, chunk, deadline)

        {:retry, state} ->
          next_chunk(false, counter, state, opts, cursor, chunk, deadline)

        {:error, class} ->
          {:error, class, state}
      end
    end
  end

  # A short chunk was the last one; otherwise the deadline decides.
  defp next_chunk(true = _last?, _counter, state, _opts, cursor, _chunk, _deadline),
    do: {:done, state, cursor}

  defp next_chunk(false, counter, state, opts, cursor, chunk, deadline) do
    if now_ms() >= deadline do
      {:stopped, state, cursor}
    else
      pause(opts[:pause_ms])
      chunks(counter, state, opts, cursor, chunk, deadline)
    end
  end

  defp batch(:requests, _state, opts), do: opts[:request_batch]
  defp batch(:content, state, _opts), do: state.content_batch
  defp batch(_events, _state, opts), do: opts[:event_batch]

  defp deadline(opts, counter), do: now_ms() + Map.fetch!(opts[:time_limits], counter)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp pause(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp pause(_ms), do: :ok

  # One chunk: its own short transaction, so a stuck one fails with an
  # error the run can record rather than being killed by the job timeout.
  defp execute(sql, params, opts) do
    rows =
      in_transaction(opts[:statement_timeout_ms], opts[:lock_timeout_ms], fn qo ->
        repo().query!(sql, params, qo).rows
      end)

    {:ok, rows}
  rescue
    error -> {:error, error_class(error)}
  catch
    :exit, _reason -> {:error, "exit"}
  end

  defp execute_count(sql, params, opts) do
    count =
      in_transaction(opts[:statement_timeout_ms], opts[:lock_timeout_ms], fn qo ->
        repo().query!(sql, params, qo).num_rows
      end)

    {:ok, count}
  rescue
    error -> {:error, error_class(error)}
  catch
    :exit, _reason -> {:error, "exit"}
  end

  defp exists?(sql, params, opts) do
    with {:ok, rows} <- execute(sql, params, opts), do: {:ok, rows != []}
  end

  # The statement and lock timeouts are the database's; the client waits a
  # margin longer, so the database's error (recordable) always comes first.
  # `fun` gets the options for its queries.
  defp in_transaction(statement_ms, lock_ms, fun)
       when is_integer(statement_ms) and is_integer(lock_ms) do
    query_opts = [timeout: statement_ms + @client_margin_ms]

    {:ok, result} =
      repo().transaction(
        fn ->
          set_timeouts(statement_ms, lock_ms, query_opts)
          fun.(query_opts)
        end,
        query_opts
      )

    result
  end

  defp set_timeouts(statement_ms, lock_ms, query_opts)
       when is_integer(statement_ms) and is_integer(lock_ms) do
    repo().query!("SET LOCAL statement_timeout = #{statement_ms}", [], query_opts)
    repo().query!("SET LOCAL lock_timeout = #{lock_ms}", [], query_opts)
  end

  # The class of a failure, never the database's message.
  defp error_class(%Postgrex.Error{} = error) do
    case pg_code(error) do
      nil -> "Postgrex.Error"
      code -> Atom.to_string(code)
    end
  end

  defp error_class(%{__struct__: module}), do: module |> Module.split() |> Enum.join(".")

  defp pg_code(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code), do: code
  defp pg_code(_error), do: nil

  # ===========================================
  # HELPERS
  # ===========================================

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  # The events table's time is `timestamp` without a zone, in UTC.
  defp naive(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp table(schema) do
    source = schema.__schema__(:source)

    case schema.__schema__(:prefix) do
      nil -> ~s("#{source}")
      prefix -> ~s("#{prefix}"."#{source}")
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
