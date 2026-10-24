defmodule PhoenixKitAI.RequestLog do
  @moduledoc """
  Writes usage rows (`phoenix_kit_ai_requests`) off the caller's process.

  By default (`config :phoenix_kit_ai, request_log_mode: :sync`) a verb inserts
  its usage row before it returns — one more database round trip on every call,
  cache hits included. With `request_log_mode: :async` the row is handed to this
  process and the verb returns at once; the row is written moments later with
  the same insert, broadcast, telemetry and usage sinks as the synchronous path
  (`PhoenixKitAI.create_request/1` does all of it here instead).

  Trade-offs of `:async`:

    * spend caps and task limits read the usage table, so calls made in the
      instant before their rows land are not counted yet (both already overshoot
      by in-flight calls);
    * a row is lost if the node dies before writing it — and the answer's
      `request_uuid`, given out when the row was queued, then names no row.

  Backpressure: when more than `request_log_max_queue` rows (default 10_000) are
  waiting, callers write synchronously again rather than drop rows. Without the
  module's supervisor tree (`PhoenixKitAI.children/0`) rows are written
  synchronously.
  """
  # Rows still queued at shutdown are written in `terminate/2`, one insert each,
  # so the supervisor gives it longer than the default five seconds.
  use GenServer, shutdown: 30_000
  require Logger

  @default_max_queue 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether rows are written asynchronously right now (mode, process, backlog)."
  @spec async?() :: boolean()
  def async? do
    Application.get_env(:phoenix_kit_ai, :request_log_mode, :sync) == :async and
      case Process.whereis(__MODULE__) do
        nil ->
          false

        pid ->
          # nil when the process exited since `whereis/1`: write synchronously
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, len} ->
              len <
                Application.get_env(:phoenix_kit_ai, :request_log_max_queue, @default_max_queue)

            nil ->
              false
          end
      end
  end

  @doc "Queue one row: its uuid and the attrs of `PhoenixKitAI.create_request/1`."
  @spec enqueue({Ecto.UUID.t(), map()}) :: :ok
  def enqueue({uuid, attrs}), do: GenServer.cast(__MODULE__, {:write, uuid, attrs})

  @doc """
  Wait until every row queued so far is written (tests, graceful shutdown, and
  the Playground before it reads a call's cost).
  """
  @spec flush(timeout()) :: :ok
  def flush(timeout \\ 30_000) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :flush, timeout)
    :ok
  end

  @impl true
  def init(_) do
    # rows still queued at shutdown are written in terminate/2
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def handle_cast({:write, uuid, attrs}, st) do
    write(uuid, attrs)
    {:noreply, st}
  end

  @impl true
  def handle_call(:flush, _from, st), do: {:reply, :ok, st}

  @impl true
  def terminate(_reason, _st) do
    drain()
    :ok
  end

  defp drain do
    receive do
      {:"$gen_cast", {:write, uuid, attrs}} ->
        write(uuid, attrs)
        drain()
    after
      0 -> :ok
    end
  end

  defp write(uuid, attrs) do
    PhoenixKitAI.write_request(uuid, attrs)
  rescue
    # the exception module only — a database error's message can carry row values
    e ->
      Logger.warning("[PhoenixKitAI.RequestLog] usage row not written: #{inspect(e.__struct__)}")
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI.RequestLog] usage row not written: repo exited")
  end
end
