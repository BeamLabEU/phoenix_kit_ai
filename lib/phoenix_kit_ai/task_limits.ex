defmodule PhoenixKitAI.TaskLimits do
  @moduledoc """
  The limits of an AI task: how much the task may use, and how much each user
  may use in it, in a calendar day and month of the site time zone.

  ## Scopes, units, periods

  | scope | counts |
  |---|---|
  | `:task` | every call of the task, with a user or without |
  | `:user` | the calls of one user in the task |

  Units: `:money` (US dollars, a `Decimal`; stored as a decimal string, read
  through `PhoenixKitAI.Money`), `:requests`, `:tokens`. Periods: `:day`, `:month` — the
  calendar day and month of the site time zone (Settings → `time_zone`,
  `PhoenixKit.Utils.TimeZone`), each from its local midnight to the next.

  A limit is an amount per (unit, period). An empty cell inherits the next
  layer's default; with no default there is no limit. `0` allows nothing.

  ## Which limit is in force

  Cell by cell (unit and period), the first that is set:

    * `:user` — the user's personal exception (`phoenix_kit_ai_task_user_limits`),
      then the task's default for its users (`limits["user"]` of
      `phoenix_kit_ai_task_settings`), then the declaration's
      `default_limits.user`;
    * `:task` — the task's own (`limits["task"]`), then the declaration's
      `default_limits.task`.

  A task declared with `user_limits: false` (its module limits its users
  itself) has no `:user` scope here: the declaration's and the stored user
  values are ignored (and kept), and setting a user limit or forgiving one is
  `{:error, :user_limits_off}`.

  ## What is counted

  The task's rows of the journal (`phoenix_kit_ai_requests`,
  `metadata->>'task'`), successful ones only (`status = 'success'`): a failed
  call costs nothing and a refusal is an error row, so neither counts. Money
  is the `cost` sum (dollars), tokens the `total_tokens` sum, requests the rows —
  so a cached answer (a zero-cost success row) counts as one request and no
  money or tokens. Money is what a row's cost says (`PhoenixKitAI.CallCost`:
  the provider's own cost, else a catalogue, the endpoint's manual or the
  built-in Anthropic price, `metadata.cost_source`; the vision verbs are
  priced like chat, making or editing images only by the provider's own
  cost): an endpoint none of them prices (`money_counted?/2`) adds nothing
  to it, and there requests and tokens are what limits a task.

  ## The check

  `check/3` runs before every provider call that names a declared task
  (after the model check, before `PhoenixKitAI.Budget`). A limit whose count
  has reached it refuses the call with `{:error, {:task_limit_exceeded,
  scope, unit, period}}` until its window ends or the limit is raised; the
  refusal is a journal row like every guard refusal. There is no reservation:
  calls running at the same time can each go past a limit by their own size.

  At the warn percent (the task's `warn_percent`, default 80) a user's limit
  tells the user and the task's limit tells the watchers
  (`PhoenixKitAI.GuardEvents`); a reached limit tells both. Each once per
  window.

  ## Forgiving

  `forgive/6` restarts the count of one scope and period from that moment to
  the end of the window; the limit itself stays. The moment is kept only as
  the `limit_forgiven` event.

  Every function here that changes something takes the scope of the person
  doing it and needs `ai.manage` (`PhoenixKitAI.Guard.may_manage?/1`); the
  change goes to the Activity log.

  The check fails open: a database error reads as nothing used.

  ## The cache

  A call reads a task's settings row and personal limits from a per-node
  cache (the request cache's flags table), loaded on the first call of the
  task: a task without limits costs no query. Every change through this
  module drops the task's entry here and broadcasts
  `{:task_limits_changed, task_key}` on `topic/0`, which
  `PhoenixKitAI.GuardWatch` turns into the same drop on every node; a
  restarted watch drops the whole cache, since it may have missed a
  broadcast. An entry is also read again after 60 seconds, which bounds what
  a lost broadcast can leave behind. A change made inside the caller's own
  `Repo.transaction` drops the cache before that transaction commits, so a
  call in between may cache the old values again; the 60 seconds bound that
  too. The usage and forgiving are always read from the database, and only
  when a limit is in force.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAI.{Endpoint, Guard, GuardEvent, GuardEvents, Money, Request}
  alias PhoenixKitAI.{Tasks, TaskSetting, TaskSpec, TaskUserLimit}

  @scopes [:task, :user]
  @units [:money, :requests, :tokens]
  @periods [:day, :month]
  @default_warn_percent 80
  @topic "phoenix_kit:ai:guard"
  @cache_ttl_ms :timer.seconds(60)
  # What the Tasks page sets; the classifier modes come with the classifier.
  @settable_modes ~w(off self_flag)

  @type scope :: :task | :user
  @type unit :: :money | :requests | :tokens
  @type period :: :day | :month
  @typedoc "Dollars (a `Decimal`) for `:money`, a whole number for requests and tokens."
  @type amount :: Decimal.t() | non_neg_integer()
  @type limits :: %{optional(unit()) => %{optional(period()) => amount() | :unmigrated}}
  @type window :: {DateTime.t(), DateTime.t()}
  @type status :: %{
          scope: scope(),
          unit: unit(),
          period: period(),
          used: amount(),
          limit: amount() | :unmigrated,
          period_key: String.t(),
          ends_at: DateTime.t(),
          forgiven_at: DateTime.t() | nil
        }

  @doc "The scopes, units and periods, in the order they are checked."
  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @doc false
  @spec units() :: [unit()]
  def units, do: @units

  @doc false
  @spec periods() :: [period()]
  def periods, do: @periods

  # ===========================================
  # WINDOWS
  # ===========================================

  @doc "The local day and month that contain `now`, as half-open UTC windows."
  @spec windows(DateTime.t()) :: %{day: window(), month: window()}
  def windows(now \\ DateTime.utc_now()) do
    zone = zone()
    today = TimeZone.local_date(now, zone)
    first = Date.beginning_of_month(today)

    %{
      day: {TimeZone.date_start(today, zone), TimeZone.date_start(Date.add(today, 1), zone)},
      month: {
        TimeZone.date_start(first, zone),
        TimeZone.date_start(Date.add(Date.end_of_month(today), 1), zone)
      }
    }
  end

  @doc ~s(The local day and month of `now` as keys: `%{day: "2026-10-22", month: "2026-10"}`.)
  @spec period_keys(DateTime.t()) :: %{day: String.t(), month: String.t()}
  def period_keys(now \\ DateTime.utc_now()) do
    today = now |> TimeZone.local_date(zone()) |> Date.to_iso8601()
    %{day: today, month: String.slice(today, 0, 7)}
  end

  defp zone, do: Settings.get_setting("time_zone", "0")

  # ===========================================
  # LIMITS IN FORCE
  # ===========================================

  @doc """
  The limits in force for `spec` (and `user_uuid`, when given; without one
  the user scope is empty) — see the moduledoc.
  """
  @spec effective(TaskSpec.t(), String.t() | nil) :: %{task: limits(), user: limits()}
  def effective(%TaskSpec{} = spec, user_uuid),
    do: effective(spec, cached(spec.key), user_uuid)

  defp effective(spec, %{setting: setting, personal: personal}, user_uuid) do
    stored = stored_limits(setting)
    declared = normalize_scoped(spec.default_limits)

    user =
      if is_binary(user_uuid) and spec.user_limits != false,
        do: merge([Map.get(personal, user_uuid, %{}), stored.user, declared.user]),
        else: %{}

    %{task: merge([stored.task, declared.task]), user: user}
  end

  @doc """
  What a task's settings and its declaration say, layer by layer, for a page
  that edits them: `stored` (the settings row), `declared`
  (`default_limits`) and `defaults` (the two merged — the task's limits and
  the limits of a user without a personal exception). The user parts are
  empty for a task declared with `user_limits: false`.
  """
  @spec layers(TaskSpec.t()) :: %{
          setting: TaskSetting.t() | nil,
          stored: %{task: limits(), user: limits()},
          declared: %{task: limits(), user: limits()},
          defaults: %{task: limits(), user: limits()}
        }
  def layers(%TaskSpec{} = spec) do
    setting = settings(spec.key)
    stored = setting |> stored_limits() |> user_part(spec)
    declared = spec.default_limits |> normalize_scoped() |> user_part(spec)

    %{
      setting: setting,
      stored: stored,
      declared: declared,
      defaults: %{
        task: merge([stored.task, declared.task]),
        user: merge([stored.user, declared.user])
      }
    }
  end

  @doc "The settings row of a task, or nil."
  @spec settings(String.t()) :: TaskSetting.t() | nil
  def settings(task_key) when is_binary(task_key),
    do: repo().get_by(TaskSetting, task_key: task_key)

  @doc "The warn percent of a task (its setting, else 80)."
  @spec warn_percent(TaskSetting.t() | String.t() | nil) :: pos_integer()
  def warn_percent(%TaskSetting{warn_percent: percent}) when is_integer(percent), do: percent
  def warn_percent(%TaskSetting{}), do: @default_warn_percent
  def warn_percent(nil), do: @default_warn_percent
  def warn_percent(task_key) when is_binary(task_key), do: warn_percent(settings(task_key))

  @doc "The personal exceptions of a task, newest first."
  @spec list_user_limits(String.t()) :: [TaskUserLimit.t()]
  def list_user_limits(task_key) when is_binary(task_key) do
    from(l in TaskUserLimit, where: l.task_key == ^task_key, order_by: [desc: l.updated_at])
    |> repo().all()
  end

  @doc """
  Whether the money of a task's calls counts on `endpoint`. For chat and for
  a task that reads images (`needs` without `:image_output`; the vision
  verbs are chat calls with images, priced the same way): some source prices
  its calls (`PhoenixKitAI.reports_cost?/1` — the provider's own cost, a
  catalogue, manual or built-in price). A task that makes images
  (`:image_output` among `needs`) may call the image-making verbs, priced
  per image or per call, which only the provider's own cost prices
  (OpenRouter): a manual or built-in price, per token, does not count there.
  A caller asking for `[:vision]` gets the chat answer. Speech is priced by
  `PhoenixKitAI.TtsPricing` on other providers too; an endpoint does not say
  which kind it is.
  """
  @spec money_counted?(Endpoint.t(), [TaskSpec.need()]) :: boolean()
  def money_counted?(endpoint, needs \\ [])

  def money_counted?(%Endpoint{provider: provider} = endpoint, needs) when is_binary(provider) do
    if :image_output in needs,
      do: Endpoint.base_provider(provider) == "openrouter",
      else: PhoenixKitAI.reports_cost?(endpoint)
  end

  def money_counted?(_endpoint, _needs), do: false

  # ── the per-node cache (see the moduledoc) ──

  @doc "The PubSub topic of `{:task_limits_changed, task_key}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  # How long a cached entry is used before it is read again.
  @spec cache_ttl_ms() :: pos_integer()
  def cache_ttl_ms, do: @cache_ttl_ms

  @doc false
  # Drops this node's cached limits of `task_key`: bumping the task's
  # generation makes an entry loaded before the change unusable, even one
  # written back after this.
  @spec forget(String.t()) :: :ok
  def forget(task_key) do
    key = {__MODULE__, :generation, task_key}
    :ets.update_counter(flags_table(), key, 1, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Forgets the whole cache (tests: the database is rolled back, the cache
  # is not).
  @spec reset_cache() :: :ok
  def reset_cache do
    :ets.match_delete(flags_table(), {{__MODULE__, :_, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # The task's settings row from this node's cache (nil when none): what
  # the guard reads per call besides the limits (the guard mode, the
  # purpose override).
  @spec cached_setting(String.t()) :: TaskSetting.t() | nil
  def cached_setting(task_key) when is_binary(task_key), do: cached(task_key).setting

  defp cached(task_key) do
    table = flags_table()
    generation = generation(table, task_key)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, {__MODULE__, :limits, task_key}) do
      [{_key, {^generation, loaded_at, entry}}] when now - loaded_at < @cache_ttl_ms ->
        entry

      _missing_stale_or_old ->
        entry = load(task_key)
        :ets.insert(table, {{__MODULE__, :limits, task_key}, {generation, now, entry}})
        entry
    end
  rescue
    ArgumentError -> load(task_key)
  end

  defp generation(table, task_key) do
    case :ets.lookup(table, {__MODULE__, :generation, task_key}) do
      [{_key, generation}] -> generation
      [] -> 0
    end
  end

  defp load(task_key) do
    %{
      setting: settings(task_key),
      personal: Map.new(list_user_limits(task_key), &{&1.user_uuid, normalize(&1.limits)})
    }
  end

  # After a change: this node at once, the others by broadcast.
  defp changed({:ok, _} = result, task_key) do
    forget(task_key)
    PubSub.broadcast(@topic, {:task_limits_changed, task_key})
    result
  end

  defp changed(result, _task_key), do: result

  defp flags_table, do: PhoenixKitAI.RequestCache.flags_table()

  defp stored_limits(%TaskSetting{limits: limits}), do: normalize_scoped(limits)
  defp stored_limits(nil), do: %{task: %{}, user: %{}}

  # The user part of scoped limits, empty when the task has no user scope.
  defp user_part(scoped, %TaskSpec{user_limits: false}), do: %{scoped | user: %{}}
  defp user_part(scoped, %TaskSpec{}), do: scoped

  # The first layer that sets a cell wins.
  defp merge(layers) do
    layers
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn layer, acc ->
      Map.merge(acc, layer, fn _unit, lower, upper -> Map.merge(lower, upper) end)
    end)
  end

  @doc false
  # `%{scope => %{unit => %{period => amount}}}` with string or atom keys,
  # read into atoms; anything else is left out.
  @spec normalize_scoped(term()) :: %{task: limits(), user: limits()}
  def normalize_scoped(limits) when is_map(limits) do
    Map.new(@scopes, fn scope -> {scope, normalize(fetch(limits, scope))} end)
  end

  def normalize_scoped(_limits), do: %{task: %{}, user: %{}}

  @doc false
  # `%{unit => %{period => amount}}`: requests and tokens are whole numbers ≥ 0
  # (or a string of one); money is dollars, a `Decimal` (or a dollar string).
  # A money cell in the released shape — an integer or a digits-only string,
  # which meant millionths of a dollar — reads as `:unmigrated`, and a task
  # with one in force refuses its calls (`check/3`) rather than take millionths
  # for dollars. A blank or invalid amount is left out — no limit.
  @spec normalize(term()) :: limits()
  def normalize(limits) when is_map(limits) do
    for unit <- @units,
        periods = fetch(limits, unit),
        is_map(periods),
        cells = cells(unit, periods),
        cells != %{},
        into: %{},
        do: {unit, cells}
  end

  def normalize(_limits), do: %{}

  defp cells(unit, periods) do
    for period <- @periods,
        amount = amount(unit, fetch(periods, period)),
        amount != nil,
        into: %{},
        do: {period, amount}
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp amount(:money, value) do
    if Money.legacy_amount?(value) or is_float(value) do
      :unmigrated
    else
      case Money.amount(value) do
        {:ok, dollars} -> dollars
        _ -> nil
      end
    end
  end

  defp amount(_unit, value) when is_integer(value) and value >= 0, do: value

  defp amount(_unit, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp amount(_unit, _value), do: nil

  # ===========================================
  # USAGE
  # ===========================================

  @doc """
  What the task (and `user_uuid` in it, when given) used in the day and month
  of `now`, from the moment a limit was forgiven when it was:
  `%{task: %{unit => %{day:, month:}}, user: … | nil}`. The user is counted
  for any task, also one declared with `user_limits: false`, where that
  count limits nothing.
  """
  @spec usage(String.t(), String.t() | nil, DateTime.t()) :: %{
          task: %{unit() => %{period() => amount()}},
          user: %{unit() => %{period() => amount()}} | nil
        }
  def usage(task_key, user_uuid, now \\ DateTime.utc_now()) when is_binary(task_key),
    do: task_key |> usage(user_uuid(user_uuid), now, true) |> Map.delete(:forgiven)

  # The task's count is skipped when no task limit needs it.
  defp usage(task_key, user_uuid, now, task?) do
    windows = windows(now)
    forgiven = forgiven(task_key, user_uuid, windows)

    %{
      task: if(task?, do: count(task_key, nil, windows, forgiven)),
      user: if(is_binary(user_uuid), do: count(task_key, user_uuid, windows, forgiven)),
      forgiven: forgiven
    }
  end

  defp count(task_key, user_uuid, windows, forgiven) do
    scope = if user_uuid, do: :user, else: :task
    day = {since(windows.day, forgiven[{scope, :day}]), elem(windows.day, 1)}
    month = {since(windows.month, forgiven[{scope, :month}]), elem(windows.month, 1)}
    totals = task_key |> totals_query(user_uuid, day, month) |> repo().one()

    Map.new(@units, fn unit ->
      {unit,
       %{
         day: total(unit, totals && totals[:"day_#{unit}"]),
         month: total(unit, totals && totals[:"month_#{unit}"])
       }}
    end)
  end

  defp totals_query(task_key, user_uuid, {day_from, day_to}, {month_from, month_to}) do
    lower = Enum.min([day_from, month_from], DateTime)

    # `"success"` stays a literal, as in `Budget`.
    query =
      from(r in Request,
        where:
          fragment("?->>'task'", r.metadata) == ^task_key and r.status == "success" and
            r.inserted_at >= ^lower and r.inserted_at < ^month_to,
        select: %{
          day_money:
            filter(
              sum(r.cost),
              r.inserted_at >= ^day_from and r.inserted_at < ^day_to
            ),
          day_requests:
            filter(count(r.uuid), r.inserted_at >= ^day_from and r.inserted_at < ^day_to),
          day_tokens:
            filter(sum(r.total_tokens), r.inserted_at >= ^day_from and r.inserted_at < ^day_to),
          month_money: filter(sum(r.cost), r.inserted_at >= ^month_from),
          month_requests: filter(count(r.uuid), r.inserted_at >= ^month_from),
          month_tokens: filter(sum(r.total_tokens), r.inserted_at >= ^month_from)
        }
      )

    if user_uuid, do: where(query, [r], r.user_uuid == ^user_uuid), else: query
  end

  defp since({from, _to}, nil), do: from

  defp since({from, _to}, %DateTime{} = forgiven_at),
    do: if(DateTime.compare(forgiven_at, from) == :gt, do: forgiven_at, else: from)

  # The last forgiving of each scope and period inside its window.
  defp forgiven(task_key, user_uuid, windows) do
    {month_from, _} = windows.month

    from(e in GuardEvent,
      where:
        e.task_key == ^task_key and e.kind == "limit_forgiven" and e.inserted_at >= ^month_from,
      select: {e.user_uuid, e.ref, e.inserted_at}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {event_user, ref, at}, acc ->
      with {:ok, scope, period} <- forgiven_ref(ref),
           true <- scope == :task or (is_binary(user_uuid) and event_user == user_uuid),
           {from, to} = windows[period],
           true <- DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt do
        Map.update(acc, {scope, period}, at, &Enum.max([&1, at], DateTime))
      else
        _ -> acc
      end
    end)
  end

  defp forgiven_ref(%{"scope" => scope, "period" => period}) do
    with {:ok, scope} <- known(scope, @scopes), {:ok, period} <- known(period, @periods) do
      {:ok, scope, period}
    end
  end

  defp forgiven_ref(_ref), do: :error

  defp known(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp known(value, allowed) when is_atom(value),
    do: if(value in allowed, do: {:ok, value}, else: :error)

  defp known(_value, _allowed), do: :error

  # Money is the dollars the rows' `cost` add up to, never rounded.
  defp total(:money, value), do: Money.sum(value)
  defp total(_unit, value), do: to_int(value)

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp to_int(value) when is_integer(value), do: value

  # ===========================================
  # THE CHECK
  # ===========================================

  @doc """
  Every limit in force for `spec` (and `user_uuid`) with what is used of it:
  the task's first, then the user's; month before day; money, requests,
  tokens.
  """
  @spec statuses(TaskSpec.t(), String.t() | nil, DateTime.t()) :: [status()]
  def statuses(%TaskSpec{} = spec, user_uuid, now \\ DateTime.utc_now()) do
    user_uuid = user_uuid(user_uuid)
    statuses(spec.key, effective(spec, user_uuid), user_uuid, now)
  end

  defp statuses(task_key, limits, user_uuid, now) do
    if limits.task == %{} and limits.user == %{} do
      []
    else
      user_uuid = if limits.user != %{}, do: user_uuid
      usage = usage(task_key, user_uuid, now, limits.task != %{})
      keys = period_keys(now)
      windows = windows(now)

      for scope <- @scopes,
          used = usage[scope],
          used != nil,
          period <- [:month, :day],
          unit <- @units,
          limit = get_in(limits, [scope, unit, period]),
          limit != nil do
        %{
          scope: scope,
          unit: unit,
          period: period,
          used: used[unit][period],
          limit: limit,
          period_key: keys[period],
          ends_at: elem(windows[period], 1),
          forgiven_at: usage.forgiven[{scope, period}]
        }
      end
    end
  end

  @doc """
  Whether a call of `spec` (`opts[:user_uuid]` the user, when any) may go on
  now: `:ok`, or `{:error, {:task_limit_exceeded, scope, unit, period}}` for
  the first limit reached. Tells the watchers and the user (see the
  moduledoc). A money limit in force that is still in the released shape
  (`normalize/1`) refuses with `{:error, {:task_limit_unmigrated, task_key}}`.
  `nil` (no declared task) is always `:ok`.
  """
  @spec check(TaskSpec.t() | nil, keyword(), DateTime.t()) ::
          :ok
          | {:error, {:task_limit_exceeded, scope(), unit(), period()}}
          | {:error, {:task_limit_unmigrated, String.t()}}
  def check(spec, opts, now \\ DateTime.utc_now())

  def check(nil, _opts, _now), do: :ok

  def check(%TaskSpec{} = spec, opts, now) do
    user_uuid = user_uuid(opts[:user_uuid])
    entry = cached(spec.key)
    limits = effective(spec, entry, user_uuid)

    # Before any query: a failing usage read is rescued into `:ok` below, and
    # a limit in the released unit must refuse whatever the database does.
    if unmigrated?(limits) do
      log_unmigrated(spec.key)
      {:error, {:task_limit_unmigrated, spec.key}}
    else
      spec.key |> statuses(limits, user_uuid, now) |> decide(spec, entry, user_uuid)
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] task limits of #{inspect(spec.key)} not checked: #{inspect(error.__struct__)}"
      )

      :ok
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI] task limits of #{inspect(spec.key)} not checked: exit")
      :ok
  end

  defp decide(statuses, spec, entry, user_uuid) do
    case Enum.find(statuses, &reached?/1) do
      nil ->
        percent = warn_percent(entry.setting)

        statuses
        |> Enum.filter(&warn?(&1, percent))
        |> Enum.each(&GuardEvents.limit_warning(spec, user_for(&1, user_uuid), &1))

        :ok

      reached ->
        GuardEvents.limit_reached(spec, user_for(reached, user_uuid), reached)
        {:error, {:task_limit_exceeded, reached.scope, reached.unit, reached.period}}
    end
  end

  # A money limit in force still in the released millionths (`normalize/1`).
  defp unmigrated?(limits) do
    Enum.any?([limits.task, limits.user], fn cells ->
      cells |> Map.get(:money, %{}) |> Map.values() |> Enum.member?(:unmigrated)
    end)
  end

  defp reached?(%{used: %Decimal{} = used, limit: %Decimal{} = limit}),
    do: Decimal.compare(used, limit) != :lt

  defp reached?(%{used: used, limit: limit}) when is_integer(limit), do: used >= limit

  defp warn?(%{used: %Decimal{} = used, limit: %Decimal{} = limit}, percent) do
    Decimal.compare(limit, 0) == :gt and
      Decimal.compare(Decimal.mult(used, 100), Decimal.mult(limit, percent)) != :lt
  end

  defp warn?(%{used: used, limit: limit}, percent) when is_integer(limit),
    do: limit > 0 and used * 100 >= limit * percent

  # Once per node and task, not on every refused call.
  defp log_unmigrated(task_key) do
    key = {__MODULE__, :unmigrated, task_key}
    table = PhoenixKitAI.RequestCache.flags_table()

    unless :ets.member(table, key) do
      :ets.insert(table, {key, true})

      Logger.error(
        "[PhoenixKitAI] task #{inspect(task_key)} has a money limit in millionths of a dollar " <>
          "(the released shape): its calls are refused until `mix phoenix_kit.update` has run " <>
          "the module's migrations, or the limit is set again in dollars"
      )
    end
  rescue
    _ -> :ok
  end

  # A caller may pass a visitor's own id as `user_uuid:`; the journal's
  # column is a uuid, so such a call is held to the task's limits alone
  # instead of the count raising and the whole check failing open.
  defp user_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp user_uuid(_value), do: nil

  defp user_for(%{scope: :user}, user_uuid), do: user_uuid
  defp user_for(_status, _user_uuid), do: nil

  # ===========================================
  # CHANGES (ai.manage)
  # ===========================================

  @doc """
  Sets a task's limits and warn percent: `attrs` takes `"limits"`
  (`%{"task" => …, "user" => …}`, see the moduledoc; amounts as numbers or
  strings, blank for none) and `"warn_percent"` (1–100, blank for the
  default). Needs `ai.manage`; written to the Activity log.

  For a task declared with `user_limits: false` a user amount is refused
  (`{:error, :user_limits_off}`, blank ones are not amounts) and the user
  values stored before are kept as they are.
  """
  @spec update_settings(term(), String.t(), map()) ::
          {:ok, TaskSetting.t()}
          | {:error, :forbidden | :unknown_task | :user_limits_off | Ecto.Changeset.t()}
  def update_settings(scope, task_key, attrs) when is_binary(task_key) and is_map(attrs) do
    limits = attrs |> fetch(:limits) |> normalize_scoped()

    with :ok <- Guard.authorize_manage(scope),
         {:ok, spec} <- declared_spec(task_key),
         :ok <- if(limits.user == %{}, do: :ok, else: user_scope(spec)) do
      setting = settings(task_key) || %TaskSetting{task_key: task_key}
      limits = limits |> stringify_scoped() |> keep_stored_user(spec, setting)

      setting
      |> Ecto.Changeset.change(%{
        limits: limits,
        warn_percent: percent(fetch(attrs, :warn_percent)),
        updated_by_uuid: Guard.actor_uuid(scope)
      })
      |> Ecto.Changeset.validate_number(:warn_percent,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 100
      )
      |> Ecto.Changeset.unique_constraint(:task_key)
      |> repo().insert_or_update()
      |> changed(task_key)
      |> log("guard.limits_updated", scope, fn row ->
        %{
          "task" => task_key,
          "limits" => row.limits,
          "limits_before" => setting.limits || %{},
          "warn_percent" => row.warn_percent,
          "warn_percent_before" => setting.warn_percent
        }
      end)
    end
  end

  # A task without the user scope keeps the user values stored before, as
  # they are.
  defp keep_stored_user(limits, %TaskSpec{user_limits: false}, %TaskSetting{
         limits: %{"user" => user}
       }),
       do: Map.put(limits, "user", user)

  defp keep_stored_user(limits, _spec, _setting), do: limits

  @doc """
  Sets a task's guard mode: `"self_flag"` (its consumer has the model flag
  off-purpose requests) or `"off"` — what `PhoenixKitAI.Guard.self_flag?/1`
  answers from then on, in place of the declaration's `self_flag`. The
  limits stay as they are. Needs `ai.manage`; written to the Activity log.
  """
  @spec set_guard_mode(term(), String.t(), String.t()) ::
          {:ok, TaskSetting.t()}
          | {:error, :forbidden | :unknown_task | :invalid_mode | Ecto.Changeset.t()}
  def set_guard_mode(scope, task_key, mode) when is_binary(task_key) do
    with :ok <- Guard.authorize_manage(scope),
         :ok <- declared(task_key),
         :ok <- if(mode in @settable_modes, do: :ok, else: {:error, :invalid_mode}) do
      setting = settings(task_key) || %TaskSetting{task_key: task_key}

      setting
      |> Ecto.Changeset.change(%{guard_mode: mode, updated_by_uuid: Guard.actor_uuid(scope)})
      |> repo().insert_or_update()
      |> changed(task_key)
      |> log("guard.mode_updated", scope, fn row ->
        %{
          "task" => task_key,
          "guard_mode" => row.guard_mode,
          "guard_mode_before" => setting.guard_mode
        }
      end)
    end
  end

  @doc """
  Sets a user's personal limits in a task (`%{unit => %{period => amount}}`);
  with no amount left the exception is removed. Needs `ai.manage`; written to
  the Activity log. `{:error, :user_limits_off}` for a task declared with
  `user_limits: false`.
  """
  @spec put_user_limits(term(), String.t(), String.t(), map()) ::
          {:ok, TaskUserLimit.t() | :deleted}
          | {:error,
             :forbidden
             | :unknown_task
             | :user_limits_off
             | :invalid_user
             | :unknown_user
             | Ecto.Changeset.t()}
  def put_user_limits(scope, task_key, user_uuid, limits)
      when is_binary(task_key) and is_map(limits) do
    with :ok <- Guard.authorize_manage(scope),
         {:ok, spec} <- declared_spec(task_key),
         :ok <- user_scope(spec),
         {:ok, user_uuid} <- user(user_uuid) do
      case normalize(limits) do
        empty when empty == %{} -> delete_user_limits(scope, task_key, user_uuid)
        normalized -> upsert_user_limits(scope, task_key, user_uuid, normalized)
      end
    end
  end

  defp upsert_user_limits(scope, task_key, user_uuid, limits) do
    row =
      repo().get_by(TaskUserLimit, task_key: task_key, user_uuid: user_uuid) ||
        %TaskUserLimit{task_key: task_key, user_uuid: user_uuid}

    before = row.limits || %{}

    row
    |> Ecto.Changeset.change(%{limits: stringify(limits)})
    |> Ecto.Changeset.unique_constraint([:task_key, :user_uuid])
    |> Ecto.Changeset.foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_ai_task_user_limits_user_uuid_fkey
    )
    |> repo().insert_or_update()
    |> changed(task_key)
    |> log("guard.user_limits_updated", scope, fn row ->
      %{
        "task" => task_key,
        "user_uuid" => user_uuid,
        "limits" => row.limits,
        "limits_before" => before
      }
    end)
  end

  @doc "Removes a user's personal limits in a task. Needs `ai.manage`; written to the Activity log."
  @spec delete_user_limits(term(), String.t(), String.t()) ::
          {:ok, :deleted} | {:error, :forbidden | :invalid_user | :unknown_user}
  def delete_user_limits(scope, task_key, user_uuid) when is_binary(task_key) do
    with :ok <- Guard.authorize_manage(scope),
         {:ok, user_uuid} <- user(user_uuid) do
      TaskUserLimit
      |> repo().get_by(task_key: task_key, user_uuid: user_uuid)
      |> remove_user_limits(scope)
    end
  end

  defp remove_user_limits(nil, _scope), do: {:ok, :deleted}

  defp remove_user_limits(%TaskUserLimit{} = row, scope) do
    {:ok, _} =
      row
      |> repo().delete()
      |> changed(row.task_key)
      |> log("guard.user_limits_deleted", scope, fn row ->
        %{"task" => row.task_key, "user_uuid" => row.user_uuid, "limits_before" => row.limits}
      end)

    {:ok, :deleted}
  end

  @doc """
  Forgives the `limit_scope` (`:task`, or `:user` with `user_uuid`) limit of
  `period` from `now`: its count starts again from then to the end of the
  window. Kept as a `limit_forgiven` event. Needs `ai.manage`. A user's
  limit is `{:error, :user_limits_off}` for a task declared with
  `user_limits: false`.
  """
  @spec forgive(term(), String.t(), scope(), period(), String.t() | nil, DateTime.t()) ::
          {:ok, GuardEvent.t()} | {:error, term()}
  def forgive(scope, task_key, limit_scope, period, user_uuid, now \\ DateTime.utc_now())
      when is_binary(task_key) do
    with :ok <- Guard.authorize_manage(scope),
         {:ok, spec} <- declared_spec(task_key),
         {:ok, limit_scope} <- known(limit_scope, @scopes),
         :ok <- if(limit_scope == :user, do: user_scope(spec), else: :ok),
         {:ok, period} <- known(period, @periods),
         {:ok, user_uuid} <- forgiven_user(limit_scope, user_uuid) do
      GuardEvents.limit_forgiven(
        task_key,
        user_uuid,
        limit_scope,
        period,
        Guard.actor_uuid(scope),
        now
      )
    else
      :error -> {:error, :invalid}
      other -> other
    end
  end

  defp forgiven_user(:task, _user_uuid), do: {:ok, nil}
  defp forgiven_user(:user, user_uuid), do: user(user_uuid)

  defp declared(task_key) do
    with {:ok, _spec} <- declared_spec(task_key), do: :ok
  end

  defp declared_spec(task_key) do
    case Tasks.get(task_key) do
      nil -> {:error, :unknown_task}
      spec -> {:ok, spec}
    end
  end

  defp user_scope(%TaskSpec{user_limits: false}), do: {:error, :user_limits_off}
  defp user_scope(%TaskSpec{}), do: :ok

  # A uuid of a user that exists; a uuid of nobody is `:unknown_user`, not a
  # foreign-key error later.
  defp user(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_uuid),
         true <- repo().exists?(from(u in User, where: u.uuid == ^uuid)) do
      {:ok, uuid}
    else
      :error -> {:error, :invalid_user}
      false -> {:error, :unknown_user}
    end
  end

  defp percent(value) when value in [nil, ""], do: nil
  defp percent(value) when is_integer(value), do: value

  defp percent(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> -1
    end
  end

  defp percent(_value), do: -1

  defp stringify_scoped(limits),
    do: Map.new(limits, fn {scope, cells} -> {Atom.to_string(scope), stringify(cells)} end)

  # Money as a dollar string (a JSON number would read back as a float, or,
  # whole, as the released millionths); counts as numbers.
  defp stringify(limits) do
    Map.new(limits, fn {unit, periods} ->
      {Atom.to_string(unit),
       Map.new(periods, fn {p, amount} -> {Atom.to_string(p), stored(amount)} end)}
    end)
  end

  defp stored(%Decimal{} = dollars), do: Money.to_json(dollars)
  defp stored(amount), do: amount

  defp log({:ok, row} = result, action, scope, metadata) do
    PhoenixKit.Activity.log("ai", action,
      actor_uuid: Guard.actor_uuid(scope),
      resource_type: "ai_task_limits",
      resource_uuid: row.uuid,
      metadata: metadata.(row)
    )

    result
  end

  defp log(result, _action, _scope, _metadata), do: result

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
