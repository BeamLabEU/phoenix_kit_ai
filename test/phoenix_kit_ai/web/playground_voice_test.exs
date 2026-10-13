defmodule PhoenixKitAI.Web.PlaygroundVoiceTest do
  @moduledoc """
  Streaming voice (xAI realtime) panel in `PhoenixKitAI.Web.Playground`.

  `Xai.RealtimeBehaviour.connect_tts/1` is invoked from inside
  `PhoenixKitAI.Realtime.Session.init/1`, which runs in a process spawned
  by the LiveView process — not this test process — so Mox's global mode
  is used (see `PhoenixKitAI.Realtime.SessionTest` for the same rationale),
  hence no `async: true`.
  """

  use PhoenixKitAI.LiveCase

  import Mox

  alias PhoenixKitAI.Test.RealtimeMock

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Application.put_env(:phoenix_kit_ai, :realtime_module, RealtimeMock)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :realtime_module) end)
    :ok
  end

  defp select_endpoint(view, endpoint) do
    render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  describe "panel visibility" do
    test "hidden until an xAI endpoint is selected", %{conn: conn} do
      openrouter = fixture_endpoint(provider: "openrouter", name: "OR Endpoint")
      xai = fixture_endpoint(provider: "xai", model: "grok-4.5", name: "xAI Endpoint")

      {:ok, view, html} = live(conn, "/en/admin/ai/playground")
      refute html =~ "Streaming Voice (xAI)"

      html = select_endpoint(view, openrouter)
      refute html =~ "Streaming Voice (xAI)"

      html = select_endpoint(view, xai)
      assert html =~ "Streaming Voice (xAI)"
    end
  end

  describe "the voice list" do
    @api_key "xai-canary-key-0123456789abcdef"

    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:voices_requested, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"voices" => [%{"voice_id" => "cloned-1", "name" => "My Clone"}]})
      end)

      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "is fetched with the endpoint's key, which never reaches the log", %{conn: conn} do
      endpoint = fixture_endpoint(provider: "xai", model: "grok-4.5", api_key: @api_key)
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      Req.Test.allow(__MODULE__, self(), view.pid)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          select_endpoint(view, endpoint)
          assert render(view) =~ "My Clone"
        end)

      assert_received {:voices_requested, ["Bearer " <> @api_key]}
      refute log =~ @api_key
    end

    test "a fetch for an endpoint no longer selected is dropped", %{conn: conn} do
      endpoint = fixture_endpoint(provider: "xai", model: "grok-4.5", api_key: @api_key)
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      Req.Test.allow(__MODULE__, self(), view.pid)

      send(view.pid, {:fetch_xai_voices, endpoint.uuid})

      refute render(view) =~ "My Clone"
      refute_received {:voices_requested, _}
    end

    test "a message carrying a key is logged by shape only", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, {:fetch_xai_voices, Ecto.UUID.generate(), @api_key})
          render(view)
        end)

      assert log =~
               "[PhoenixKitAI.Web.Playground] unhandled handle_info: {:fetch_xai_voices, …}/3"

      refute log =~ @api_key
    end
  end

  describe "start_voice" do
    test "connects through the realtime module and shows Connected", %{conn: conn} do
      endpoint =
        fixture_endpoint(provider: "xai", model: "grok-4.5", api_key: "xai-test-key")

      expect(RealtimeMock, :connect_tts, fn opts ->
        assert opts[:api_key] == "xai-test-key"
        assert opts[:voice] == "eve"
        assert opts[:codec] == "pcm"
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      select_endpoint(view, endpoint)

      html = render_click(view, "start_voice")
      assert html =~ "Connected"
    end

    test "shows an error flash when no endpoint is selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      html = render_click(view, "start_voice")
      assert html =~ "Please select an endpoint"
    end
  end

  describe "speak_voice" do
    test "sends text and signals done through the realtime module", %{conn: conn} do
      endpoint = fixture_endpoint(provider: "xai", model: "grok-4.5")
      ws_pid = spawn(fn -> Process.sleep(:infinity) end)
      test_pid = self()

      # `Session.send_text/2` and `finish/1` are GenServer CASTS: the LiveView
      # handler returns before the session process has consumed them, so
      # bare expectations race `verify_on_exit!` and intermittently report
      # "invoked 0 times". The mocks signal this process instead, and the
      # assert_receive both synchronizes and asserts.
      expect(RealtimeMock, :connect_tts, fn _opts -> {:ok, ws_pid} end)

      expect(RealtimeMock, :send_text, fn ^ws_pid, "Hello there" ->
        send(test_pid, :text_sent)
        :ok
      end)

      expect(RealtimeMock, :send_text_done, fn ^ws_pid ->
        send(test_pid, :text_done)
        :ok
      end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      select_endpoint(view, endpoint)
      render_click(view, "start_voice")

      render_submit(view, "speak_voice", %{"text" => "Hello there"})

      assert_receive :text_sent, 1_000
      assert_receive :text_done, 1_000
    end
  end

  describe "audio streaming" do
    test "pushes each audio chunk to the client as base64", %{conn: conn} do
      endpoint = fixture_endpoint(provider: "xai", model: "grok-4.5")

      expect(RealtimeMock, :connect_tts, fn opts ->
        opts[:on_audio].(<<1, 2, 3>>)
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      select_endpoint(view, endpoint)
      render_click(view, "start_voice")

      assert_push_event(view, "xai-audio-chunk", %{data: "AQID"})
    end
  end

  describe "stop_voice" do
    test "resets to idle once the session closes", %{conn: conn} do
      endpoint = fixture_endpoint(provider: "xai", model: "grok-4.5")
      ws_pid = spawn(fn -> Process.sleep(:infinity) end)

      expect(RealtimeMock, :connect_tts, fn _opts -> {:ok, ws_pid} end)
      expect(RealtimeMock, :close, fn ^ws_pid -> :ok end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      select_endpoint(view, endpoint)
      render_click(view, "start_voice")

      render_click(view, "stop_voice")

      # `close/1` is a cast and the LiveView's own `Process.monitor/1` of
      # the session pid resolves asynchronously — poll briefly for the
      # `:DOWN`-driven reset instead of asserting on a single render.
      wait_until(fn -> render(view) =~ "Not connected" end)
    end
  end
end
