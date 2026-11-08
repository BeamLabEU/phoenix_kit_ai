defmodule PhoenixKitAI.Web.PlaygroundTranscribeTest do
  @moduledoc """
  The Playground's Speech to text card and its Dictate button: a clip
  recorded (core's recorder, delivered as `{:audio_recorded, id, clip}`) or
  picked as a file, written down through `PhoenixKitAI.transcribe/3` against
  a `Req.Test` stub, run again with other settings, compared and used as the
  chat message.

  `Recorder` stands in for core's audio recorder, which the locked core may
  not have; the card only renders it and takes its message.
  """
  use PhoenixKitAI.LiveCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @wait 5_000

  @catalogue [
    %{
      "id" => "google/gemini-2.5-flash",
      "name" => "Gemini 2.5 Flash",
      "architecture" => %{
        "input_modalities" => ["text", "image", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["temperature", "response_format", "structured_outputs"]
    },
    %{
      "id" => "anthropic/claude-sonnet",
      "name" => "Claude Sonnet",
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["temperature"]
    }
  ]

  defmodule Recorder do
    @moduledoc false
    use Phoenix.Component

    def audio_recorder(assigns) do
      ~H"""
      <button type="button" id={@id} data-busy={to_string(@busy)} data-format={@format}>
        {@label}
      </button>
      """
    end

    def error_message(reason), do: "recorder says #{reason}"
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

    user_uuid = Fixtures.confirmed_user_fixture().uuid
    conn = put_test_scope(build_conn(), fake_scope(user_uuid: user_uuid))

    {:ok,
     conn: conn,
     user_uuid: user_uuid,
     endpoint: fixture_endpoint(name: "Ears", model: "google/gemini-2.5-flash")}
  end

  # Answers the catalogue, a chat call (the words as the JSON asked for) and
  # the speech-to-text API, telling the test what each POST carried.
  defp stub(words \\ "Twenty sheets of 18 mm.") do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", _path} ->
          Req.Test.json(conn, %{"data" => @catalogue})

        {"POST", "/api/v1/audio/transcriptions"} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:multipart, raw})
          Req.Test.json(conn, %{"text" => " #{words} ", "language" => "en", "duration" => 0.1})

        {"POST", _path} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:chat, Jason.decode!(raw)})
          Req.Test.json(conn, chat_answer(words))
      end
    end)
  end

  defp chat_answer(words) do
    %{
      "model" => "google/gemini-2.5-flash",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => Jason.encode!(%{"text" => words, "language" => "en"})
          },
          "finish_reason" => "stop"
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

  defp open(conn, endpoint) do
    {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
    Req.Test.allow(__MODULE__, self(), view.pid)
    render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})
    view
  end

  defp record(view) do
    clip = %{data: wav(), format: "wav", content_type: "audio/wav", duration: 0.1}
    send(view.pid, {:audio_recorded, "playground-stt-recorder", clip})
    render_async(view, @wait)
  end

  defp pick_file(view, name \\ "note.wav", content \\ wav()) do
    file =
      file_input(view, "#playground-transcribe-form", :stt_file, [
        %{name: name, content: content, type: "audio/wav"}
      ])

    render_upload(file, name)
  end

  defp submit(view, params \\ %{}) do
    view |> element("#playground-transcribe-form") |> render_submit(params)
    render_async(view, @wait)
  end

  defp rows(endpoint),
    do:
      TestRepo.all(
        from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid, order_by: r.inserted_at)
      )

  defp start_capabilities do
    pid =
      start_supervised!(
        {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    assert :ok = Capabilities.refresh()
  end

  describe "the card" do
    test "appears once an endpoint is chosen, with the recorder and a file picker", %{
      conn: conn,
      endpoint: endpoint
    } do
      {:ok, view, html} = live(conn, "/en/admin/ai/playground")
      refute html =~ "playground-transcribe"

      render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})
      assert has_element?(view, "#playground-transcribe-form")
      assert has_element?(view, ~s(#playground-stt-recorder[data-format="wav_16k"]))
      assert has_element?(view, "#playground-transcribe-form input[type=file]")
      # nothing to write down yet
      assert has_element?(view, "#playground-transcribe-form button[type=submit][disabled]")
    end

    test "without core's recorder, says so and still takes a file", %{
      conn: conn,
      endpoint: endpoint
    } do
      Application.put_env(:phoenix_kit_ai, :audio_recorder, PhoenixKitAI.NoSuchRecorder)
      view = open(conn, endpoint)

      refute has_element?(view, "#playground-stt-recorder")
      assert render(view) =~ "Recording here needs PhoenixKit 3.4 or later"
      assert has_element?(view, "#playground-transcribe-form input[type=file]")
    end
  end

  describe "a recording" do
    test "is kept, played back and written down at once, billed to the user under ai.playground",
         %{conn: conn, endpoint: endpoint, user_uuid: user_uuid} do
      stub()
      view = open(conn, endpoint)

      html = record(view)

      assert has_element?(view, "#playground-stt-clip audio[src^='data:audio/wav;base64,']")
      assert html =~ "Twenty sheets of 18 mm."
      assert has_element?(view, "#playground-stt-results", "Chat with the audio attached")
      assert has_element?(view, "#playground-stt-results .badge", "en")
      assert html =~ "$0.0004"

      assert_received {:chat, %{"messages" => [%{"content" => [_prompt, audio_part | _schema]}]}}
      assert %{"type" => "input_audio", "input_audio" => %{"format" => "wav"}} = audio_part

      assert [
               %Request{
                 request_type: "transcription",
                 user_uuid: ^user_uuid,
                 metadata: %{"task" => "ai.playground", "source" => "PhoenixKitAI.Web.Playground"}
               }
             ] = rows(endpoint)
    end

    test "that cannot be read is an error, and the earlier clip is not written down instead",
         %{conn: conn, endpoint: endpoint} do
      stub()
      view = open(conn, endpoint)
      record(view)
      assert_received {:chat, _body}

      send(view.pid, {:audio_recorded, "playground-stt-recorder", %{data: "", format: "wav"}})
      assert render_async(view, @wait) =~ "Input cannot be empty"
      refute_received {:chat, _body}
      assert [_one] = rows(endpoint)
    end

    test "that has no speech is an answer, not an error", %{conn: conn, endpoint: endpoint} do
      stub("")
      view = open(conn, endpoint)

      assert record(view) =~ "No speech was heard in the recording."
      refute has_element?(view, "#playground-stt-results button", "Use as chat message")
    end
  end

  describe "a picked file" do
    test "is kept as the clip and written down on the button", %{conn: conn, endpoint: endpoint} do
      stub()
      view = open(conn, endpoint)

      pick_file(view)
      assert has_element?(view, "#playground-stt-clip", "note.wav")
      assert has_element?(view, "#playground-stt-clip", "0.1 s")
      refute_received {:chat, _body}

      assert submit(view) =~ "Twenty sheets of 18 mm."
      assert_received {:chat, _body}
    end

    test "with no clip, the button asks for one", %{conn: conn, endpoint: endpoint} do
      view = open(conn, endpoint)
      assert submit(view) =~ "Record something or pick a file first"
    end

    test "can be removed", %{conn: conn, endpoint: endpoint} do
      view = open(conn, endpoint)
      pick_file(view)

      view |> element("#playground-stt-clip button", "Remove") |> render_click()
      refute has_element?(view, "#playground-stt-clip")
    end
  end

  describe "running it again" do
    test "uses the new settings and lists the answers newest first", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = open(conn, endpoint)
      record(view)
      assert_received {:chat, %{"model" => "google/gemini-2.5-flash"}}

      submit(view, %{
        "stt_model" => "google/gemini-2.5-pro",
        "stt_language" => "et",
        "stt_instructions" => "Plywood sizes.",
        "stt_transport" => ""
      })

      assert_received {:chat, %{"model" => "google/gemini-2.5-pro", "messages" => [message]}}
      assert %{"content" => [%{"text" => prompt} | _]} = message
      assert prompt =~ "expected to be in et"
      assert prompt =~ "Plywood sizes."

      html = render(view)
      assert [_, _] = Regex.scan(~r/id="playground-stt-result-\d+"/, html)
      assert html =~ "Language hint: et"
      assert html =~ "With instructions"

      view |> element("#playground-stt-results button", "Clear") |> render_click()
      refute has_element?(view, "#playground-stt-results")
    end

    test "through the speech-to-text API posts the clip as a file", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = open(conn, endpoint)
      pick_file(view)

      html = submit(view, %{"stt_model" => "whisper-1", "stt_transport" => "transcriptions"})

      assert_received {:multipart, raw}
      assert raw =~ ~s(name="model"\r\n\r\nwhisper-1)
      assert raw =~ ~s(filename="audio.wav")
      refute_received {:chat, _body}

      assert html =~ "Twenty sheets of 18 mm."
      assert has_element?(view, "#playground-stt-results", "Speech-to-text API")
    end

    test "keeps the clip and the answers when the endpoint changes, but not its model override",
         %{conn: conn, endpoint: endpoint} do
      stub()
      other = fixture_endpoint(name: "Other ears", model: "google/gemini-2.5-flash")
      view = open(conn, endpoint)
      record(view)
      render_change(view, "stt_change", %{"stt_model" => "google/gemini-2.5-pro"})

      render_change(view, "change", %{"endpoint_uuid" => other.uuid})

      assert has_element?(view, "#playground-stt-clip")
      assert has_element?(view, "#playground-stt-results", "Ears")
      assert has_element?(view, ~s(#playground-stt-model[value=""]))
    end
  end

  describe "the hint and the model suggestions" do
    test "come from the capability cache", %{conn: conn, endpoint: endpoint} do
      stub()
      start_capabilities()
      view = open(conn, endpoint)

      assert has_element?(
               view,
               ~s(#playground-stt-models option[value="google/gemini-2.5-flash"])
             )

      refute has_element?(
               view,
               ~s(#playground-stt-models option[value="anthropic/claude-sonnet"])
             )

      assert has_element?(view, "#playground-stt-hint", "takes audio")

      render_change(view, "stt_change", %{"stt_model" => "anthropic/claude-sonnet"})
      assert has_element?(view, "#playground-stt-hint.text-error", "does not take audio")

      render_change(view, "stt_change", %{"stt_transport" => "transcriptions"})
      assert has_element?(view, "#playground-stt-hint", "/audio/transcriptions")
    end

    test "a model that can't hear is refused before any call, on the card", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      start_capabilities()
      view = open(conn, endpoint)
      render_change(view, "stt_change", %{"stt_model" => "anthropic/claude-sonnet"})

      html = record(view)

      assert html =~ "cannot do what this task needs"
      refute_received {:chat, _body}
      refute has_element?(view, "#playground-stt-results")
    end
  end

  describe "the answer as the chat message" do
    test "goes into the message, leaving a chosen prompt", %{conn: conn, endpoint: endpoint} do
      stub()
      prompt = fixture_prompt(content: "Say hi to {{Name}}")
      view = open(conn, endpoint)
      render_change(view, "change", %{"prompt_uuid" => prompt.uuid})
      record(view)

      html =
        view |> element("#playground-stt-results button", "Use as chat message") |> render_click()

      assert html =~ "The words are in the chat message above."
      assert view |> element("textarea[name=message]") |> render() =~ "Twenty sheets of 18 mm."
    end
  end

  describe "the Dictate button" do
    test "sits under the chat message and writes down with the card's settings", %{
      conn: conn,
      endpoint: endpoint
    } do
      stub()
      view = open(conn, endpoint)
      assert has_element?(view, ~s(#playground-dictate-dictate[phx-hook="PhoenixKitAIDictate"]))
      render_change(view, "stt_change", %{"stt_model" => "google/gemini-2.5-pro"})

      clip = %{data: wav(), format: "wav", content_type: "audio/wav", duration: 0.1}

      Phoenix.LiveView.send_update(view.pid, PhoenixKitAI.Web.Components.Dictate,
        id: "playground-dictate",
        audio_recorded: {"playground-dictate", clip}
      )

      render_async(view, @wait)
      assert_receive {:chat, %{"model" => "google/gemini-2.5-pro"}}, @wait

      assert [%Request{metadata: %{"source" => "PhoenixKitAI.Web.Playground.Dictate"}}] =
               rows(endpoint)
    end

    test "is not there without an endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      refute has_element?(view, "#playground-dictate-dictate")
    end
  end

  test "a realtime event is logged by its type, never its words", %{conn: conn} do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, {:xai_realtime_event, %{"type" => "text.done", "text" => "secret words"}})
        render(view)
      end)

    assert log =~ ~s(xai realtime event: "text.done")
    refute log =~ "secret"
  end
end
