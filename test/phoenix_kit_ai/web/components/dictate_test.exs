defmodule PhoenixKitAI.Web.Components.DictateTest do
  @moduledoc """
  The dictation component on a page: a recording in, the words out, through
  `PhoenixKitAI.transcribe/3` against `Req.Test` stubs.

  `Recorder` stands in for core's audio recorder, which the locked core does not
  have: the same `audio_recorder/1`, `error_message/1` and delivery through `target`.
  """
  use PhoenixKitAI.LiveCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.Web.Components.Dictate

  # A clip goes through a task, the database and a stub: longer than the 100 ms
  # `assert_receive` and `render_async` wait by default on a cold or busy machine.
  @wait 5_000

  @answer %{"text" => "  Twenty sheets of 18 mm.\n", "language" => "en"}

  @catalogue [
    %{
      "id" => "google/gemini-2.5-flash",
      "architecture" => %{
        "input_modalities" => ["text", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["temperature", "response_format", "structured_outputs"]
    },
    %{
      "id" => "anthropic/claude-sonnet",
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["temperature"]
    }
  ]

  defmodule Recorder do
    @moduledoc false
    use Phoenix.LiveComponent

    def audio_recorder(assigns) do
      ~H"""
      <.live_component
        module={__MODULE__}
        id={@id}
        format={@format}
        max_seconds={@max_seconds}
        label={@label}
        busy={@busy}
        errors={@errors}
        target={@target}
      />
      """
    end

    def error_message(reason), do: "recorder says #{reason}"

    @impl true
    def render(assigns) do
      ~H"""
      <button
        id={@id}
        phx-click="record"
        phx-target={@myself}
        data-busy={to_string(@busy)}
        data-format={@format}
        data-seconds={@max_seconds}
        data-errors={@errors}
      >
        {@label}
      </button>
      """
    end

    @impl true
    def handle_event("record", %{"error" => reason}, socket) do
      deliver(socket, :audio_recorder_error, String.to_existing_atom(reason))
      {:noreply, socket}
    end

    def handle_event("record", _params, socket) do
      clip = %{data: wav(), format: "wav", content_type: "audio/wav", duration: 0.1}
      deliver(socket, :audio_recorded, clip)
      {:noreply, socket}
    end

    defp deliver(%{assigns: %{target: target, id: id}}, tag, payload),
      do: send_update(target, %{tag => {id, payload}})

    # A PCM WAV: 16 kHz, mono, 16-bit, a tenth of a second.
    defp wav do
      samples = :binary.copy(<<0, 0>>, 1_600)

      "RIFF" <>
        <<36 + byte_size(samples)::little-32>> <>
        "WAVEfmt " <>
        <<16::little-32, 1::little-16, 1::little-16, 16_000::little-32, 32_000::little-32,
          2::little-16, 16::little-16>> <>
        "data" <> <<byte_size(samples)::little-32>> <> samples
    end
  end

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    @impl true
    def mount(_params, %{"attrs" => attrs, "test" => test}, socket),
      do: {:ok, Phoenix.Component.assign(socket, attrs: attrs, test: test)}

    @impl true
    def render(assigns) do
      ~H"""
      <.live_component module={PhoenixKitAI.Web.Components.Dictate} id="voice" {@attrs} />
      """
    end

    @impl true
    def handle_info({:attrs, attrs}, socket),
      do:
        {:noreply,
         Phoenix.Component.assign(socket, :attrs, Map.merge(socket.assigns.attrs, attrs))}

    def handle_info(message, socket) do
      send(socket.assigns.test, message)
      {:noreply, socket}
    end
  end

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :audio_recorder, Recorder)

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      Application.delete_env(:phoenix_kit_ai, :audio_recorder)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    {:ok, endpoint: fixture_endpoint(model: "google/gemini-2.5-flash")}
  end

  defp stub(answer \\ @answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{"data" => @catalogue})

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:post, Jason.decode!(raw)})
          Req.Test.json(conn, chat_answer(answer))
      end
    end)
  end

  defp chat_answer(answer, finish_reason \\ "stop") do
    %{
      "model" => "google/gemini-2.5-flash",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => Jason.encode!(answer)},
          "finish_reason" => finish_reason
        }
      ],
      "usage" => %{
        "prompt_tokens" => 120,
        "completion_tokens" => 14,
        "total_tokens" => 134,
        "cost" => 0.0004
      }
    }
  end

  defp mount_with(conn, attrs) do
    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"attrs" => Map.new(attrs), "test" => self()})

    Req.Test.allow(__MODULE__, self(), view.pid)
    view
  end

  defp record(view, params \\ %{}), do: view |> element("#voice") |> render_click(params)

  defp rows(endpoint),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))

  describe "a recording" do
    test "gives the page the trimmed words and writes the task's row", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = mount_with(conn, endpoint: endpoint.uuid)

      record(view)

      assert_receive {:dictated, "voice", "Twenty sheets of 18 mm."}, @wait
      assert render_async(view, @wait) =~ "Dictate"

      assert [
               %Request{
                 request_type: "transcription",
                 metadata: %{
                   "task" => "ai.dictation",
                   "source" => "PhoenixKitAI.Web.Components.Dictate"
                 }
               }
             ] = rows(endpoint)
    end

    test "takes the endpoint by name and as a struct", %{conn: conn, endpoint: endpoint} do
      stub()

      for value <- [endpoint.name, endpoint] do
        conn |> mount_with(endpoint: value) |> record()
        assert_receive {:dictated, "voice", _text}, @wait
      end
    end

    test "passes the other attributes to transcribe/3; nil is not given", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      user = Fixtures.user_fixture()

      view =
        mount_with(conn,
          endpoint: endpoint.uuid,
          model: "google/gemini-2.5-flash-lite",
          instructions: "Plywood: 2500×1250, BB/BB.",
          language: "et",
          user_uuid: user.uuid,
          task: "host.voice",
          source: "Host.Voice",
          run: "run-1",
          step: "voice",
          temperature: nil
        )

      record(view)

      assert_receive {:post, %{"model" => "google/gemini-2.5-flash-lite"} = body}, @wait
      assert_receive {:dictated, "voice", _text}, @wait
      assert Jason.encode!(body["messages"]) =~ "2500×1250"
      assert body["temperature"] == 0

      user_uuid = user.uuid

      assert [
               %Request{
                 user_uuid: ^user_uuid,
                 metadata: %{
                   "task" => "host.voice",
                   "source" => "Host.Voice",
                   "run" => "run-1",
                   "step" => "voice"
                 }
               }
             ] = rows(endpoint)
    end
  end

  describe "while writing down" do
    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:held, self()})

        receive do
          :release -> Req.Test.json(conn, chat_answer(@answer))
        end
      end)

      :ok
    end

    test "the recorder is held back and the page told, until the words are in", %{
      conn: conn,
      endpoint: endpoint
    } do
      view = mount_with(conn, endpoint: endpoint.uuid)
      assert has_element?(view, ~s(#voice[data-busy="false"]))

      record(view)
      assert_receive {:held, task}, @wait

      assert has_element?(view, ~s(#voice[data-busy="true"]))
      assert render(view) =~ "Writing down what you said…"

      send(task, :release)
      assert_receive {:dictated, "voice", _text}, @wait

      assert has_element?(view, ~s(#voice[data-busy="false"]))
      refute render(view) =~ "Writing down what you said…"
    end

    test "the refusal of a second clip shows while it holds, and not after the words", %{
      conn: conn,
      endpoint: endpoint
    } do
      view = mount_with(conn, endpoint: endpoint.uuid)

      record(view)
      assert_receive {:held, task}, @wait

      record(view)
      assert render(view) =~ "Still writing down the last recording"

      send(task, :release)
      assert_receive {:dictated, "voice", _text}, @wait
      refute render(view) =~ "Still writing down the last recording"
    end

    test "a second clip is refused and the first one's words still arrive", %{
      conn: conn,
      endpoint: endpoint
    } do
      view = mount_with(conn, endpoint: endpoint.uuid, show_error: false)

      record(view)
      assert_receive {:held, task}, @wait

      record(view)
      assert_receive {:dictation_failed, "voice", :busy}, @wait
      refute_received {:held, _second}

      send(task, :release)
      assert_receive {:dictated, "voice", _text}, @wait
    end
  end

  test "nil on an attribute of its own means not given", %{conn: conn, endpoint: endpoint} do
    view = mount_with(conn, endpoint: endpoint.uuid, busy: nil, max_seconds: nil)
    assert has_element?(view, ~s(#voice[data-busy="false"][data-seconds="180"]))

    send(view.pid, {:attrs, %{busy: true}})
    assert has_element?(view, ~s(#voice[data-busy="true"]))

    send(view.pid, {:attrs, %{busy: nil}})
    assert has_element?(view, ~s(#voice[data-busy="false"]))
  end

  test "a name of 16 bytes is a name, not a raw uuid", %{conn: conn} do
    stub()
    endpoint = fixture_endpoint(name: "Label reader 123", model: "google/gemini-2.5-flash")

    view = mount_with(conn, endpoint: endpoint.name)
    record(view)

    assert_receive {:dictated, "voice", _text}, @wait
  end

  test "the page's busy holds the recorder back on its own", %{conn: conn, endpoint: endpoint} do
    view = mount_with(conn, endpoint: endpoint.uuid, busy: false)

    send(view.pid, {:attrs, %{busy: true}})
    assert has_element?(view, ~s(#voice[data-busy="true"]))
  end

  test "the recorder gets the format and the limits", %{conn: conn, endpoint: endpoint} do
    view = mount_with(conn, endpoint: endpoint.uuid, label: "Say it", max_seconds: 60)
    assert has_element?(view, ~s(#voice[data-format="wav_16k"][data-seconds="60"]), "Say it")

    view = mount_with(conn, endpoint: endpoint.uuid)
    assert has_element?(view, ~s(#voice[data-seconds="180"]), "Dictate")
  end

  test "with core's recorder missing, nothing is shown to record with", %{
    conn: conn,
    endpoint: endpoint
  } do
    Application.put_env(:phoenix_kit_ai, :audio_recorder, Does.Not.Exist)

    view = mount_with(conn, endpoint: endpoint.uuid)
    refute has_element?(view, "#voice")
    assert has_element?(view, "#voice-dictate")
  end

  describe "into" do
    test "pushes the words to the field and still tells the page", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = mount_with(conn, endpoint: endpoint.uuid, into: "inquiry-text", mode: :replace)
      assert has_element?(view, ~s(#voice-dictate[phx-hook="PhoenixKitAIDictate"]))

      record(view)

      assert_push_event(view, "phoenix_kit_ai:dictated:voice-dictate", %{
        into: "inquiry-text",
        mode: :replace,
        text: "Twenty sheets of 18 mm."
      })

      assert_receive {:dictated, "voice", "Twenty sheets of 18 mm."}, @wait
    end

    test "appends by default", %{conn: conn, endpoint: endpoint} do
      stub()
      view = mount_with(conn, endpoint: endpoint.uuid, into: "inquiry-text")

      record(view)

      assert_push_event(view, "phoenix_kit_ai:dictated:voice-dictate", %{mode: :append})
    end

    test "without it the page only gets the message and no hook is asked for", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = mount_with(conn, endpoint: endpoint.uuid)
      refute has_element?(view, "[phx-hook]")

      record(view)

      assert_receive {:dictated, "voice", _text}, @wait
      refute_push_event(view, "phoenix_kit_ai:dictated:voice-dictate", %{})
    end
  end

  describe "a failure" do
    test "no speech is shown, and the page hears nothing", %{conn: conn, endpoint: endpoint} do
      stub(%{"text" => "  \n", "language" => nil})
      view = mount_with(conn, endpoint: endpoint.uuid, into: "inquiry-text")

      record(view)

      assert render_async(view, @wait) =~ "We couldn&#39;t hear anything"
      refute_received {:dictated, _id, _text}
      refute_received {:dictation_failed, _id, _reason}
      refute_push_event(view, "phoenix_kit_ai:dictated:voice-dictate", %{})
    end

    test "with show_error={false} goes to the page and nothing is shown", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub(%{"text" => ""})
      view = mount_with(conn, endpoint: endpoint.uuid, show_error: false)

      record(view)

      assert_receive {:dictation_failed, "voice", :no_speech}, @wait
      refute render(view) =~ "hear anything"
    end

    test "is cleared by the next clip", %{conn: conn, endpoint: endpoint} do
      stub(%{"text" => ""})
      view = mount_with(conn, endpoint: endpoint.uuid)

      record(view)
      assert render_async(view, @wait) =~ "hear anything"

      stub()
      record(view)
      assert_receive {:dictated, "voice", _text}, @wait
      refute render(view) =~ "hear anything"
    end

    test "without an endpoint, or with a gone one, says so", %{conn: conn} do
      for attrs <- [[], [endpoint: ""], [endpoint: "No Such"], [endpoint: Ecto.UUID.generate()]] do
        view = mount_with(conn, attrs)
        record(view)
        assert render_async(view, @wait) =~ "No AI endpoint is set up for dictation."
      end
    end

    test "says a model can't hear when the guard refuses it", %{conn: conn, endpoint: endpoint} do
      stub()

      pid =
        start_supervised!(
          {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
        )

      Req.Test.allow(__MODULE__, self(), pid)
      assert :ok = Capabilities.refresh()

      view = mount_with(conn, endpoint: endpoint.uuid, model: "anthropic/claude-sonnet")
      record(view)

      assert render_async(view, @wait) =~ "model can&#39;t hear"
      refute_received {:post, _body}
    end

    test "keeps the model's words out of the reason", %{conn: conn, endpoint: endpoint} do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, chat_answer(%{"text" => "the secret words"}, "length"))
      end)

      view = mount_with(conn, endpoint: endpoint.uuid, show_error: false)
      record(view)

      assert_receive {:dictation_failed, "voice", :output_truncated}, @wait
    end

    # Only the component's own line: the raise also reaches `Task`'s crash report,
    # which is not ours and is written whenever it is written.
    test "a task that dies is told like any failure, and our log line has no words", %{
      conn: conn,
      endpoint: endpoint
    } do
      Req.Test.stub(__MODULE__, fn _conn -> raise "the secret words" end)
      view = mount_with(conn, endpoint: endpoint.uuid, show_error: false)

      log =
        capture_log(fn ->
          record(view)
          assert_receive {:dictation_failed, "voice", :task_failed}, @wait
        end)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "task exited"))
      refute line =~ "secret"
    end
  end

  describe "the recorder's errors" do
    test "are the recorder's to show by default", %{conn: conn, endpoint: endpoint} do
      view = mount_with(conn, endpoint: endpoint.uuid)
      assert has_element?(view, ~s(#voice[data-errors="inline"]))
    end

    test "reach a page that handles its own", %{conn: conn, endpoint: endpoint} do
      view = mount_with(conn, endpoint: endpoint.uuid, show_error: false)
      assert has_element?(view, ~s(#voice[data-errors="notify"]))

      for reason <- [:denied, :unavailable, :unreadable, :too_large, :failed] do
        record(view, %{"error" => Atom.to_string(reason)})
        assert_receive {:dictation_failed, "voice", ^reason}, @wait
      end
    end
  end

  describe "message/1" do
    test "has words for the limits, the blocks and the rest" do
      assert Dictate.message({:budget_exceeded, :global}) =~ "usage limit"
      assert Dictate.message({:task_limit_exceeded, :user, :money, :day}) =~ "usage limit"
      assert Dictate.message({:task_blocked, "ai.dictation"}) =~ "isn't available"
      assert Dictate.message({:task_disabled, "ai.dictation"}) =~ "isn't available"
      assert Dictate.message({:model_unfit, [:audio_input]}) =~ "can't hear"
      assert Dictate.message({:model_unverified, [:audio_input]}) =~ "verified"
      assert Dictate.message({:audio_too_large, 2, 1}) =~ "too long"
      assert Dictate.message(:output_truncated) =~ "too long"
      assert Dictate.message(:busy) =~ "Still writing"
      assert Dictate.message(:denied) == "recorder says denied"
      assert Dictate.message({:api_error, 500}) =~ "couldn't write that down"
    end
  end

  test "ai.dictation is declared with its need" do
    assert %PhoenixKitAI.TaskSpec{needs: [:audio_input], module: PhoenixKitAI} =
             PhoenixKitAI.Tasks.get("ai.dictation")
  end
end
