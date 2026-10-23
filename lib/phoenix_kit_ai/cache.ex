defmodule PhoenixKitAI.Cache do
  @moduledoc """
  Short-lived node-local cache for the two lookups every provider call repeats:
  the endpoint row (`resolve_endpoint/1` by uuid) and its integration credentials
  (`PhoenixKit.Integrations.get_credentials/1` — a settings read plus a decrypt,
  done once to validate the endpoint and again to build the request headers).

  * **Endpoints** are dropped when the endpoint changes: `update_endpoint/3` and
    `delete_endpoint/2` invalidate on the calling node right away, and the
    `phoenix_kit:ai:endpoints` broadcast reaches the other nodes.
  * **Credentials** are dropped on any change announced on core's system
    integrations topic (`PhoenixKit.Integrations.Events`): setup saved,
    connected, disconnected, renamed, removed. A *personal* connection's changes
    are broadcast on a per-user topic this cache does not follow; for those the
    TTL is the bound.
  * Every entry also expires after a TTL (`config :phoenix_kit_ai,
    endpoint_cache_ttl:` / `credential_cache_ttl:`, seconds, default 300; `0`
    turns that cache off), so a missed broadcast heals itself.

  Credentials stay in this ETS table — never in a log line, a message or a
  broadcast. The table is `:public` (callers fill it), so any process on the
  node can read it; that is no wider than today, where any process on the
  node can call `PhoenixKit.Integrations.get_credentials/1` itself. Only `{:ok, _}` results are cached. Without the module's supervisor
  tree (`PhoenixKitAI.children/0`) every lookup goes straight to the source.
  """
  use GenServer
  require Logger

  alias PhoenixKit.Integrations.Events

  @table :phoenix_kit_ai_lookup_cache
  @default_ttl 300

  # ---- client ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The endpoint for `uuid` from the cache, or from `fun` (cached when `{:ok, _}`)."
  @spec endpoint(String.t(), (-> {:ok, term()} | term())) :: term()
  def endpoint(uuid, fun) when is_binary(uuid),
    do: fetch({:endpoint, uuid}, :endpoint_cache_ttl, fun)

  @doc "The credentials for an integration key from the cache, or from `fun`."
  @spec credentials(String.t(), (-> {:ok, map()} | term())) :: term()
  def credentials(key, fun) when is_binary(key),
    do: fetch({:credentials, key}, :credential_cache_ttl, fun)

  @doc "Drop one endpoint (on this node; other nodes follow the broadcast)."
  @spec invalidate_endpoint(String.t()) :: :ok
  def invalidate_endpoint(uuid) when is_binary(uuid) do
    if table?() do
      bump({:endpoint, uuid})
      :ets.delete(@table, {:endpoint, uuid})
    end

    :ok
  end

  def invalidate_endpoint(_), do: :ok

  @doc "Drop every cached credential."
  @spec invalidate_credentials() :: :ok
  def invalidate_credentials do
    if table?() do
      bump(:credentials)
      :ets.match_delete(@table, {{:credentials, :_}, :_, :_})
    end

    :ok
  end

  @doc "Drop everything (tests, or after an out-of-band change)."
  @spec clear() :: :ok
  def clear do
    if table?() do
      bump(:all)
      :ets.match_delete(@table, {{:endpoint, :_}, :_, :_})
      :ets.match_delete(@table, {{:credentials, :_}, :_, :_})
    end

    :ok
  end

  defp fetch(key, ttl_key, fun) do
    ttl = ttl(ttl_key)
    if ttl == 0 or not table?(), do: fun.(), else: lookup(key, ttl, fun)
  end

  defp lookup(key, ttl, fun) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, value, expires}] when expires > now ->
        value

      _ ->
        generation = generation(key)
        store(key, fun.(), now + ttl, generation)
    end
  end

  # Only successes are kept: an error is looked up again next time. Nor is a
  # value kept when an invalidation came while it was being looked up: it may
  # be the row from before the change, and would stay for the whole TTL.
  defp store(key, {:ok, _} = ok, expires, generation) do
    if generation(key) == generation, do: :ets.insert(@table, {key, ok, expires})
    ok
  end

  defp store(_key, other, _expires, _generation), do: other

  # A counter per entry (and one for every credential, one for everything)
  # that each invalidation bumps.
  defp generation({:endpoint, _uuid} = key), do: {counter(key), counter(:all)}
  defp generation({:credentials, _key}), do: {counter(:credentials), counter(:all)}

  defp counter(name) do
    case :ets.lookup(@table, {:generation, name}) do
      [{_key, n}] -> n
      [] -> 0
    end
  end

  defp bump(name),
    do: :ets.update_counter(@table, {:generation, name}, 1, {{:generation, name}, 0})

  defp ttl(key) do
    case Application.get_env(:phoenix_kit_ai, key, @default_ttl) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_ttl
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  # ---- server: owns the table, follows the change broadcasts ----

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    subscribe()
    {:ok, nil}
  end

  defp subscribe do
    PhoenixKitAI.subscribe_endpoints()
    Events.subscribe()
  rescue
    # PubSub not running yet (some test setups): the TTL still bounds staleness
    e ->
      Logger.warning(
        "[PhoenixKitAI.Cache] not following change broadcasts: #{Exception.message(e)}"
      )
  end

  @impl true
  def handle_info(msg, st) when is_tuple(msg) and tuple_size(msg) >= 2 do
    cond do
      # checked first: {:integration_disconnected, provider_key} is also a 2-tuple
      integration_event?(msg) -> invalidate_credentials()
      # endpoint topic: {event, endpoint_uuid}
      tuple_size(msg) == 2 and is_binary(elem(msg, 1)) -> invalidate_endpoint(elem(msg, 1))
      true -> :ok
    end

    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp integration_event?(msg) do
    case elem(msg, 0) do
      event when is_atom(event) -> String.starts_with?(Atom.to_string(event), "integration_")
      _ -> false
    end
  end
end
