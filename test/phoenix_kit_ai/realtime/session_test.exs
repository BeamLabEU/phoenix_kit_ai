defmodule PhoenixKitAI.Realtime.SessionTest do
  # `Xai.RealtimeBehaviour.connect_tts/1` is called from inside
  # `Session.init/1`, which runs in the newly spawned session process, not
  # this test process — Mox's default per-process allowances can't cover
  # that (the pid doesn't exist yet when the expectation is set up), so
  # this uses Mox's documented global mode instead, hence `async: false`.
  use ExUnit.Case, async: false

  import Mox

  alias PhoenixKitAI.Realtime.Session
  alias PhoenixKitAI.Test.RealtimeMock

  setup :set_mox_global
  setup :verify_on_exit!

  defp unlinked_pid do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  describe "start_link/1" do
    test "connects via the realtime module and forwards audio chunks + events to the live view pid" do
      ws_pid = unlinked_pid()

      expect(RealtimeMock, :connect_tts, fn opts ->
        assert opts[:api_key] == "test-key"
        assert opts[:voice] == "eve"
        assert opts[:codec] == "pcm"

        # Simulate chunks/events arriving asynchronously, like the real
        # WebSockex process invoking these callbacks.
        opts[:on_audio].("chunk-1")
        opts[:on_event].(%{"type" => "audio.done"})

        {:ok, ws_pid}
      end)

      assert {:ok, session_pid} =
               Session.start_link(
                 live_view_pid: self(),
                 api_key: "test-key",
                 voice: "eve",
                 codec: "pcm",
                 realtime_module: RealtimeMock
               )

      assert_receive {:xai_audio_chunk, "chunk-1"}
      assert_receive {:xai_realtime_event, %{"type" => "audio.done"}}
      assert Process.alive?(session_pid)
    end

    test "returns the connect error instead of starting" do
      expect(RealtimeMock, :connect_tts, fn _opts -> {:error, :unauthorized} end)

      # start_link/1 links the caller to the child — in production that
      # link is absorbed by PhoenixKitAI.Realtime.Supervisor (a
      # DynamicSupervisor, which traps exits by default), so
      # `DynamicSupervisor.start_child/2` just returns `{:error, reason}`
      # to the LiveView without it needing to trap anything. Calling
      # start_link directly here (no supervisor in between) means this
      # test process must trap exits itself to see the same clean
      # `{:error, reason}` instead of crashing on the linked EXIT.
      Process.flag(:trap_exit, true)

      assert {:error, :unauthorized} =
               Session.start_link(
                 live_view_pid: self(),
                 api_key: "bad-key",
                 realtime_module: RealtimeMock
               )
    end
  end

  describe "send_text/2, finish/1, close/1" do
    test "forward to the realtime module, and close stops the session" do
      ws_pid = unlinked_pid()

      expect(RealtimeMock, :connect_tts, fn _opts -> {:ok, ws_pid} end)
      expect(RealtimeMock, :send_text, fn ^ws_pid, "hello" -> :ok end)
      expect(RealtimeMock, :send_text_done, fn ^ws_pid -> :ok end)
      expect(RealtimeMock, :close, fn ^ws_pid -> :ok end)

      {:ok, session_pid} =
        Session.start_link(
          live_view_pid: self(),
          api_key: "test-key",
          realtime_module: RealtimeMock
        )

      Process.flag(:trap_exit, true)
      Process.link(session_pid)

      Session.send_text(session_pid, "hello")
      Session.finish(session_pid)
      Session.close(session_pid)

      assert_receive {:EXIT, ^session_pid, :normal}
    end
  end

  describe "owning live view cleanup" do
    test "closes the connection and stops when the live view process goes down" do
      ws_pid = unlinked_pid()
      live_view_pid = unlinked_pid()

      expect(RealtimeMock, :connect_tts, fn _opts -> {:ok, ws_pid} end)
      expect(RealtimeMock, :close, fn ^ws_pid -> :ok end)

      {:ok, session_pid} =
        Session.start_link(
          live_view_pid: live_view_pid,
          api_key: "test-key",
          realtime_module: RealtimeMock
        )

      Process.flag(:trap_exit, true)
      Process.link(session_pid)

      Process.exit(live_view_pid, :kill)

      assert_receive {:EXIT, ^session_pid, :normal}
    end
  end

  describe "child_spec/1" do
    test "is restart: :temporary — a dead session is never auto-restarted" do
      assert %{restart: :temporary} = Session.child_spec(live_view_pid: self(), api_key: "k")
    end
  end
end
