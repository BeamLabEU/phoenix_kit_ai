defmodule PhoenixKitAI.Fetch.HostState do
  @moduledoc """
  The per-node state of `PhoenixKitAI.Fetch`: each host's robots.txt rules
  (cached for `robots_ttl` seconds) and the next moment a request to it may
  start (the per-host rate limit).

  The rules live in a public ETS table read without this process; a rate
  limit slot is handed out by this process, one caller at a time, so two
  callers never take the same moment. Without it (a host app that does not
  start `PhoenixKitAI.children/0`) robots.txt is fetched on every call and no
  rate limit applies — `PhoenixKitAI.Fetch` says so in a warning, once.

  Every 10 minutes the rows that no longer say
  anything — expired rules, slots already in the past — are deleted, so a
  crawl over many hosts does not keep one row per host for the node's life.
  """

  use GenServer

  @table :phoenix_kit_ai_fetch_hosts
  @prune_every_ms 10 * 60_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the state process is running on this node."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Takes the next slot for `host` with `interval_ms` between requests and
  returns how many milliseconds the caller waits before it starts. `0` when
  the process is not running.
  """
  @spec reserve(String.t(), non_neg_integer(), integer() | nil) :: non_neg_integer() | :deadline
  def reserve(host, interval_ms, deadline_at \\ nil)
      when is_binary(host) and is_integer(interval_ms) do
    if running?(),
      do: GenServer.call(__MODULE__, {:reserve, host, interval_ms, deadline_at}),
      else: 0
  catch
    :exit, _ -> 0
  end

  @doc "The cached robots rules of `origin`, or nil (none, expired, or no process)."
  @spec robots(term()) :: term() | nil
  def robots(origin) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, {:robots, origin}) do
      [{_, rules, expires}] when expires > now -> rules
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Caches `rules` for `origin` for `ttl_ms`."
  @spec put_robots(term(), term(), non_neg_integer()) :: :ok
  def put_robots(origin, rules, ttl_ms) do
    :ets.insert(@table, {{:robots, origin}, rules, System.monotonic_time(:millisecond) + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets every cached rule and slot (tests; a host after changing its policy)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Deletes the expired rules and past slots now; returns how many rows went."
  @spec prune() :: non_neg_integer()
  def prune do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:robots, :_}, :_, :"$1"}, [{:"=<", :"$1", now}], [true]},
      {{{:next, :_}, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])
  rescue
    ArgumentError -> 0
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_prune()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    prune()
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every_ms)

  @impl GenServer
  def handle_call({:reserve, host, interval_ms, deadline_at}, _from, state) do
    now = System.monotonic_time(:millisecond)

    start =
      case :ets.lookup(@table, {:next, host}) do
        [{_, next}] when next > now -> next
        _ -> now
      end

    if is_integer(deadline_at) and start >= deadline_at do
      {:reply, :deadline, state}
    else
      :ets.insert(@table, {{:next, host}, start + max(interval_ms, 0)})
      {:reply, start - now, state}
    end
  end
end
