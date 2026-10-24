defmodule PhoenixKitAI.Limiter do
  @moduledoc """
  Caps how many provider calls run at once per key, and lines up the rest in
  arrival order.

  A provider rate-limits a burst (429) long before a spend cap matters, and a
  batch job that fires 50 calls at once mostly buys retries. The limiter gives a
  key (by default the endpoint's provider, `"provider:openrouter"`) a number of
  slots; a call that finds them taken waits its turn, and gives up with
  `{:error, :concurrency_limit_timeout}` after `wait` milliseconds or with
  `{:error, :concurrency_queue_full}` when `max_waiting` calls are already in line.

  Nothing is limited unless configured — globally per key:

      config :phoenix_kit_ai, concurrency: %{
        "provider:openrouter" => 8,            # all OpenRouter endpoints together
        "endpoint:Label reader" => 2           # one endpoint, by name
      }

  or per call, which wins over the configuration:

      PhoenixKitAI.complete(ep, messages, concurrency: [limit: 4])            # the default key
      PhoenixKitAI.complete(ep, messages, concurrency: [key: "batch", limit: 4, wait: 60_000])
      PhoenixKitAI.complete(ep, messages, concurrency: false)                 # bypass

  A waiting call can be told its place in line: `concurrency: [notify: pid]` sends
  `{:phoenix_kit_ai_queue, key, position}` (1 = next) to `pid` whenever it changes.

  The slot covers the whole provider call, retries included (see
  `PhoenixKitAI.Completion`), so backing off after a 429 also keeps the pressure
  off. A caller that dies — crashed, killed, a closed LiveView — gives its slot or
  its place back (monitors). Limits are per node; in a cluster each node keeps its
  own count. Without the module's supervisor tree (`PhoenixKitAI.children/0`) every
  call runs straight through.

  Options (`concurrency:` keyword or the app env `:concurrency_defaults`):
  `wait` (default 30_000 ms), `max_waiting` (default 1_000).
  """
  use GenServer

  @default_wait 30_000
  @default_max_waiting 1_000

  # ---- client ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Runs `fun` under the limit that applies to `endpoint` and `opts`; returns what
  `fun` returns, or `{:error, :concurrency_limit_timeout | :concurrency_queue_full}`.
  """
  @spec run(map(), keyword(), (-> term())) :: term()
  def run(endpoint, opts, fun) when is_function(fun, 0) do
    case limit_for(endpoint, opts) do
      nil -> fun.()
      {key, limit, settings} -> with_slot(key, limit, settings, fun)
    end
  end

  @doc "The `{key, limit, settings}` that applies, or nil when the call is not limited."
  @spec limit_for(map(), keyword()) :: {String.t() | term(), pos_integer(), keyword()} | nil
  def limit_for(endpoint, opts) do
    defaults = Application.get_env(:phoenix_kit_ai, :concurrency_defaults, [])

    case Keyword.get(opts, :concurrency) do
      false ->
        nil

      per_call when is_list(per_call) ->
        key = Keyword.get(per_call, :key, default_key(endpoint))

        case Keyword.get(per_call, :limit) || configured_limit(endpoint, key) do
          limit when is_integer(limit) and limit > 0 ->
            {key, limit, Keyword.merge(defaults, per_call)}

          _ ->
            nil
        end

      _ ->
        configured(endpoint, defaults)
    end
  end

  @doc "Current state of one key: slots, running, waiting (zeros for an unknown key)."
  @spec stats(term()) :: %{
          optional(:limit) => pos_integer(),
          running: non_neg_integer(),
          waiting: non_neg_integer()
        }
  def stats(key) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:stats, key}),
      else: %{running: 0, waiting: 0}
  end

  defp configured(endpoint, defaults) do
    config = Application.get_env(:phoenix_kit_ai, :concurrency, %{})

    Enum.find_value(candidate_keys(endpoint), fn key ->
      case Map.get(config, key) do
        limit when is_integer(limit) and limit > 0 -> {key, limit, defaults}
        _ -> nil
      end
    end)
  end

  defp configured_limit(endpoint, key) do
    config = Application.get_env(:phoenix_kit_ai, :concurrency, %{})
    Map.get(config, key) || Enum.find_value(candidate_keys(endpoint), &Map.get(config, &1))
  end

  # most specific first: one endpoint (by uuid, then by name), then its provider
  defp candidate_keys(endpoint) do
    [
      endpoint_key(:uuid, Map.get(endpoint, :uuid)),
      endpoint_key(:name, Map.get(endpoint, :name)),
      default_key(endpoint)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp endpoint_key(_kind, nil), do: nil
  defp endpoint_key(_kind, value), do: "endpoint:" <> to_string(value)

  # The base provider: an endpoint on a named connection (`"openrouter:work"`)
  # shares `"provider:openrouter"` with the others.
  defp default_key(endpoint) do
    case Map.get(endpoint, :provider) do
      provider when is_binary(provider) and provider != "" ->
        "provider:" <> PhoenixKitAI.Endpoint.base_provider(provider)

      _ ->
        "provider:unknown"
    end
  end

  defp with_slot(key, limit, settings, fun) do
    if Process.whereis(__MODULE__) do
      wait = Keyword.get(settings, :wait, @default_wait)
      max_waiting = Keyword.get(settings, :max_waiting, @default_max_waiting)
      notify = Keyword.get(settings, :notify)

      case acquire(key, limit, max_waiting, is_pid(notify)) do
        :unlimited ->
          fun.()

        {:go, ref} ->
          hold(ref, fun)

        {:queued, ref, position} ->
          notify(notify, key, position)
          deadline = System.monotonic_time(:millisecond) + wait
          await(ref, key, notify, deadline, fun)

        :full ->
          :telemetry.execute([:phoenix_kit_ai, :limiter, :rejected], %{count: 1}, %{
            key: key,
            reason: :full
          })

          {:error, :concurrency_queue_full}
      end
    else
      fun.()
    end
  end

  defp await(ref, key, notify, deadline, fun) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:phoenix_kit_ai_limiter_go, ^ref} ->
        hold(ref, fun)

      {:phoenix_kit_ai_limiter_position, ^ref, position} ->
        notify(notify, key, position)
        await(ref, key, notify, deadline, fun)
    after
      remaining ->
        cancel(ref)

        :telemetry.execute([:phoenix_kit_ai, :limiter, :rejected], %{count: 1}, %{
          key: key,
          reason: :timeout
        })

        {:error, :concurrency_limit_timeout}
    end
  end

  # The limiter gone between `whereis/1` and the call (a restart), or too
  # busy to answer in time: the call runs unlimited, as it does without the
  # limiter at all. The ref is made here so a late acquire can be taken back:
  # the cancel is sent after the acquire from the same process, so the server
  # reads it second and frees the slot (or place) it would otherwise keep for
  # this caller until it dies.
  defp acquire(key, limit, max_waiting, track?) do
    ref = make_ref()

    try do
      GenServer.call(__MODULE__, {:acquire, self(), ref, key, limit, max_waiting, track?})
    catch
      :exit, _ ->
        GenServer.cast(__MODULE__, {:cancel, ref})
        :unlimited
    end
  end

  # The cancel is a call, so every message the server sent for `ref` before it
  # dropped it (a go that raced the timeout, a position) is already in this
  # mailbox when it returns, and is taken out: a caller is often a long-lived
  # LiveView or job process, whose `handle_info/2` should never see them. A go
  # that raced is a slot the server frees again with the cancel.
  defp cancel(ref) do
    GenServer.call(__MODULE__, {:cancel, ref})
  catch
    :exit, _ -> :ok
  after
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:phoenix_kit_ai_limiter_go, ^ref} -> flush(ref)
      {:phoenix_kit_ai_limiter_position, ^ref, _position} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp hold(ref, fun) do
    fun.()
  after
    GenServer.cast(__MODULE__, {:release, ref})
  end

  defp notify(pid, key, position) when is_pid(pid),
    do: send(pid, {:phoenix_kit_ai_queue, key, position})

  defp notify(_, _, _), do: :ok

  # ---- server ----

  @impl true
  def init(_), do: {:ok, %{keys: %{}, refs: %{}}}

  @impl true
  def handle_call({:acquire, pid, ref, key, limit, max_waiting, track?}, _from, st) do
    fresh = %{running: MapSet.new(), waiting: :queue.new(), nwaiting: 0, limit: limit}

    # The latest limit for a key wins (a config change takes effect on the next
    # call). A raised limit first admits the calls already waiting, in order.
    st = admit(st, key, %{Map.get(st.keys, key, fresh) | limit: limit})
    k = Map.get(st.keys, key, fresh)

    cond do
      MapSet.size(k.running) < k.limit and k.nwaiting == 0 ->
        mon = Process.monitor(pid)
        st = put_key(st, key, %{k | running: MapSet.put(k.running, ref)})
        {:reply, {:go, ref}, %{st | refs: Map.put(st.refs, ref, {key, mon, :running})}}

      k.nwaiting >= max_waiting ->
        {:reply, :full, put_key(st, key, k)}

      true ->
        mon = Process.monitor(pid)
        k = %{k | waiting: :queue.in({ref, pid, track?}, k.waiting), nwaiting: k.nwaiting + 1}
        st = put_key(st, key, k)

        {:reply, {:queued, ref, k.nwaiting},
         %{st | refs: Map.put(st.refs, ref, {key, mon, :waiting})}}
    end
  end

  def handle_call({:cancel, ref}, _from, st), do: {:reply, :ok, drop(st, ref)}

  def handle_call({:stats, key}, _from, st) do
    case Map.get(st.keys, key) do
      nil -> {:reply, %{running: 0, waiting: 0}, st}
      k -> {:reply, %{limit: k.limit, running: MapSet.size(k.running), waiting: k.nwaiting}, st}
    end
  end

  @impl true
  def handle_cast({:release, ref}, st), do: {:noreply, drop(st, ref)}
  def handle_cast({:cancel, ref}, st), do: {:noreply, drop(st, ref)}

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, st) do
    case Enum.find(st.refs, fn {_ref, {_key, m, _}} -> m == mon end) do
      {ref, _} -> {:noreply, drop(st, ref)}
      nil -> {:noreply, st}
    end
  end

  # forget `ref` (running or waiting), then hand free slots to the front of the line
  defp drop(st, ref) do
    case Map.pop(st.refs, ref) do
      {nil, _} ->
        st

      {{key, mon, state}, refs} ->
        Process.demonitor(mon, [:flush])
        k = remove_ref(Map.fetch!(st.keys, key), ref, state)
        admit(%{st | refs: refs}, key, k)
    end
  end

  defp remove_ref(k, ref, :running), do: %{k | running: MapSet.delete(k.running, ref)}

  defp remove_ref(k, ref, :waiting) do
    kept = :queue.filter(fn {r, _, _} -> r != ref end, k.waiting)
    %{k | waiting: kept, nwaiting: :queue.len(kept)}
  end

  defp admit(st, key, k) do
    if MapSet.size(k.running) < k.limit do
      case :queue.out(k.waiting) do
        {{:value, {ref, pid, _track?}}, rest} ->
          send(pid, {:phoenix_kit_ai_limiter_go, ref})
          {key_, mon, _} = Map.fetch!(st.refs, ref)
          st = %{st | refs: Map.put(st.refs, ref, {key_, mon, :running})}

          admit(st, key, %{
            k
            | running: MapSet.put(k.running, ref),
              waiting: rest,
              nwaiting: k.nwaiting - 1
          })

        {:empty, _} ->
          finish(st, key, k)
      end
    else
      finish(st, key, k)
    end
  end

  # Places in line go only to the waiters that asked (`notify:`): the others
  # would get a message per waiter on every change of the line for nothing.
  defp finish(st, key, k) do
    k.waiting
    |> :queue.to_list()
    |> Enum.with_index(1)
    |> Enum.each(fn
      {{ref, pid, true}, pos} -> send(pid, {:phoenix_kit_ai_limiter_position, ref, pos})
      _ -> :ok
    end)

    put_key(st, key, k)
  end

  # an idle key is removed, so the map doesn't grow with every key ever seen
  defp put_key(st, key, %{running: running, nwaiting: 0} = k) do
    if MapSet.size(running) == 0,
      do: %{st | keys: Map.delete(st.keys, key)},
      else: %{st | keys: Map.put(st.keys, key, k)}
  end

  defp put_key(st, key, k), do: %{st | keys: Map.put(st.keys, key, k)}
end
