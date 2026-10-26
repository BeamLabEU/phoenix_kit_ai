defmodule PhoenixKitAI.Web.Components.JournalRetentionCard do
  @moduledoc """
  The markup of the "Journal retention" card on AI → Usage, and its two
  confirmations. State and events live in `PhoenixKitAI.Web.JournalRetention`;
  the periods, warnings and counts it shows come from
  `PhoenixKitAI.Retention`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.TimeDisplay, only: [time_ago: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAI.{Errors, Retention}
  alias PhoenixKitAI.Web.JournalRetention

  # A nightly run older than this is no longer "the last night".
  @recent_night_hours 36
  @settle_hours 24

  attr(:settings, :map, required: true, doc: "`Retention.settings/0`")
  attr(:last_run, :map, required: true, doc: "`Retention.last_run/0`")
  attr(:job, :map, default: nil, doc: "`Retention.pending_job/0`")
  attr(:can_manage, :boolean, default: false)
  attr(:form, :map, required: true)
  attr(:form_errors, :map, default: %{})
  attr(:warnings, :map, default: %{})
  attr(:run_form, :map, required: true)
  attr(:run_errors, :map, default: %{})
  attr(:run, :map, default: nil)
  attr(:save, :map, default: nil)

  @doc "The card, with its confirmations."
  def card(assigns) do
    assigns =
      assigns
      |> assign(:kinds, Retention.kinds())
      |> assign(:lines, status_lines(assigns.settings, assigns.last_run, DateTime.utc_now()))

    ~H"""
    <div id="ai-journal-retention" class="card bg-base-200 mb-6">
      <div class="card-body py-4 gap-4">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="card-title text-lg">{gettext("Journal retention")}</h3>
          <span :if={!@can_manage} id="ai-retention-read-only" class="badge badge-ghost badge-sm">
            {gettext("Read only")}
          </span>
        </div>
        <p class="text-sm text-base-content/70">
          {gettext(
            "By default nothing is deleted. A period you choose is applied by the nightly cleanup, no earlier than a day after you save it."
          )}
        </p>

        <ul id="ai-retention-status" class="text-sm space-y-1">
          <li :for={{id, type, text} <- @lines} id={"ai-retention-status-#{id}"} class="flex gap-2 items-start">
            <.icon name={line_icon(type)} class={"w-4 h-4 mt-0.5 shrink-0 #{line_class(type)}"} />
            <span>{text}</span>
          </li>
          <li :if={@job} id="ai-retention-job" class="flex gap-2 items-center">
            <.icon name="hero-arrow-path" class="w-4 h-4 shrink-0 text-info" />
            <span>{gettext("A cleanup job is %{state}", state: job_state(@job.state))}</span>
            <.time_ago datetime={@job.attempted_at || @job.inserted_at} class="text-xs text-base-content/60" />
          </li>
        </ul>

        <%= if @can_manage do %>
          <form
            id="ai-retention-form"
            phx-change="retention_validate"
            phx-submit="retention_save"
            class="space-y-4"
          >
            <.period_row
              :for={kind <- @kinds}
              kind={kind}
              value={@form[kind]}
              error={@form_errors[kind]}
              warnings={@warnings[kind] || []}
            />
            <div>
              <.button type="submit" size="sm" phx-disable-with={gettext("Saving…")}>
                {gettext("Save periods")}
              </.button>
            </div>
          </form>

          <.run_block
            kinds={@kinds}
            settings={@settings}
            form={@run_form}
            errors={@run_errors}
            run={@run}
          />
        <% else %>
          <dl id="ai-retention-periods" class="grid gap-2 sm:grid-cols-3 text-sm">
            <div :for={kind <- @kinds} data-period={kind}>
              <dt class="text-base-content/70">{kind_label(kind)}</dt>
              <dd class="font-medium">{period_text(@settings[kind])}</dd>
            </div>
          </dl>
        <% end %>

        <div class="text-xs text-base-content/60 space-y-1">
          <p>
            {gettext(
              "Clearing the content keeps each entry's cost, tokens and model. An entry's error message (which may quote the provider's answer) leaves only with the entry; the reasons and notes of blocks are not covered here."
            )}
          </p>
          <p>{wal_note()}</p>
        </div>
      </div>
    </div>

    <.confirm_modal
      :if={@save}
      show
      on_confirm="retention_save_confirm"
      on_cancel="retention_save_cancel"
      title={gettext("Save a shorter period")}
      title_icon="hero-exclamation-triangle"
      messages={save_messages(@save)}
      max_messages={10}
      confirm_text={gettext("Save")}
      loading={@save.preview == :loading}
      confirm_disabled={@save.preview == :loading}
      danger
    />

    <.confirm_modal
      :if={@run && @run.confirm}
      show
      on_confirm="retention_run_confirm"
      on_cancel="retention_run_cancel"
      title={gettext("Clean up the journal now")}
      title_icon="hero-trash"
      messages={preview_messages(@run.preview, run_kinds(@run)) ++ [{:info, wal_note()}]}
      max_messages={10}
      confirm_text={gettext("Delete")}
      danger
    />
    """
  end

  attr(:id, :string, required: true)
  attr(:at, :any, required: true, doc: "the oldest journal entry's time")

  @doc """
  The caption of a total "for all time" once entries may have been
  deleted: it covers the retained period, from the oldest entry on.
  """
  def retained_since(assigns) do
    ~H"""
    <div id={@id} class="text-xs text-base-content/60" data-retained-since>
      {gettext("For the retained period, since %{date}", date: date_only(@at))}
    </div>
    """
  end

  attr(:at, :any, required: true, doc: "`metadata.content_pruned_at` of a journal entry")

  @doc "The notice in a journal entry's details that its content was removed."
  def content_pruned(assigns) do
    ~H"""
    <div id="ai-request-content-pruned" class="alert alert-info text-sm mb-4">
      <.icon name="hero-scissors" class="w-4 h-4" />
      <span>
        {gettext("The content was removed by the retention period on %{date}",
          date: datetime_text(parse_iso(@at))
        )}
      </span>
    </div>
    """
  end

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_iso(_value), do: nil

  attr(:kind, :atom, required: true)
  attr(:value, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:warnings, :list, default: [])

  defp period_row(assigns) do
    assigns = assign(assigns, :forever, assigns.value["forever"] == true)

    ~H"""
    <div id={"ai-retention-#{@kind}"} class="grid gap-2 md:grid-cols-[16rem_1fr] items-start">
      <div>
        <div class="font-medium text-sm">{kind_label(@kind)}</div>
        <div class="text-xs text-base-content/60">{kind_hint(@kind)}</div>
      </div>
      <div class="space-y-1">
        <div class="flex flex-wrap items-center gap-3">
          <.checkbox
            id={"ai-retention-#{@kind}-forever"}
            name={"retention[#{@kind}][forever]"}
            checked={@forever}
            label={gettext("Keep forever")}
            class="checkbox-sm"
            aria-controls={"ai-retention-#{@kind}-n ai-retention-#{@kind}-unit"}
          />
          <.input
            :if={!@forever}
            id={"ai-retention-#{@kind}-n"}
            name={"retention[#{@kind}][n]"}
            value={@value["n"]}
            inputmode="numeric"
            autocomplete="off"
            aria-label={gettext("Number")}
            class={["input-sm", @error && "input-error"]}
            wrapper_class="w-24"
          />
          <div :if={!@forever} class="w-36">
            <.select
              id={"ai-retention-#{@kind}-unit"}
              name={"retention[#{@kind}][unit]"}
              value={@value["unit"]}
              options={unit_options(@value["n"])}
              aria-label={gettext("Unit")}
              class="select-sm"
            />
          </div>
        </div>
        <p :if={@error} class="text-error text-xs" data-retention-error={@kind}>{@error}</p>
        <p
          :for={warning <- @warnings}
          class="text-warning text-xs flex gap-1 items-start"
          data-retention-warning={warning}
        >
          <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 mt-0.5 shrink-0" />
          <span>{warning_text(warning, @kind, @value)}</span>
        </p>
      </div>
    </div>
    """
  end

  attr(:kinds, :list, required: true)
  attr(:settings, :map, required: true)
  attr(:form, :map, required: true)
  attr(:errors, :map, default: %{})
  attr(:run, :map, default: nil)

  defp run_block(assigns) do
    ~H"""
    <div id="ai-retention-run" class="border-t border-base-300 pt-4 space-y-3">
      <div>
        <h4 class="font-semibold">{gettext("Clean up now")}</h4>
        <p class="text-xs text-base-content/60">
          {gettext(
            "Count first, then confirm. A value here applies to this run only and is not saved."
          )}
        </p>
      </div>
      <form
        id="ai-retention-run-form"
        phx-change="retention_run_change"
        phx-submit="retention_run_preview"
        class="space-y-3"
      >
        <div
          :for={kind <- @kinds}
          id={"ai-retention-run-#{kind}"}
          class="grid gap-2 md:grid-cols-[16rem_1fr] items-start"
        >
          <div class="font-medium text-sm">{kind_label(kind)}</div>
          <div class="space-y-1">
            <div class="flex flex-wrap items-center gap-3">
              <div class="w-56">
                <.select
                  id={"ai-retention-run-#{kind}-mode"}
                  name={"retention_run[#{kind}][mode]"}
                  value={@form[kind]["mode"]}
                  options={mode_options(@settings[kind])}
                  aria-label={kind_label(kind)}
                  class="select-sm"
                />
              </div>
              <%= if @form[kind]["mode"] == "value" do %>
                <.input
                  id={"ai-retention-run-#{kind}-n"}
                  name={"retention_run[#{kind}][n]"}
                  value={@form[kind]["n"]}
                  inputmode="numeric"
                  autocomplete="off"
                  aria-label={gettext("Number")}
                  class={["input-sm", @errors[kind] && "input-error"]}
                  wrapper_class="w-24"
                />
                <div class="w-36">
                  <.select
                    id={"ai-retention-run-#{kind}-unit"}
                    name={"retention_run[#{kind}][unit]"}
                    value={@form[kind]["unit"]}
                    options={unit_options(@form[kind]["n"])}
                    aria-label={gettext("Unit")}
                    class="select-sm"
                  />
                </div>
              <% end %>
            </div>
            <p :if={@errors[kind]} class="text-error text-xs" data-retention-run-error={kind}>
              {@errors[kind]}
            </p>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <.button type="submit" size="sm" variant="outline" phx-disable-with={gettext("Counting…")}>
            {gettext("Count")}
          </.button>
          <.button
            :if={@run}
            id="ai-retention-run-delete"
            type="button"
            size="sm"
            variant="error"
            phx-click="retention_run_open"
            disabled={!JournalRetention.runnable?(@run)}
          >
            {gettext("Delete")}
          </.button>
        </div>
      </form>

      <ul :if={@run} id="ai-retention-run-preview" class="text-sm space-y-1">
        <li :for={{type, text} <- preview_messages(@run.preview, run_kinds(@run))} class="flex gap-2 items-start">
          <.icon name={line_icon(type)} class={"w-4 h-4 mt-0.5 shrink-0 #{line_class(type)}"} />
          <span>{text}</span>
        </li>
      </ul>
    </div>
    """
  end

  # ===========================================
  # TEXTS
  # ===========================================

  @doc "The name of a kind."
  @spec kind_label(Retention.kind()) :: String.t()
  def kind_label(:content), do: gettext("Content of journal entries")
  def kind_label(:requests), do: gettext("Journal entries")
  def kind_label(:guard_events), do: gettext("Guard events")

  defp kind_hint(:content),
    do: gettext("Prompts, answers and reasoning are removed; the entry, its cost and tokens stay")

  defp kind_hint(:requests), do: gettext("The whole entry is deleted, with its cost")
  defp kind_hint(:guard_events), do: gettext("Flags, blocks and forgiven limits of the AI guard")

  @doc "A period in words."
  @spec period_text(Retention.period()) :: String.t()
  def period_text(:forever), do: gettext("Kept forever")
  def period_text({n, :day}), do: ngettext("%{count} day", "%{count} days", n)
  def period_text({n, :month}), do: ngettext("%{count} month", "%{count} months", n)
  def period_text({n, :year}), do: ngettext("%{count} year", "%{count} years", n)

  # The units named for the number typed (a blank or a non-number: the
  # plural that goes with none).
  defp unit_options(n) do
    count =
      case Integer.parse(String.trim(n || "")) do
        {count, ""} when count >= 0 -> count
        _ -> 0
      end

    [
      {ngettext("day", "days", count), "day"},
      {ngettext("month", "months", count), "month"},
      {ngettext("year", "years", count), "year"}
    ]
  end

  defp mode_options(saved) do
    [{gettext("Leave as it is"), "skip"}] ++
      if(saved == :forever,
        do: [],
        else: [{gettext("By the saved period (%{period})", period: period_text(saved)), "saved"}]
      ) ++
      [{gettext("Older than…"), "value"}]
  end

  defp warning_text(:previous_months_deleted, kind, value),
    do:
      gettext(
        "Entries before %{date} will be deleted: there will be nothing to check the provider's invoice against for the months before it",
        date: raw_cutoff_date(kind, value)
      )

  defp warning_text(:short_windows, _kind, _value),
    do:
      gettext(
        "The 30-day windows (model recommendations, token medians, flags of the last 30 days, the 30-day totals on this page) will see less"
      )

  defp warning_text(:guard_history_deleted, kind, value),
    do:
      gettext("Flags and forgiven limits before %{date} will be deleted",
        date: raw_cutoff_date(kind, value)
      )

  defp warning_text(:content_outlives_row, _kind, _value),
    do: gettext("The content will live as long as its entry does")

  defp raw_cutoff_date(kind, value) do
    with {:ok, period} <- JournalRetention.parse_period(value),
         {:ok, cut} <- Retention.cutoff(kind, period, DateTime.utc_now()) do
      date_text(cut)
    else
      _ -> ""
    end
  end

  defp wal_note,
    do:
      gettext(
        "Deleting does not shrink the table files: the space is reused after autovacuum. A large first run writes a lot of WAL (replicas, backups)."
      )

  defp job_state("available"), do: gettext("waiting in the queue")
  defp job_state("scheduled"), do: gettext("scheduled")
  defp job_state("executing"), do: gettext("running")
  defp job_state("retryable"), do: gettext("waiting to retry")
  defp job_state(other), do: other

  defp line_icon(:ok), do: "hero-check-circle"
  defp line_icon(:error), do: "hero-x-circle"
  defp line_icon(:warning), do: "hero-exclamation-triangle"
  defp line_icon(_info), do: "hero-information-circle"

  defp line_class(:ok), do: "text-success"
  defp line_class(:error), do: "text-error"
  defp line_class(:warning), do: "text-warning"
  defp line_class(_info), do: "text-info"

  # ===========================================
  # THE NIGHTLY LINE
  # ===========================================

  @doc """
  The lines about the nightly cleanup, `{id, type, text}`: off (everything
  kept forever); the first cleanup of a kind changed less than a day ago;
  the last night — done (with what it did and whether more is left),
  failed, or not run at all; the last manual run; and a kind stored
  without its change time, to be saved again.
  """
  @spec status_lines(map(), map(), DateTime.t()) :: [{String.t(), atom(), String.t()}]
  def status_lines(settings, last_run, now) do
    finite = Enum.reject(Retention.kinds(), &(settings[&1] == :forever))
    settling = Enum.filter(finite, &settling?(settings.changed_at[&1], now))

    off =
      if finite == [],
        do: [{"off", :info, gettext("Automatic cleanup is off: the journal is kept forever")}],
        else: []

    first =
      for kind <- settling do
        {"first-#{kind}", :info,
         first_cleanup_text(
           kind,
           datetime_text(DateTime.add(settings.changed_at[kind], @settle_hours * 3600))
         )}
      end

    off ++
      first ++
      night_lines(last_run.scheduled, finite -- settling, now) ++
      manual_lines(last_run.manual) ++ unconfirmed_lines(settings)
  end

  defp first_cleanup_text(:content, date),
    do:
      gettext("The first cleanup of the content of journal entries runs no earlier than %{date}",
        date: date
      )

  defp first_cleanup_text(:requests, date),
    do: gettext("The first cleanup of journal entries runs no earlier than %{date}", date: date)

  defp first_cleanup_text(:guard_events, date),
    do: gettext("The first cleanup of guard events runs no earlier than %{date}", date: date)

  defp settling?(%DateTime{} = changed_at, now),
    do: DateTime.diff(now, changed_at, :second) < @settle_hours * 3600

  defp settling?(_changed_at, _now), do: false

  defp night_lines(%{status: :failed, at: at, error: error}, _settled, _now) do
    [
      {"night", :error,
       gettext("The nightly cleanup failed on %{date}: %{error}",
         date: datetime_text(at),
         error: failure_text(error)
       )}
    ]
  end

  defp night_lines(%{status: :ok, at: %DateTime{} = at} = entry, settled, now)
       when settled != [] do
    if DateTime.diff(now, at, :second) < @recent_night_hours * 3600,
      do:
        done_lines(
          "night",
          gettext("Last nightly cleanup: %{date}", date: datetime_text(at)),
          entry
        ),
      else: not_run()
  end

  defp night_lines(_entry, [], _now), do: []
  defp night_lines(_entry, _settled, _now), do: not_run()

  # A run's failure as the stamp keeps it: a refusal of the checks in its
  # sentence; a database or other class as it is (it names no value).
  @refusal_classes ~w(foreign_key_blocks cutoff_in_future invalid_cutoff invalid_args)

  defp failure_text(class) when class in @refusal_classes,
    do: Errors.message({:prune_failed, class})

  defp failure_text(class) when is_binary(class), do: class
  defp failure_text(_class), do: "?"

  defp not_run do
    [
      {"night", :warning,
       gettext(
         "The nightly cleanup has not run. Check that PhoenixKitAI.JournalPruneWorker is in Oban's crontab (mix phoenix_kit.update adds it), or clean up by hand."
       )}
    ]
  end

  defp manual_lines(%{status: :ok, at: at} = entry),
    do:
      done_lines(
        "manual",
        gettext("Last manual cleanup: %{date}", date: datetime_text(at)),
        entry
      )

  defp manual_lines(%{status: :failed, at: at, error: error}) do
    [
      {"manual", :error,
       gettext("The last manual cleanup failed on %{date}: %{error}",
         date: datetime_text(at),
         error: failure_text(error)
       )}
    ]
  end

  defp manual_lines(_entry), do: []

  defp done_lines(id, heading, %{counts: counts, more_left: more_left}) do
    done =
      Enum.join(
        [
          heading,
          ngettext(
            "%{count} journal entry deleted",
            "%{count} journal entries deleted",
            counts.requests
          ),
          ngettext(
            "the content of %{count} entry cleared",
            "the content of %{count} entries cleared",
            counts.content
          ),
          ngettext(
            "%{count} guard event deleted",
            "%{count} guard events deleted",
            counts.guard_events
          )
        ],
        ", "
      )

    more =
      if more_left,
        do: [
          {"#{id}-more", :warning,
           gettext("More is left: the next run continues where this one stopped")}
        ],
        else: []

    [{id, :ok, done} | more]
  end

  # The stored period is what the form shows (`unconfirmed_periods`):
  # saving it as it is applies it.
  defp unconfirmed_lines(settings) do
    for kind <- settings.unconfirmed do
      period = period_text(Map.get(settings.unconfirmed_periods, kind, :forever))
      {"unconfirmed-#{kind}", :warning, unconfirmed_text(kind, period)}
    end
  end

  defp unconfirmed_text(:content, period),
    do:
      gettext(
        "The period for the content of journal entries (%{period}) is stored without the time it was set: the content is kept forever until it is saved again",
        period: period
      )

  defp unconfirmed_text(:requests, period),
    do:
      gettext(
        "The period for journal entries (%{period}) is stored without the time it was set: the entries are kept forever until it is saved again",
        period: period
      )

  defp unconfirmed_text(:guard_events, period),
    do:
      gettext(
        "The period for guard events (%{period}) is stored without the time it was set: the events are kept forever until it is saved again",
        period: period
      )

  # ===========================================
  # THE PREVIEW
  # ===========================================

  defp run_kinds(%{cutoffs: cutoffs}), do: Enum.filter(Retention.kinds(), &cutoffs[&1])

  defp save_messages(%{preview: preview, kinds: kinds, first_run_at: first_run_at}) do
    [
      {:info,
       gettext("The first nightly cleanup runs no earlier than %{date}.",
         date: datetime_text(first_run_at)
       )}
      | preview_messages(preview, kinds)
    ] ++ [{:info, wal_note()}]
  end

  @doc """
  The preview in words, `{type, text}`, for the kinds given a boundary:
  the counts and dates, and the floor where a boundary was held at it. Not
  counted in time: a warning that the run stays possible. Refused (a
  foreign key): the reason.
  """
  @spec preview_messages(term(), [Retention.kind()]) :: [{atom(), String.t()}]
  def preview_messages(:loading, _kinds), do: [{:info, gettext("Counting…")}]

  def preview_messages({:ok, counts}, kinds), do: Enum.flat_map(kinds, &kind_messages(&1, counts))

  def preview_messages({:error, :preview_timeout}, _kinds) do
    [
      {:warning, Errors.message(:preview_timeout)},
      {:info,
       gettext(
         "You can still go on: the boundaries are checked again, and the numbers will be in the outcome."
       )}
    ]
  end

  def preview_messages({:error, reason}, _kinds), do: [{:error, Errors.message(reason)}]

  defp kind_messages(:requests, counts) do
    date = date_text(counts.cutoffs.requests)

    floor_message(:requests, counts, date) ++
      [
        {:info,
         ngettext(
           "%{count} journal entry older than %{date} will be deleted.",
           "%{count} journal entries older than %{date} will be deleted.",
           counts.requests,
           date: date
         )}
      ]
  end

  defp kind_messages(:content, counts) do
    cut = counts.cutoffs.content
    # where the count starts: the later of the requests boundary and the
    # point already cleared
    from = counts.content_from

    text =
      if from && DateTime.compare(from, cut) == :lt do
        ngettext(
          "The content of up to %{count} journal entry from %{from} to %{date} will be removed.",
          "The content of up to %{count} journal entries from %{from} to %{date} will be removed.",
          counts.content,
          from: date_text(from),
          date: date_text(cut)
        )
      else
        ngettext(
          "The content of up to %{count} journal entry older than %{date} will be removed.",
          "The content of up to %{count} journal entries older than %{date} will be removed.",
          counts.content,
          date: date_text(cut)
        )
      end

    floor_message(:content, counts, nil) ++ [{:info, text}]
  end

  defp kind_messages(:guard_events, counts) do
    date = date_text(counts.cutoffs.guard_events)

    floor_message(:guard_events, counts, date) ++
      [
        {:info,
         ngettext(
           "%{count} guard event older than %{date} will be deleted.",
           "%{count} guard events older than %{date} will be deleted.",
           counts.guard_events,
           date: date
         )}
      ]
  end

  defp floor_message(kind, %{clamped: clamped}, date) do
    if kind in clamped, do: [{:warning, floor_text(kind, date)}], else: []
  end

  defp floor_text(:requests, date),
    do:
      gettext(
        "The period is shorter than the current month: entries from %{date} on are not deleted — the spend limits read them.",
        date: date
      )

  defp floor_text(:guard_events, date),
    do:
      gettext(
        "The period is shorter than the current month: guard events from %{date} on are not deleted — this month's forgiven limits read them.",
        date: date
      )

  defp floor_text(:content, _date),
    do: gettext("The content of the last 24 hours is never removed.")

  # ===========================================
  # DATES
  # ===========================================

  # A boundary in the site time zone: its date, and the time unless it is
  # midnight.
  defp date_text(%DateTime{} = at) do
    local = TimeZone.shift(at, zone())
    date = format_date(local)

    if Time.truncate(DateTime.to_time(local), :second) == ~T[00:00:00],
      do: date,
      else: date <> " " <> Calendar.strftime(local, "%H:%M")
  end

  defp date_text(_at), do: "?"

  defp date_only(%DateTime{} = at), do: format_date(TimeZone.shift(at, zone()))
  defp date_only(_at), do: "?"

  defp datetime_text(%DateTime{} = at) do
    local = TimeZone.shift(at, zone())
    format_date(local) <> " " <> Calendar.strftime(local, "%H:%M")
  end

  defp datetime_text(_at), do: "?"

  defp format_date(%{year: year, month: month, day: day}) do
    gettext("%{day} %{month} %{year}", day: day, month: month_name(month), year: year)
  end

  # The month as it reads after a day number ("25 октября"), which is not
  # the nominative a calendar header uses.
  defp month_name(1), do: pgettext("date", "January")
  defp month_name(2), do: pgettext("date", "February")
  defp month_name(3), do: pgettext("date", "March")
  defp month_name(4), do: pgettext("date", "April")
  defp month_name(5), do: pgettext("date", "May")
  defp month_name(6), do: pgettext("date", "June")
  defp month_name(7), do: pgettext("date", "July")
  defp month_name(8), do: pgettext("date", "August")
  defp month_name(9), do: pgettext("date", "September")
  defp month_name(10), do: pgettext("date", "October")
  defp month_name(11), do: pgettext("date", "November")
  defp month_name(12), do: pgettext("date", "December")

  defp zone, do: Settings.get_setting("time_zone", "0")
end
