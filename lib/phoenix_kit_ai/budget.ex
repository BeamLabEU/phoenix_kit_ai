defmodule PhoenixKitAI.Budget do
  @moduledoc """
  Spend caps over the trailing 24 hours and the current calendar month,
  checked before every provider call.

  Usage rows already carry cost, endpoint and user; a cap is a sum over
  a window plus a refusal. Four scopes, each a module setting in US
  dollars (a decimal string, `"5"` or `"0.10"`) where `0` or blank means no
  cap; the usage rows' `cost` is summed and compared as it is:

  | setting | scope | window |
  |---|---|---|
  | `ai_daily_cap` | every call the module makes (`:global`) | trailing 24 hours |
  | `ai_monthly_cap` | every call the module makes (`:global_month`) | calendar month |
  | `ai_daily_cap_per_endpoint` | calls on one endpoint (`:endpoint`) | trailing 24 hours |
  | `ai_daily_cap_per_user` | calls attributed to a `user_uuid:` (`:user`) | trailing 24 hours |

  The monthly cap is the same sum as the global daily one over a longer
  window: from the local midnight that starts the current month to now, in
  the site time zone (Settings → `time_zone`; the month window of
  `PhoenixKitAI.TaskLimits.windows/2`). It is calendar, not rolling: it
  starts again at zero on the first of the month. Both site-wide caps can be
  set together ("$8 a day, $100 a month"); whichever is reached first refuses.
  A value that is set but not a number reads as no cap, with a warning (once
  per node).

  Because it scans a month of rows, the monthly sum is reused for 30 seconds
  (`config :phoenix_kit_ai, budget_month_cache_ttl: milliseconds`, `0` =
  off), except between the warn percent and the cap, where every check scans:
  spend can pass the cap by 30 seconds of calls only while it is far below it.
  When the scan fails, the last good sum of the month is used (zero if there
  is none) and calls do not scan again for 5 seconds.

  The released versions kept these caps under `ai_daily_budget*` in integer
  millionths of a dollar (`"5000000"` was $5). The module's migration chain
  copies them to the keys above in dollars and leaves the old keys alone. A
  scope whose old key is still set while its new key is missing (the migration
  has not run) refuses every call with `{:error, {:budget_unmigrated, scope}}`
  rather than read millionths as dollars, which would loosen the cap a million
  times over.

  Beside the money, `ai_daily_calls_per_user` caps how many calls one user
  may make in the same trailing day (a count, `0` = no cap; scope
  `:user_calls`). A cheap model makes a money cap meaningless as a limit on
  how much one person can use, and a count says it directly.

  It counts **successful** calls (cached answers included — each writes a
  zero-cost success row); failed provider calls cost nothing and do not
  count. Like the money cap it reads the usage rows by `user_uuid`, so a
  `user_uuid:` that is not a PhoenixKit user (its rows are written
  unattributed, with a warning) is never capped — pass real user uuids.

  `ai_budget_warn_percent` (default 80) marks when a scope is close: the
  call still runs, but a `Logger.warning` and a
  `[:phoenix_kit_ai, :budget, :warning]` telemetry event fire once per
  crossing per scope (the flag clears when spend drops back under the
  line). Its `spent` / `limit` measurements are in the scope's unit: dollars
  (floats — a measurement must be a number), or a call count for
  `:user_calls` — check the `scope` metadata before adding them up.

  Once a cap is reached every verb returns `{:error, {:budget_exceeded,
  scope}}` without a provider call — cached answers included: a cap is a
  stop switch, so a runaway site goes quiet rather than half-quiet. The
  daily windows are rolling, not a calendar day: spend from 23:00 still
  counts at 09:00. The check reads the usage table; there is no reservation, so
  concurrent callers can overshoot by their in-flight calls. It also fails
  open — a database error reads as zero spend and no cap (for the monthly cap,
  as the last good sum) — because the module would otherwise refuse everything
  on a blip. A warning names the exception, once per outage per scope per node.

  The per-user cap only bites when the caller passes `user_uuid:`, and the
  value must be a PhoenixKit user uuid (the usage row has a foreign key on
  it; a row with an unknown user is written without it, with a warning, so
  it counts toward no user). Anonymous visitors cannot be capped individually; cap the
  endpoint or the site instead.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitAI.{Endpoint, Money, Request}

  @scopes [:global, :global_month, :endpoint, :user, :user_calls]
  @money_scopes [:global, :global_month, :endpoint, :user]
  @user_scopes [:user, :user_calls]
  @settings %{
    global: "ai_daily_cap",
    global_month: "ai_monthly_cap",
    endpoint: "ai_daily_cap_per_endpoint",
    user: "ai_daily_cap_per_user",
    user_calls: "ai_daily_calls_per_user"
  }
  # The released versions' money caps, integer millionths of a dollar. The
  # monthly cap is newer than the move to dollars and has no old key.
  @legacy_settings %{
    global: "ai_daily_budget",
    endpoint: "ai_daily_budget_per_endpoint",
    user: "ai_daily_budget_per_user"
  }
  @warn_setting "ai_budget_warn_percent"
  @zone_setting "time_zone"
  # How long the month's spend sum is reused: the sum scans a whole month of
  # rows, which a busy site cannot afford on every call.
  @month_cache_ttl_ms 30_000
  # After a failed month scan, how long calls stop retrying it (they serve the
  # last good sum, or zero) instead of each running the slow query again.
  @month_failure_backoff_ms 5_000
  @default_warn_percent 80
  @window_seconds 24 * 60 * 60

  @type scope :: :global | :global_month | :endpoint | :user | :user_calls
  @typedoc "Dollars (a `Decimal`) for a money scope, a call count for `:user_calls`."
  @type amount :: Decimal.t() | non_neg_integer()
  @type status :: %{
          scope: scope(),
          spent: amount(),
          limit: amount(),
          remaining: Decimal.t() | integer()
        }

  @doc "The setting key for a scope's cap."
  @spec setting(scope()) :: String.t()
  def setting(scope) when scope in @scopes, do: Map.fetch!(@settings, scope)

  @doc "The settings keys the released versions kept the money caps under (millionths)."
  @spec legacy_settings() :: %{scope() => String.t()}
  def legacy_settings, do: @legacy_settings

  @doc """
  `:ok` when every configured cap has room, `{:error, {:budget_exceeded,
  scope}}` for the first scope that is reached, `{:error, {:budget_unmigrated,
  scope}}` for a cap still in the released versions' settings only. Emits the
  warning for scopes past the warn percent; `status/2` does not.
  """
  @spec check(Endpoint.t(), keyword()) ::
          :ok | {:error, {:budget_exceeded | :budget_unmigrated, scope()}}
  def check(%Endpoint{} = endpoint, opts) do
    limits = limits()

    case Enum.find(@money_scopes, &(limits[&1] == :unmigrated)) do
      nil ->
        entries = status(endpoint, opts, limits)
        Enum.each(entries, &maybe_warn(&1, endpoint, opts[:user_uuid]))

        case Enum.find(entries, &reached?/1) do
          %{scope: scope} -> {:error, {:budget_exceeded, scope}}
          nil -> :ok
        end

      scope ->
        log_unmigrated(scope)
        {:error, {:budget_unmigrated, scope}}
    end
  end

  @doc """
  Spent / limit / remaining for every scope that has a cap (the user scope
  only when `user_uuid:` is given), with no warnings or refusals — hosts show
  it, `check/2` acts on it. It fills the monthly sum's cache and reads through
  it: the monthly `:global_month` spend can be up to 30 seconds old, unless it
  is between the warn percent and the cap. Takes an endpoint struct or uuid.
  Money is dollars (`Decimal`), `:user_calls` a count. A scope still in the
  released versions' settings only is left out (`check/2` refuses on it).
  """
  @spec status(Endpoint.t() | String.t(), keyword()) :: [status()]
  def status(endpoint_uuid, opts) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint -> status(endpoint, opts)
      _ -> []
    end
  end

  def status(%Endpoint{} = endpoint, opts), do: status(endpoint, opts, limits())

  defp status(endpoint, opts, limits) do
    user_uuid = opts[:user_uuid]

    for scope <- @scopes,
        limit = limits[scope],
        positive?(limit),
        scope not in @user_scopes or is_binary(user_uuid) do
      spent = spent(scope, endpoint, user_uuid, limit)
      %{scope: scope, spent: spent, limit: limit, remaining: subtract(limit, spent)}
    end
  end

  @doc """
  The cap for a scope: dollars (`Decimal`) for a money scope, a call count for
  `:user_calls`; `0` = none (also for a cap not migrated yet).
  """
  @spec limit(scope()) :: amount()
  def limit(scope) when scope in @scopes do
    case limits()[scope] do
      :unmigrated -> Decimal.new(0)
      limit -> limit
    end
  end

  @doc "The warn threshold as a percentage of a cap (default 80)."
  @spec warn_percent() :: pos_integer()
  def warn_percent do
    case count(settings()[@warn_setting]) do
      0 -> @default_warn_percent
      percent -> percent
    end
  end

  @doc """
  Sets a scope's cap: dollars for a money scope — a `Decimal` or a dollar
  string (`"5"`, `"0.10"`) — or a call count for `:user_calls`; `0` removes
  it. A money cap given as any other integer or as a float is refused with
  `{:error, :ambiguous_amount}`: the released API took integer millionths of a
  dollar, and `set_limit(:global, 5_000_000)` must not become a $5,000,000 cap.
  """
  @spec set_limit(scope(), Decimal.t() | String.t() | non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def set_limit(:user_calls, amount) when is_integer(amount) and amount >= 0,
    do: write(:user_calls, Integer.to_string(amount))

  def set_limit(scope, amount) when scope in @money_scopes do
    case Money.amount(amount) do
      {:ok, dollars} -> write(scope, Money.to_json(dollars))
      {:error, :ambiguous_amount} = error -> error
      :error -> {:error, :invalid_amount}
    end
  end

  def set_limit(_scope, _amount), do: {:error, :invalid_amount}

  defp write(scope, value),
    do: PhoenixKit.Settings.update_setting_with_module(setting(scope), value, "ai")

  @doc false
  # Forgets every "already warned" flag (tests). The pattern also matches the
  # other `{Budget, key, id}` entries in the flags table: the month's cached
  # sum and its failure backoff, the read-failure flags and the unparsable-cap
  # note, so this resets all of them.
  @spec reset_warnings() :: :ok
  def reset_warnings do
    :ets.match_delete(PhoenixKitAI.RequestCache.flags_table(), {{__MODULE__, :_, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # One cached batch read for the settings; the settings cache is
  # invalidated on every write, so `set_limit/2` takes effect at once.
  defp settings do
    keys =
      Map.values(@settings) ++ Map.values(@legacy_settings) ++ [@warn_setting, @zone_setting]

    PhoenixKit.Settings.get_settings_cached(keys, %{})
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # scope => dollars (`Decimal`) | count | `:unmigrated`
  defp limits do
    values = settings()

    Map.new(@scopes, fn
      :user_calls ->
        {:user_calls, count(values[@settings.user_calls])}

      :global_month ->
        value = values[@settings.global_month]
        log_unparsable(:global_month, value)
        {:global_month, money_limit(value, nil)}

      scope ->
        {scope, money_limit(values[@settings[scope]], values[@legacy_settings[scope]])}
    end)
  end

  # The new key decides when it holds an amount; when it is missing, blank or
  # not a number, an old key that still holds a cap means the migration has
  # not run (a hand-edited blank must not drop the cap).
  defp money_limit(value, legacy) do
    case Money.to_decimal(value) do
      {:ok, dollars} ->
        if Decimal.negative?(dollars), do: Decimal.new(0), else: dollars

      :error ->
        if Money.legacy_amount?(legacy), do: :unmigrated, else: Decimal.new(0)
    end
  end

  defp count(value) when is_integer(value) and value >= 0, do: value

  defp count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int >= 0 -> int
      _ -> 0
    end
  end

  defp count(_other), do: 0

  defp positive?(%Decimal{} = amount), do: Decimal.compare(amount, 0) == :gt
  defp positive?(amount) when is_integer(amount), do: amount > 0
  defp positive?(_), do: false

  defp subtract(%Decimal{} = limit, spent), do: Decimal.sub(limit, spent)
  defp subtract(limit, spent), do: limit - spent

  defp reached?(%{remaining: %Decimal{} = remaining}), do: Decimal.compare(remaining, 0) != :gt
  defp reached?(%{remaining: remaining}), do: remaining <= 0

  # A cap that is set but not a number reads as no cap (fail open), so say so:
  # once per node and per distinct bad value (compared by hash, so the value
  # itself is not kept or logged). Blank is "no cap" on purpose.
  defp log_unparsable(scope, value) do
    if is_binary(value) and String.trim(value) != "" and Money.to_decimal(value) == :error do
      table = PhoenixKitAI.RequestCache.flags_table()
      key = {__MODULE__, :unparsable, scope}
      hash = :erlang.phash2(value)

      if :ets.lookup(table, key) != [{key, hash}] do
        :ets.insert(table, {key, hash})

        Logger.warning(
          "[PhoenixKitAI] #{@settings[scope]} is set but is not a number: the #{scope} " <>
            "spend cap is NOT enforced until it is a dollar amount such as \"100\" or \"0.10\""
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # Once per node, not on every refused call.
  defp log_unmigrated(scope) do
    key = {__MODULE__, :unmigrated, scope}
    table = PhoenixKitAI.RequestCache.flags_table()

    unless :ets.member(table, key) do
      :ets.insert(table, {key, true})

      Logger.error(
        "[PhoenixKitAI] the #{scope} spend cap is still in #{@legacy_settings[scope]} " <>
          "(millionths of a dollar) and not in #{@settings[scope]} (dollars): every AI call " <>
          "is refused until `mix phoenix_kit.update` has run the module's migrations"
      )
    end
  rescue
    _ -> :ok
  end

  # Dollars spent in the scope's window (a nil cost counts as zero), or for
  # :user_calls the number of calls. Only the read is shielded: the window is
  # computed outside, and a failing read is logged (once per outage per scope
  # per node) and reads as nothing spent. The month's sum handles its own
  # failures (`month_sum/3`): it falls back to the last good sum.
  defp spent(scope, endpoint, user_uuid, limit),
    do: read_spent(scope, window_start(scope), endpoint, user_uuid, limit)

  defp read_spent(:global_month, since, endpoint, user_uuid, limit) do
    guarded(:global_month, fn ->
      month_sum(since, limit, fn -> money(:global_month, since, endpoint, user_uuid) end)
    end)
  end

  defp read_spent(:user_calls, since, _endpoint, user_uuid, _limit),
    do: read(:user_calls, fn -> calls(since, user_uuid) end)

  defp read_spent(scope, since, endpoint, user_uuid, _limit),
    do: read(scope, fn -> money(scope, since, endpoint, user_uuid) end)

  @doc false
  # A database read of `scope`: its value, with the scope's read-failure flag
  # cleared; a failure is logged and reads as nothing spent. Only a real
  # database read belongs here — a sum served from the month cache proves
  # nothing about the database, and another scope's read proves nothing about
  # this one.
  def read(scope, fun), do: guarded(scope, fn -> fun.() |> read_ok(scope) end)

  defp guarded(scope, fun) do
    fun.()
  rescue
    error -> read_failed(scope, inspect(error.__struct__))
  catch
    :exit, _ -> read_failed(scope, "exit")
  end

  defp read_failed(scope, class) do
    log_read_failed(scope, class)
    if scope == :user_calls, do: 0, else: Decimal.new(0)
  end

  # Once per outage per scope on this node, not on every call while the
  # database is down: the scope's flag clears on its next successful read, so a
  # later outage is logged again.
  defp log_read_failed(scope, class) do
    key = {__MODULE__, :read_failed, scope}
    table = PhoenixKitAI.RequestCache.flags_table()

    unless :ets.member(table, key) do
      :ets.insert(table, {key, true})

      Logger.warning(
        "[PhoenixKitAI] the #{scope} spend cap could not read the usage table (#{class}): " <>
          "the cap is not enforced on a fresh sum while reads fail " <>
          "(further failures of this scope are not logged on this node)"
      )
    end
  rescue
    _ -> :ok
  end

  # The flag is only written on a failure, so look before deleting: this runs
  # for every scope of every call, and a delete takes the table's write lock.
  defp read_ok(value, scope) do
    table = PhoenixKitAI.RequestCache.flags_table()
    key = {__MODULE__, :read_failed, scope}
    if :ets.member(table, key), do: :ets.delete(table, key)
    value
  rescue
    ArgumentError -> value
  end

  # The month's sum, reused for a short while. The key holds the month start,
  # so a new month (or another time zone) never sees the old sum. TTL 0, or
  # anything but a positive integer, turns the cache off (a bad TTL must not
  # raise and read as "nothing spent"); a failed read then reads as nothing
  # spent, like the other scopes.
  #
  # With the cache on:
  # - Between the warn percent and the cap the cache is bypassed: it exists
  #   for the stretch where the cap is far away (or already reached, where
  #   nothing more is spent), and an overshoot of a window of calls matters
  #   most just below the cap.
  # - A failed scan is never stored as a sum. The last good sum of the same
  #   month (even an expired one) is served instead, or zero when there is
  #   none, and for a few seconds calls do not scan again.
  # - At expiry every concurrent caller scans (no single-flight: it would need
  #   a lock that a crashed caller can leave behind, and the scan is skipped
  #   anyway on most calls).
  @doc false
  def month_sum(since, limit, fun) do
    ttl = Application.get_env(:phoenix_kit_ai, :budget_month_cache_ttl, @month_cache_ttl_ms)

    if is_integer(ttl) and ttl > 0 do
      table = PhoenixKitAI.RequestCache.flags_table()
      now = System.monotonic_time(:millisecond)
      entry = cache_read(table, since)

      if fresh_entry?(entry, now, limit),
        do: elem(entry, 0),
        else: scan_month(table, since, ttl, entry, fun)
    else
      fun.() |> read_ok(:global_month)
    end
  end

  defp fresh_entry?({sum, expires_at}, now, limit), do: expires_at > now and settled?(sum, limit)
  defp fresh_entry?(nil, _now, _limit), do: false

  # Far from the cap (under the warn percent) or at it: a stale sum costs
  # nothing.
  defp settled?(sum, limit) do
    threshold = Decimal.div(Decimal.mult(limit, warn_percent()), 100)
    Decimal.lt?(sum, threshold) or not Decimal.lt?(sum, limit)
  end

  defp scan_month(table, since, ttl, entry, fun) do
    if backing_off?(table, since) do
      stale_sum(entry)
    else
      case run_scan(fun) do
        {:ok, sum} ->
          read_ok(sum, :global_month)
          cache_write(table, since, sum, ttl)
          sum

        {:failed, class} ->
          backoff_write(table, since)
          log_read_failed(:global_month, class)
          stale_sum(entry)
      end
    end
  end

  defp run_scan(fun) do
    {:ok, fun.()}
  rescue
    error -> {:failed, inspect(error.__struct__)}
  catch
    :exit, _ -> {:failed, "exit"}
  end

  defp stale_sum({sum, _expires_at}), do: sum
  defp stale_sum(nil), do: Decimal.new(0)

  defp cache_read(table, since) do
    case :ets.lookup(table, {__MODULE__, :month_spent, since}) do
      [{_key, {sum, expires_at}}] -> {sum, expires_at}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp backing_off?(table, since) do
    case :ets.lookup(table, {__MODULE__, :month_failed, since}) do
      [{_key, until}] -> until > System.monotonic_time(:millisecond)
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp backoff_write(table, since) do
    until = System.monotonic_time(:millisecond) + @month_failure_backoff_ms
    :ets.insert(table, {{__MODULE__, :month_failed, since}, until})
  rescue
    ArgumentError -> true
  end

  # Entries for other month starts are dead weight: drop them. A good scan
  # also ends a backoff.
  defp cache_write(table, since, sum, ttl) do
    :ets.select_delete(table, [
      {{{__MODULE__, :month_spent, :"$1"}, :_}, [{:"=/=", :"$1", {:const, since}}], [true]}
    ])

    :ets.delete(table, {__MODULE__, :month_failed, since})

    :ets.insert(
      table,
      {{__MODULE__, :month_spent, since}, {sum, System.monotonic_time(:millisecond) + ttl}}
    )
  rescue
    ArgumentError -> true
  end

  # The monthly cap counts from the start of the site's calendar month, the
  # window `TaskLimits` uses; the others look at the trailing 24 hours.
  defp window_start(:global_month) do
    zone = settings()[@zone_setting] || "0"
    PhoenixKitAI.TaskLimits.windows(DateTime.utc_now(), zone).month |> elem(0)
  end

  defp window_start(_scope), do: DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

  # Successful calls only, like the money sum: a failed call costs nothing
  # and is not the user's doing. Same literal status, same partial index.
  defp calls(since, user_uuid) do
    from(r in Request,
      where: r.inserted_at >= ^since and r.status == "success" and r.user_uuid == ^user_uuid,
      select: count(r.uuid)
    )
    |> PhoenixKit.RepoHelper.repo().one()
    |> Kernel.||(0)
  end

  defp money(scope, since, endpoint, user_uuid) do
    # `"success"` must stay a literal, not `^status`: core (V193) indexes this
    # sum with partial indexes `WHERE status = 'success'`, and Postgres can only
    # use them when it can prove the query's condition matches — which it
    # cannot for a bound parameter once a prepared statement goes generic.
    query =
      from(r in Request,
        where: r.inserted_at >= ^since and r.status == "success",
        select: coalesce(sum(r.cost), 0)
      )

    query =
      case scope do
        :global -> query
        :global_month -> query
        :endpoint -> where(query, [r], r.endpoint_uuid == ^endpoint.uuid)
        :user -> where(query, [r], r.user_uuid == ^user_uuid)
      end

    query |> PhoenixKit.RepoHelper.repo().one() |> Money.sum()
  end

  # Warn once per crossing: the flag is an ETS row per scope key and clears
  # when spend drops back under the line (a new day, or month).
  defp maybe_warn(%{spent: spent, limit: limit, scope: scope}, endpoint, user_uuid) do
    table = PhoenixKitAI.RequestCache.flags_table()
    key = {__MODULE__, scope, scope_id(scope, endpoint, user_uuid)}
    percent = percent_of(spent, limit)
    over? = percent >= warn_percent()
    warned? = :ets.member(table, key)

    cond do
      over? and not warned? ->
        :ets.insert(table, {key, true})

        Logger.warning(
          "[PhoenixKitAI] budget #{scope} at #{percent}% " <>
            "(#{show(spent)} of #{show(limit)} #{window_label(scope)})"
        )

        :telemetry.execute(
          [:phoenix_kit_ai, :budget, :warning],
          %{spent: measure(spent), limit: measure(limit)},
          %{scope: scope, endpoint_uuid: endpoint.uuid, user_uuid: user_uuid}
        )

      not over? and warned? ->
        :ets.delete(table, key)

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # The whole percent of a cap spent, rounded down.
  defp percent_of(%Decimal{} = spent, limit) do
    spent
    |> Decimal.mult(100)
    |> Decimal.div(limit)
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  defp percent_of(spent, limit), do: div(spent * 100, max(limit, 1))

  defp window_label(:global_month), do: "this month"
  defp window_label(_scope), do: "in 24h"

  defp show(%Decimal{} = dollars), do: "$" <> Decimal.to_string(dollars, :normal)
  defp show(calls), do: "#{calls} calls"

  defp measure(%Decimal{} = dollars), do: Decimal.to_float(dollars)
  defp measure(calls), do: calls

  defp scope_id(:global, _endpoint, _user), do: :all
  defp scope_id(:global_month, _endpoint, _user), do: :all
  defp scope_id(:endpoint, endpoint, _user), do: endpoint.uuid
  defp scope_id(:user, _endpoint, user), do: user
  defp scope_id(:user_calls, _endpoint, user), do: user
end
