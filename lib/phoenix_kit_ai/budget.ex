defmodule PhoenixKitAI.Budget do
  @moduledoc """
  Spend caps over the trailing 24 hours, checked before every provider call.

  Usage rows already carry cost, endpoint and user; a cap is a sum over
  the trailing day plus a refusal. Three scopes, each a module setting in
  the unit of the `cost_cents` column (millionths of a dollar — the module
  calls them nanodollars; `1_000_000` = $1) where `0` means no cap:

  | setting | scope |
  |---|---|
  | `ai_daily_budget` | every call the module makes |
  | `ai_daily_budget_per_endpoint` | calls on one endpoint |
  | `ai_daily_budget_per_user` | calls attributed to a `user_uuid:` |

  `ai_budget_warn_percent` (default 80) marks when a scope is close: the
  call still runs, but a `Logger.warning` and a
  `[:phoenix_kit_ai, :budget, :warning]` telemetry event fire once per
  crossing per scope (the flag clears when spend drops back under the
  line).

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
  it; a row with an unknown user is not written and is logged as a
  warning). Anonymous visitors cannot be capped individually; cap the
  endpoint or the site instead.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitAI.{Endpoint, Request}

  @scopes [:global, :endpoint, :user]
  @settings %{
    global: "ai_daily_budget",
    endpoint: "ai_daily_budget_per_endpoint",
    user: "ai_daily_budget_per_user"
  }
  @warn_setting "ai_budget_warn_percent"
  @default_warn_percent 80
  @window_seconds 24 * 60 * 60

  @type scope :: :global | :endpoint | :user
  @type status :: %{
          scope: scope(),
          spent: non_neg_integer(),
          limit: non_neg_integer(),
          remaining: integer()
        }

  @doc "The setting key for a scope's cap."
  @spec setting(scope()) :: String.t()
  def setting(scope) when scope in @scopes, do: Map.fetch!(@settings, scope)

  @doc """
  `:ok` when every configured cap has room, `{:error, {:budget_exceeded,
  scope}}` for the first scope that is reached. Emits the warning for
  scopes past the warn percent; `status/2` does not.
  """
  @spec check(Endpoint.t(), keyword()) :: :ok | {:error, {:budget_exceeded, scope()}}
  def check(%Endpoint{} = endpoint, opts) do
    entries = status(endpoint, opts)
    Enum.each(entries, &maybe_warn(&1, endpoint, opts[:user_uuid]))

    case Enum.find(entries, &(&1.remaining <= 0)) do
      %{scope: scope} -> {:error, {:budget_exceeded, scope}}
      nil -> :ok
    end
  end

  @doc """
  Spent / limit / remaining for every scope that has a cap (the user scope
  only when `user_uuid:` is given), with no side effects — hosts show it,
  `check/2` acts on it. Takes an endpoint struct or uuid.
  """
  @spec status(Endpoint.t() | String.t(), keyword()) :: [status()]
  def status(endpoint_uuid, opts) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint -> status(endpoint, opts)
      _ -> []
    end
  end

  def status(%Endpoint{} = endpoint, opts) do
    user_uuid = opts[:user_uuid]
    limits = limits()

    for scope <- @scopes,
        limit = limits[scope],
        limit > 0,
        scope != :user or is_binary(user_uuid) do
      spent = spent(scope, endpoint, user_uuid)
      %{scope: scope, spent: spent, limit: limit, remaining: limit - spent}
    end
  end

  @doc "The cap for a scope in nanodollars (`0` = none)."
  @spec limit(scope()) :: non_neg_integer()
  def limit(scope) when scope in @scopes, do: limits()[scope]

  @doc "The warn threshold as a percentage of a cap (default 80)."
  @spec warn_percent() :: pos_integer()
  def warn_percent do
    case parse(settings()[@warn_setting]) do
      0 -> @default_warn_percent
      percent -> percent
    end
  end

  @doc "Sets a scope's cap (nanodollars; `0` removes it)."
  @spec set_limit(scope(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def set_limit(scope, nanodollars)
      when scope in @scopes and is_integer(nanodollars) and nanodollars >= 0 do
    PhoenixKit.Settings.update_setting_with_module(
      setting(scope),
      Integer.to_string(nanodollars),
      "ai"
    )
  end

  @doc false
  # Forgets every "already warned" flag (tests).
  @spec reset_warnings() :: :ok
  def reset_warnings do
    :ets.match_delete(PhoenixKitAI.RequestCache.flags_table(), {{__MODULE__, :_, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # One cached batch read for the four settings; the settings cache is
  # invalidated on every write, so `set_limit/2` takes effect at once.
  defp settings do
    keys = Map.values(@settings) ++ [@warn_setting]
    PhoenixKit.Settings.get_settings_cached(keys, %{})
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp limits do
    values = settings()
    Map.new(@settings, fn {scope, key} -> {scope, parse(values[key])} end)
  end

  defp parse(value) when is_integer(value) and value >= 0, do: value

  defp parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int >= 0 -> int
      _ -> 0
    end
  end

  defp parse(_other), do: 0

  # Nanodollars spent in the trailing window; a nil cost counts as zero.
  defp spent(scope, endpoint, user_uuid) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    # `"success"` must stay a literal, not `^status`: core (V193) indexes this
    # sum with partial indexes `WHERE status = 'success'`, and Postgres can only
    # use them when it can prove the query's condition matches — which it
    # cannot for a bound parameter once a prepared statement goes generic.
    query =
      from(r in Request,
        where: r.inserted_at >= ^since and r.status == "success",
        select: coalesce(sum(r.cost_cents), 0)
      )

    query =
      case scope do
        :global -> query
        :endpoint -> where(query, [r], r.endpoint_uuid == ^endpoint.uuid)
        :user -> where(query, [r], r.user_uuid == ^user_uuid)
      end

    # `sum(integer)` is a bigint on Postgres; the Decimal clause covers
    # other adapters.
    case PhoenixKit.RepoHelper.repo().one(query) do
      %Decimal{} = decimal -> decimal |> Decimal.round(0) |> Decimal.to_integer()
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # Warn once per crossing: the flag is an ETS row per scope key and clears
  # when spend drops back under the line (a new day).
  defp maybe_warn(%{spent: spent, limit: limit, scope: scope}, endpoint, user_uuid) do
    table = PhoenixKitAI.RequestCache.flags_table()
    key = {__MODULE__, scope, scope_id(scope, endpoint, user_uuid)}
    over? = spent * 100 >= limit * warn_percent()
    warned? = :ets.member(table, key)

    cond do
      over? and not warned? ->
        :ets.insert(table, {key, true})

        Logger.warning(
          "[PhoenixKitAI] budget #{scope} at #{div(spent * 100, max(limit, 1))}% (#{spent} of #{limit} nanodollars in 24h)"
        )

        :telemetry.execute(
          [:phoenix_kit_ai, :budget, :warning],
          %{spent: spent, limit: limit},
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

  defp scope_id(:global, _endpoint, _user), do: :all
  defp scope_id(:endpoint, endpoint, _user), do: endpoint.uuid
  defp scope_id(:user, _endpoint, user), do: user
end
