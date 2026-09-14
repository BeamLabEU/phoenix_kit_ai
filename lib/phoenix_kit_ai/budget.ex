defmodule PhoenixKitAI.Budget do
  @moduledoc """
  Spend caps over the last 24 hours, checked before every provider call.

  Usage rows already carry cost (nanodollars), endpoint and user; a cap is
  a sum over the trailing day plus a refusal. Three scopes, each a module
  setting in nanodollars where `0` means no cap:

  | setting | scope |
  |---|---|
  | `ai_daily_budget` | every call the module makes |
  | `ai_daily_budget_per_endpoint` | calls on one endpoint |
  | `ai_daily_budget_per_user` | calls a caller attributed to a `user_uuid:` |

  `ai_budget_warn_percent` (default 80) marks when a scope is close: the
  call still runs, but a `Logger.warning` and a
  `[:phoenix_kit_ai, :budget, :warning]` telemetry event fire once per
  crossing per scope.

  Above the cap every verb returns `{:error, {:budget_exceeded, scope}}`
  without a provider call. The per-user cap only bites when the caller
  passes `user_uuid:` — a public site that lets visitors trigger calls
  should always pass it.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitAI.Request

  @scopes [:global, :endpoint, :user]
  @settings %{
    global: "ai_daily_budget",
    endpoint: "ai_daily_budget_per_endpoint",
    user: "ai_daily_budget_per_user"
  }
  @warn_setting "ai_budget_warn_percent"
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
  scope}}` for the first scope that is spent. Emits the warning for scopes
  past the warn percent.
  """
  @spec check(PhoenixKitAI.Endpoint.t(), keyword()) :: :ok | {:error, {:budget_exceeded, scope()}}
  def check(endpoint, opts) do
    case Enum.find(status(endpoint, opts), &(&1.remaining < 0)) do
      %{scope: scope} ->
        {:error, {:budget_exceeded, scope}}

      nil ->
        :ok
    end
  end

  @doc """
  Spent / limit / remaining for every scope that has a cap (the user scope
  only when `user_uuid:` is given). Hosts show it; `check/2` acts on it.
  """
  @spec status(PhoenixKitAI.Endpoint.t(), keyword()) :: [status()]
  def status(endpoint, opts) do
    user_uuid = opts[:user_uuid]

    for scope <- @scopes,
        limit = limit(scope),
        limit > 0,
        scope != :user or is_binary(user_uuid) do
      spent = spent(scope, endpoint, user_uuid)
      entry = %{scope: scope, spent: spent, limit: limit, remaining: limit - spent}
      maybe_warn(entry, endpoint, user_uuid)
      entry
    end
  end

  @doc "The cap for a scope in nanodollars (`0` = none)."
  @spec limit(scope()) :: non_neg_integer()
  def limit(scope) when scope in @scopes do
    case PhoenixKit.Settings.get_setting(setting(scope), "0") do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse(value)
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "The warn threshold as a percentage of a cap (default 80)."
  @spec warn_percent() :: pos_integer()
  def warn_percent do
    case PhoenixKit.Settings.get_setting(@warn_setting, "80") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> max(parse(value), 1)
      _ -> 80
    end
  rescue
    _ -> 80
  catch
    :exit, _ -> 80
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

  defp parse(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int >= 0 -> int
      _ -> 0
    end
  end

  # Nanodollars spent in the trailing window; a nil cost counts as zero.
  defp spent(scope, endpoint, user_uuid) do
    since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

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

    case PhoenixKit.RepoHelper.repo().one(query) do
      nil -> 0
      %Decimal{} = decimal -> decimal |> Decimal.round(0) |> Decimal.to_integer()
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
    end
  rescue
    _ -> 0
  end

  # Warn once per crossing: the flag lives in persistent_term per scope key
  # and clears when spend drops back under the line (a new day).
  defp maybe_warn(%{spent: spent, limit: limit, scope: scope}, endpoint, user_uuid) do
    key = {__MODULE__, :warned, scope, scope_id(scope, endpoint, user_uuid)}
    over? = spent * 100 >= limit * warn_percent()

    cond do
      over? and not :persistent_term.get(key, false) ->
        :persistent_term.put(key, true)

        Logger.warning(
          "[PhoenixKitAI] budget #{scope} at #{div(spent * 100, max(limit, 1))}% (#{spent} of #{limit} nanodollars in 24h)"
        )

        :telemetry.execute(
          [:phoenix_kit_ai, :budget, :warning],
          %{spent: spent, limit: limit},
          %{scope: scope, endpoint_uuid: endpoint.uuid, user_uuid: user_uuid}
        )

      not over? and :persistent_term.get(key, false) ->
        :persistent_term.erase(key)

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
