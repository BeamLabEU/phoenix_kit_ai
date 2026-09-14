defmodule PhoenixKitAI.RequestCache do
  @moduledoc """
  A write-once cache for provider answers, keyed on what would be sent.

  Any verb accepts `cache: true` (default TTL), `cache: [ttl: seconds |
  :infinity, key: term]` or `cache: :refresh` (bypass a stored answer and
  overwrite it). Without `key:` the key is a SHA-256 over the verb, the
  endpoint, the model and the request-shaping inputs (messages or prompt,
  image bytes, request options) — never the caller's `source`, attribution
  or idempotency key. With `key:` ("product:123", say) the caller's term
  replaces the request material, so a re-rendered prompt still hits; the
  verb, endpoint and model stay in the key. A hit returns the stored
  result, makes no provider call, and writes a zero-cost usage row marked
  `cached: true` so attribution and caps stay truthful; it emits
  `[:phoenix_kit_ai, :cache, :hit]` (a miss emits `…:miss`).

  Entries live in a public ETS table owned by this process (so reads and
  writes never queue behind it); the process only sweeps expired entries.
  Default TTL and sweep interval come from
  `config :phoenix_kit_ai, request_cache: [ttl: 86_400, sweep: 300]`
  (seconds). Restarting the node empties the cache — this is a cost
  saver, not a store of record.
  """

  use GenServer

  @table :phoenix_kit_ai_request_cache
  @default_ttl 24 * 60 * 60
  @default_sweep 5 * 60

  @type key :: binary()

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Default TTL in seconds."
  @spec default_ttl() :: pos_integer()
  def default_ttl, do: config()[:ttl] || @default_ttl

  @doc "The cache key for a verb on an endpoint over `material` (any term)."
  @spec key(atom(), PhoenixKitAI.Endpoint.t(), String.t() | nil, term()) :: key()
  def key(verb, endpoint, model, material) do
    :crypto.hash(:sha256, :erlang.term_to_binary({verb, endpoint.uuid, model, material}))
  end

  @type ttl :: pos_integer() | :infinity

  @doc "How the caller asked for caching: `false`, `{:use, ttl}` or `{:refresh, ttl}`."
  @spec mode(keyword()) :: false | {:use, ttl()} | {:refresh, ttl()}
  def mode(opts) do
    case Keyword.get(opts, :cache, config()[:default] == true) do
      true -> {:use, default_ttl()}
      :refresh -> {:refresh, default_ttl()}
      cache_opts when is_list(cache_opts) -> list_mode(cache_opts)
      _ -> false
    end
  end

  defp list_mode(cache_opts) do
    ttl = Keyword.get(cache_opts, :ttl, default_ttl())
    if Keyword.get(cache_opts, :refresh, false), do: {:refresh, ttl}, else: {:use, ttl}
  end

  @doc "The caller's own key term from `cache: [key: …]`, or nil."
  @spec caller_key(keyword()) :: term() | nil
  def caller_key(opts) do
    case Keyword.get(opts, :cache) do
      cache_opts when is_list(cache_opts) -> Keyword.get(cache_opts, :key)
      _ -> nil
    end
  end

  @doc """
  Runs `fun` unless a fresh answer for `key` is stored. `fun` returns
  `{:ok, result} | {:error, _}`; only `{:ok, _}` results are stored.
  """
  @spec fetch(key(), keyword(), (-> {:ok, term()} | {:error, term()}), map()) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, opts, fun, meta \\ %{}) do
    case mode(opts) do
      false ->
        fun.()

      {:use, ttl} ->
        use_cached(key, ttl, fun, meta)

      {:refresh, ttl} ->
        emit(:miss, meta)
        store(key, ttl, fun.())
    end
  end

  @doc "A stored, unexpired value."
  @spec get(key()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] ->
        if expires_at == :infinity or System.monotonic_time(:second) < expires_at,
          do: {:ok, value},
          else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores `value` for `ttl` seconds (or forever with `:infinity`)."
  @spec put(key(), term(), ttl()) :: :ok
  def put(key, value, ttl) do
    expires_at = if ttl == :infinity, do: :infinity, else: System.monotonic_time(:second) + ttl
    :ets.insert(@table, {key, expires_at, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every entry."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Number of stored entries (expired ones included until the next sweep)."
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  rescue
    ArgumentError -> 0
  end

  defp use_cached(key, ttl, fun, meta) do
    case get(key) do
      {:ok, value} ->
        emit(:hit, meta)
        if on_hit = meta[:on_hit], do: on_hit.(value)
        {:ok, value}

      :miss ->
        emit(:miss, meta)
        store(key, ttl, fun.())
    end
  end

  defp store(key, ttl, {:ok, value} = ok) do
    put(key, value, ttl)
    ok
  end

  defp store(_key, _ttl, other), do: other

  defp emit(event, meta) do
    :telemetry.execute([:phoenix_kit_ai, :cache, event], %{count: 1}, meta)
  rescue
    _ -> :ok
  end

  defp config, do: Application.get_env(:phoenix_kit_ai, :request_cache, [])

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    # `:infinity` entries never match (an atom compares greater than any integer).
    :ets.select_delete(@table, [
      {{:_, :"$1", :_}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, (config()[:sweep] || @default_sweep) * 1000)
  end
end
