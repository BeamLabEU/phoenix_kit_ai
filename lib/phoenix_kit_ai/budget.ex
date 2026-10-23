defmodule PhoenixKitAI.Budget do
  @moduledoc """
  Spend caps over the trailing 24 hours, checked before every provider call.

  Usage rows already carry cost, endpoint and user; a cap is a sum over
  the trailing day plus a refusal. Three scopes, each a module setting in US
  dollars (a decimal string, `"5"` or `"0.10"`) where `0` or blank means no
  cap; the usage rows' `cost` is summed and compared as it is:

  | setting | scope |
  |---|---|
  | `ai_daily_cap` | every call the module makes |
  | `ai_daily_cap_per_endpoint` | calls on one endpoint |
  | `ai_daily_cap_per_user` | calls attributed to a `user_uuid:` |

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
  window is rolling, not a calendar day: spend from 23:00 still counts at
  09:00. The check reads the usage table; there is no reservation, so
  concurrent callers can overshoot by their in-flight calls. It also fails
  open — a database error reads as zero spend and no cap — because the
  module would otherwise refuse everything on a blip.

  The per-user cap only bites when the caller passes `user_uuid:`, and the
  value must be a PhoenixKit user uuid (the usage row has a foreign key on
  it; a row with an unknown user is written without it, with a warning, so
  it counts toward no user). Anonymous visitors cannot be capped individually; cap the
  endpoint or the site instead.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitAI.{Endpoint, Money, Request}

  @scopes [:global, :endpoint, :user, :user_calls]
  @money_scopes [:global, :endpoint, :user]
  @user_scopes [:user, :user_calls]
  @settings %{
    global: "ai_daily_cap",
    endpoint: "ai_daily_cap_per_endpoint",
    user: "ai_daily_cap_per_user",
    user_calls: "ai_daily_calls_per_user"
  }
  # The released versions' money caps, integer millionths of a dollar.
  @legacy_settings %{
    global: "ai_daily_budget",
    endpoint: "ai_daily_budget_per_endpoint",
    user: "ai_daily_budget_per_user"
  }
  @warn_setting "ai_budget_warn_percent"
  @default_warn_percent 80
  @window_seconds 24 * 60 * 60

  @type scope :: :global | :endpoint | :user | :user_calls
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
  only when `user_uuid:` is given), with no side effects — hosts show it,
  `check/2` acts on it. Takes an endpoint struct or uuid. Money is dollars
  (`Decimal`), `:user_calls` a count. A scope still in the released versions'
  settings only is left out (`check/2` refuses on it).
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
      spent = spent(scope, endpoint, user_uuid)
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
  # Forgets every "already warned" flag (tests).
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
    keys = Map.values(@settings) ++ Map.values(@legacy_settings) ++ [@warn_setting]
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

      scope ->
        {scope, money_limit(values[@settings[scope]], values[@legacy_settings[scope]])}
    end)
  end

  # The new key decides when it is there; only when it is missing does an old
  # key that still holds a cap mean the migration has not run.
  defp money_limit(value, legacy) when value in [nil, ""] do
    if Money.legacy_amount?(legacy), do: :unmigrated, else: Decimal.new(0)
  end

  defp money_limit(value, _legacy) do
    case Money.to_decimal(value) do
      {:ok, dollars} -> if Decimal.negative?(dollars), do: Decimal.new(0), else: dollars
      :error -> Decimal.new(0)
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

  # Dollars spent in the trailing window (a nil cost counts as zero), or for
  # :user_calls the number of calls.
  defp spent(scope, endpoint, user_uuid) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    if scope == :user_calls,
      do: calls(since, user_uuid),
      else: money(scope, since, endpoint, user_uuid)
  rescue
    _ -> if scope == :user_calls, do: 0, else: Decimal.new(0)
  catch
    :exit, _ -> if scope == :user_calls, do: 0, else: Decimal.new(0)
  end

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
        :endpoint -> where(query, [r], r.endpoint_uuid == ^endpoint.uuid)
        :user -> where(query, [r], r.user_uuid == ^user_uuid)
      end

    query |> PhoenixKit.RepoHelper.repo().one() |> Money.sum()
  end

  # Warn once per crossing: the flag is an ETS row per scope key and clears
  # when spend drops back under the line (a new day).
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
          "[PhoenixKitAI] budget #{scope} at #{percent}% (#{show(spent)} of #{show(limit)} in 24h)"
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

  defp show(%Decimal{} = dollars), do: "$" <> Decimal.to_string(dollars, :normal)
  defp show(calls), do: "#{calls} calls"

  defp measure(%Decimal{} = dollars), do: Decimal.to_float(dollars)
  defp measure(calls), do: calls

  defp scope_id(:global, _endpoint, _user), do: :all
  defp scope_id(:endpoint, endpoint, _user), do: endpoint.uuid
  defp scope_id(:user, _endpoint, user), do: user
  defp scope_id(:user_calls, _endpoint, user), do: user
end
