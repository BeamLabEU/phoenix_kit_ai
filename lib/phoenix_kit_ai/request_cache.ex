defmodule PhoenixKitAI.RequestCache do
  @moduledoc """
  A write-once cache for provider answers, keyed on what would be sent.

  Every `PhoenixKitAI` verb accepts `cache: true` (default TTL),
  `cache: [ttl: seconds | :infinity, key: term, refresh: boolean]` or
  `cache: :refresh` (bypass a stored answer and overwrite it). Without
  `key:` the key is a SHA-256 over the verb, the endpoint (uuid and
  `updated_at`, so editing the endpoint invalidates its entries), the model
  and the request-shaping inputs — messages or prompt, image bytes, request
  options, the JSON shape asked for — never the caller's `source`,
  attribution, idempotency key or `user_uuid`. With `key:` ("product:123",
  say) the caller's term replaces the request material, so a re-rendered
  prompt still hits; the verb, endpoint, model and JSON shape stay in the
  key.

  Entries are shared across users: two callers asking the same thing get
  the same answer, and a caller key is global to the endpoint. Scope it
  yourself (`cache: [key: {user_uuid, "profile"}]`) when the answer is
  personal.

  A hit returns the stored result and makes no provider call; the verbs
  pass an `:on_hit` callback through `meta` that writes a zero-cost usage
  row marked `cached: true` (attribution and the prompt link intact), so
  reports stay truthful — a hit does not count against a spend cap because
  it costs nothing. `[:phoenix_kit_ai, :cache, :hit | :miss | :refresh]`
  fires per lookup. Only `{:ok, _}` results are stored; concurrent misses
  on the same key each call the provider (no single-flight).

  Entries live in a public ETS table owned by this process (reads and
  writes never queue behind it); the process only sweeps expired entries.
  `config :phoenix_kit_ai, request_cache: [ttl: 86_400, sweep: 300,
  max_entries: 10_000, max_value_bytes: 8_000_000, default: false]` —
  read per call; `default: true` caches every cacheable verb unless a call
  says `cache: false`. A full table or an oversized value (an image edit
  result, typically) is simply not stored. Restarting the node empties the
  cache, and without the module's supervisor tree (`PhoenixKitAI.children/0`)
  every lookup is a miss — this is a cost saver, not a store of record.
  """

  use GenServer

  require Logger

  @table :phoenix_kit_ai_request_cache
  @flags_table :phoenix_kit_ai_flags
  @default_ttl 24 * 60 * 60
  @default_sweep 5 * 60
  @default_max_entries 10_000
  @default_max_value_bytes 8_000_000

  @type key :: binary()
  @type ttl :: pos_integer() | :infinity

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Default TTL in seconds."
  @spec default_ttl() :: pos_integer()
  def default_ttl, do: positive(config()[:ttl], @default_ttl)

  @doc """
  The cache key for a verb on an endpoint over `material` (any term). The
  endpoint's `updated_at` is part of it, so an admin edit starts fresh.
  """
  @spec key(atom(), PhoenixKitAI.Endpoint.t(), String.t() | nil, term()) :: key()
  def key(verb, endpoint, model, material) do
    term = {verb, endpoint.uuid, Map.get(endpoint, :updated_at), model, material}
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
  end

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
    ttl =
      case Keyword.get(cache_opts, :ttl) do
        :infinity -> :infinity
        n when is_integer(n) and n > 0 -> n
        _ -> default_ttl()
      end

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
  Runs `fun` unless a fresh answer for `key` is stored. `key` may be a
  zero-arity function, called only when caching is on (hashing image bytes
  is not free). `fun` returns `{:ok, result} | {:error, _}`; only `{:ok, _}`
  is stored. `meta` is the telemetry metadata; its `:on_hit` entry, a
  one-arity function, runs on a hit with the stored value and is not
  emitted.
  """
  @spec fetch(key() | (-> key()), keyword(), (-> {:ok, term()} | {:error, term()}), map()) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, opts, fun, meta \\ %{}) do
    case mode(opts) do
      false ->
        fun.()

      {:use, ttl} ->
        use_cached(resolve_key(key), ttl, fun, meta)

      {:refresh, ttl} ->
        emit(:refresh, meta)
        store(resolve_key(key), ttl, fun.())
    end
  end

  defp resolve_key(key) when is_function(key, 0), do: key.()
  defp resolve_key(key), do: key

  @doc "A stored, unexpired value."
  @spec get(key()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] ->
        if expires_at == :infinity or System.monotonic_time(:millisecond) < expires_at,
          do: {:ok, value},
          else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Stores `value` for `ttl` seconds (or forever with `:infinity`). Returns
  `:ok`, or `{:error, :full | :too_large}` when the table is at
  `max_entries` or the value is over `max_value_bytes` (nothing stored).
  """
  @spec put(key(), term(), ttl()) :: :ok | {:error, :full | :too_large}
  def put(key, value, ttl) do
    cond do
      :erlang.external_size(value) >
          positive(config()[:max_value_bytes], @default_max_value_bytes) ->
        {:error, :too_large}

      size() >= positive(config()[:max_entries], @default_max_entries) and
          :ets.lookup(@table, key) == [] ->
        {:error, :full}

      true ->
        # Millisecond deadlines: with whole seconds a `ttl: 1` could expire
        # almost at once on a clock boundary.
        expires_at =
          if ttl == :infinity,
            do: :infinity,
            else: System.monotonic_time(:millisecond) + ttl * 1000

        :ets.insert(@table, {key, expires_at, value})
        :ok
    end
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
    case :ets.info(@table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc false
  # A small public set for once-only flags (the budget warnings) that must
  # not live in persistent_term — every put there is a global GC.
  @spec flags_table() :: atom()
  def flags_table, do: @flags_table

  defp use_cached(key, ttl, fun, meta) do
    case get(key) do
      {:ok, value} ->
        emit(:hit, meta)
        run_on_hit(meta[:on_hit], value)
        {:ok, value}

      :miss ->
        emit(:miss, meta)
        store(key, ttl, fun.())
    end
  end

  # A hit must never fail because its bookkeeping did.
  defp run_on_hit(on_hit, value) when is_function(on_hit, 1) do
    on_hit.(value)
    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] cache hit bookkeeping failed: #{Exception.message(error)}")
      :ok
  end

  defp run_on_hit(_other, _value), do: :ok

  defp store(key, ttl, {:ok, value} = ok) do
    put(key, value, ttl)
    ok
  end

  defp store(_key, _ttl, other), do: other

  defp emit(event, meta) do
    :telemetry.execute([:phoenix_kit_ai, :cache, event], %{count: 1}, Map.delete(meta, :on_hit))
  rescue
    _ -> :ok
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

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

    :ets.new(@flags_table, [:named_table, :public, :set])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    # The `is_integer` guard keeps `:infinity` entries out of the delete.
    :ets.select_delete(@table, [
      {{:_, :"$1", :_}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, positive(config()[:sweep], @default_sweep) * 1000)
  end
end
