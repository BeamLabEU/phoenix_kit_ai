defmodule PhoenixKitAI.Realtime.Session do
  @moduledoc """
  Owns one xAI realtime WebSocket connection (`Xai.Realtime`) on behalf of a
  single Playground LiveView, forwarding audio chunks and events to it as
  plain messages.

  Runs under `PhoenixKitAI.Realtime.Supervisor` (a `DynamicSupervisor`
  contributed via `PhoenixKitAI.children/0`) with `restart: :temporary` — a
  dead session is not auto-restarted, the LiveView re-triggers "start voice"
  itself.

  ## Cleanup

  `Xai.Realtime.connect_tts/1` is called from `init/1`, so the WebSockex
  connection links to *this* process, not the owning LiveView — a socket
  crash only takes down the session. The reverse direction (LiveView goes
  away) is handled by monitoring `live_view_pid`: LiveView's own
  `terminate/2` isn't reliably called without `trap_exit`, so closing the
  connection is driven from here via the `:DOWN` message instead.
  """

  use GenServer

  require Logger

  @default_realtime_module Xai.Realtime

  @type start_opts :: [
          live_view_pid: pid(),
          api_key: String.t(),
          voice: String.t(),
          language: String.t(),
          codec: String.t(),
          sample_rate: pos_integer(),
          realtime_module: module()
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # A dead/ended voice session should never be auto-restarted by the
  # DynamicSupervisor — the LiveView re-triggers "start voice" itself.
  def child_spec(opts) do
    super(opts) |> Map.put(:restart, :temporary)
  end

  @doc "Send text to be spoken."
  @spec send_text(pid(), String.t()) :: :ok
  def send_text(pid, text) when is_binary(text) do
    GenServer.cast(pid, {:send_text, text})
  end

  @doc "Signal end of the current utterance."
  @spec finish(pid()) :: :ok
  def finish(pid) do
    GenServer.cast(pid, :finish)
  end

  @doc "Close the realtime connection and stop the session."
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  @impl true
  def init(opts) do
    live_view_pid = Keyword.fetch!(opts, :live_view_pid)
    realtime_module = Keyword.get(opts, :realtime_module, @default_realtime_module)

    Process.monitor(live_view_pid)

    connect_opts = [
      api_key: Keyword.fetch!(opts, :api_key),
      voice: Keyword.get(opts, :voice, "eve"),
      language: Keyword.get(opts, :language, "en"),
      codec: Keyword.get(opts, :codec, "pcm"),
      sample_rate: Keyword.get(opts, :sample_rate, 24_000),
      on_audio: fn chunk -> send(live_view_pid, {:xai_audio_chunk, chunk}) end,
      on_event: fn event -> send(live_view_pid, {:xai_realtime_event, event}) end
    ]

    case realtime_module.connect_tts(connect_opts) do
      {:ok, ws_pid} ->
        {:ok, %{live_view_pid: live_view_pid, realtime_module: realtime_module, ws_pid: ws_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:send_text, text}, state) do
    state.realtime_module.send_text(state.ws_pid, text)
    {:noreply, state}
  end

  def handle_cast(:finish, state) do
    state.realtime_module.send_text_done(state.ws_pid)
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    state.realtime_module.close(state.ws_pid)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{live_view_pid: pid} = state) do
    state.realtime_module.close(state.ws_pid)
    {:stop, :normal, state}
  end

  # Catch-all for unmatched messages — never silently swallow one we didn't
  # expect (mirrors PhoenixKitAI.Web.Playground's own handle_info/2 default).
  def handle_info(msg, state) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Realtime.Session] unhandled handle_info: #{inspect(msg)}"
    end)

    {:noreply, state}
  end
end
