defmodule PhoenixKitAI.Web.EndpointFormModelFetchTest do
  @moduledoc """
  The endpoint form's validate-then-fetch flow: which validation results
  let the model fetch go ahead, that the fetch runs off the LiveView
  process, that a result for a connection or model type the operator has
  left is dropped, and that no API key reaches the debug log.

  The connection is picked while it has no key (so the form starts no
  validation of its own, which would go over the network), then given one;
  each test then delivers the validation result the form would have
  received.
  """

  use PhoenixKitAI.LiveCase

  import ExUnit.CaptureLog

  @api_key "sk-or-v1-canary-key-0123456789abcdef"

  @models %{
    "data" => [
      %{
        "id" => "anthropic/claude-3-haiku",
        "name" => "Claude 3 Haiku",
        "context_length" => 200_000,
        "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
        "pricing" => %{"prompt" => "0.00000025", "completion" => "0.00000125"}
      }
    ]
  }

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp stub_models(fun) do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Req.Test.stub(stub, fun)
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    stub
  end

  defp models_ok(conn), do: Plug.Conn.send_resp(conn, 200, Jason.encode!(@models))

  # Mounts the new-endpoint form with a connection picked and a key behind
  # it, the picker showing its spinner as it does while validation runs.
  defp form_awaiting_validation(conn, stub) do
    name = "fetch-#{System.unique_integer([:positive])}"
    %{uuid: uuid} = seed_openrouter_connection(name)

    {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
    Req.Test.allow(stub, self(), view.pid)
    render_hook(view, "select_provider_connection", %{"uuid" => uuid})

    seed_openrouter_connection(name, data: %{"api_key" => @api_key})
    start_spinner(view)

    {view, uuid}
  end

  defp start_spinner(view) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Phoenix.Component.assign(state.socket, :models_loading, true)}
    end)

    # Any handled message pushes the changed assign to the client.
    send(view.pid, :model_fetch_slow)
    assert render(view) =~ "Loading models..."
  end

  describe "validation results" do
    for {label, result} <- [
          {":ok", :ok},
          {"{:ok, note}", {:ok, %{fact: "us-east-1"}}},
          {":unverified", :unverified}
        ] do
      test "#{label} proceeds to the model fetch and the picker stops loading", %{conn: conn} do
        stub = stub_models(&models_ok/1)
        {view, uuid} = form_awaiting_validation(conn, stub)

        send(view.pid, {:validation_done, uuid, unquote(Macro.escape(result))})
        html = render_async(view, 2_000)

        refute html =~ "Loading models..."
        assert html =~ "Claude 3 Haiku"
      end
    end

    test "{:error, reason} stops loading, shows the reason and fetches nothing", %{conn: conn} do
      test_pid = self()

      stub =
        stub_models(fn conn ->
          send(test_pid, :models_requested)
          models_ok(conn)
        end)

      {view, uuid} = form_awaiting_validation(conn, stub)

      send(view.pid, {:validation_done, uuid, {:error, "Key rejected by provider"}})
      html = render_async(view, 2_000)

      refute html =~ "Loading models..."
      assert html =~ "Key rejected by provider"
      refute html =~ "Claude 3 Haiku"
      refute_received :models_requested
    end

    test "a result for a connection the operator has left is ignored", %{conn: conn} do
      stub = stub_models(&models_ok/1)
      {view, _uuid} = form_awaiting_validation(conn, stub)

      send(view.pid, {:validation_done, Ecto.UUID.generate(), :ok})
      html = render_async(view, 2_000)

      assert html =~ "Loading models..."
      refute html =~ "Claude 3 Haiku"
    end
  end

  describe "a connection that goes away mid-validation" do
    test "the picker stops loading when its connection is removed", %{conn: conn} do
      stub = stub_models(&models_ok/1)
      {view, uuid} = form_awaiting_validation(conn, stub)

      :ok = PhoenixKit.Integrations.remove_connection(uuid)
      send(view.pid, {:integration_connection_removed, uuid})

      # With no connection picked the picker is not on the page, so the
      # loading flag is read from the socket: it is what the next pick
      # would inherit.
      _ = render(view)
      refute :sys.get_state(view.pid).socket.assigns.models_loading

      # The late result is for a connection that is no longer picked.
      send(view.pid, {:validation_done, uuid, :ok})
      html = render_async(view, 2_000)

      refute html =~ "Loading models..."
      refute html =~ "Claude 3 Haiku"
    end

    test "a reload that keeps the picked connection leaves the fetch in flight", %{conn: conn} do
      stub = stub_models(&models_ok/1)
      {view, uuid} = form_awaiting_validation(conn, stub)

      send(view.pid, {:integration_connected, "openrouter", uuid})

      assert render(view) =~ "Loading models..."
    end
  end

  describe "the model fetch" do
    test "says so when the connection's key is gone by the time it runs", %{conn: conn} do
      stub = stub_models(&models_ok/1)
      %{uuid: uuid} = seed_openrouter_connection("nokey-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      Req.Test.allow(stub, self(), view.pid)
      render_hook(view, "select_provider_connection", %{"uuid" => uuid})
      start_spinner(view)

      send(view.pid, {:validation_done, uuid, :ok})
      html = render_async(view, 2_000)

      refute html =~ "Loading models..."
      assert html =~ "No API key configured"
    end

    test "a provider error stops loading and shows the translated reason", %{conn: conn} do
      stub = stub_models(fn conn -> Req.Test.transport_error(conn, :nxdomain) end)
      {view, uuid} = form_awaiting_validation(conn, stub)

      log =
        capture_log(fn ->
          send(view.pid, {:validation_done, uuid, :ok})
          html = render_async(view, 2_000)

          refute html =~ "Loading models..."
          assert html =~ "Connection error"
        end)

      assert log =~ "model fetch failed"
    end

    test "runs off the LiveView: the form answers, and shows the slow hint, mid-fetch",
         %{conn: conn} do
      test_pid = self()

      stub =
        stub_models(fn conn ->
          send(test_pid, {:models_requested, self()})

          receive do
            :release -> models_ok(conn)
          after
            5_000 -> models_ok(conn)
          end
        end)

      {view, uuid} = form_awaiting_validation(conn, stub)

      send(view.pid, {:validation_done, uuid, :ok})
      assert_receive {:models_requested, fetcher}, 2_000

      # The request is still open. An inline fetch would hold the LiveView
      # here and this render would time out.
      send(view.pid, :model_fetch_slow)
      html = render(view)
      assert html =~ "Loading models..."
      assert html =~ "taking longer than usual"

      send(fetcher, :release)
      html = render_async(view, 2_000)

      refute html =~ "Loading models..."
      refute html =~ "taking longer than usual"
      assert html =~ "Claude 3 Haiku"
    end

    test "a result for a connection switched away from mid-fetch is dropped", %{conn: conn} do
      test_pid = self()

      stub =
        stub_models(fn conn ->
          send(test_pid, {:models_requested, self()})

          receive do
            :release -> models_ok(conn)
          after
            5_000 -> models_ok(conn)
          end
        end)

      {view, uuid} = form_awaiting_validation(conn, stub)
      %{uuid: other} = seed_openrouter_connection("other-#{System.unique_integer([:positive])}")

      send(view.pid, {:validation_done, uuid, :ok})
      assert_receive {:models_requested, fetcher}, 2_000

      render_hook(view, "select_provider_connection", %{"uuid" => other})
      send(fetcher, :release)
      html = render_async(view, 2_000)

      refute html =~ "Claude 3 Haiku"
      refute html =~ "Loading models..."
      assert html =~ "Enter model ID"
    end

    test "a result for a model type switched away from mid-fetch is dropped", %{conn: conn} do
      test_pid = self()

      stub =
        stub_models(fn conn ->
          send(test_pid, {:models_requested, self()})

          receive do
            :release -> models_ok(conn)
          after
            5_000 -> models_ok(conn)
          end
        end)

      {view, uuid} = form_awaiting_validation(conn, stub)

      send(view.pid, {:validation_done, uuid, :ok})
      assert_receive {:models_requested, fetcher}, 2_000

      # The connection was picked while it had no key, so the form holds it
      # as not connected and the type switch starts no fetch of its own.
      render_hook(view, "select_model_type", %{"model_type" => "tts"})
      send(fetcher, :release)
      html = render_async(view, 2_000)

      refute html =~ "Claude 3 Haiku"
    end
  end

  describe "no API key in the log" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "the whole flow, for every validation result", %{conn: conn} do
      log =
        capture_log([level: :debug], fn ->
          for result <- [:ok, {:ok, %{fact: "x"}}, :unverified, {:error, "nope"}] do
            stub = stub_models(&models_ok/1)
            {view, uuid} = form_awaiting_validation(conn, stub)
            send(view.pid, {:validation_done, uuid, result})
            render_async(view, 2_000)
          end
        end)

      refute log =~ @api_key
    end

    test "a message the form does not handle is logged by shape, not content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, {:validation_done, Ecto.UUID.generate(), :ok, @api_key})
          send(view.pid, {:fetch_models, @api_key, Ecto.UUID.generate()})
          send(view.pid, %URI{host: @api_key})
          send(view.pid, @api_key)
          render(view)
        end)

      assert log =~
               "[PhoenixKitAI.Web.EndpointForm] unhandled handle_info: {:validation_done, …}/4"

      assert log =~ "unhandled handle_info: {:fetch_models, …}/3"
      assert log =~ "unhandled handle_info: %URI{}"
      assert log =~ "unhandled handle_info: binary"
      refute log =~ @api_key
    end
  end
end
