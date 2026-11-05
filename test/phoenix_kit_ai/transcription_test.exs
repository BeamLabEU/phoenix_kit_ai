defmodule PhoenixKitAI.TranscriptionTest do
  @moduledoc """
  `PhoenixKitAI.transcribe/3` end to end against `Req.Test` stubs: the chat
  path (OpenRouter `input_audio`, a JSON answer), the transcriptions path
  (multipart `/audio/transcriptions`), "no speech" as an answer, the guard's
  `:audio_input` on both `transcribe/3` and `complete/3`, the usage row (the
  audio never in it, the words under the content gate), the monthly spend cap
  and the errors that stop a call before any request.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.{Budget, Capabilities, Request}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @catalogue [
    %{
      "id" => "google/gemini-2.5-flash",
      "architecture" => %{
        "input_modalities" => ["text", "image", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["response_format", "structured_outputs", "temperature"]
    },
    %{
      "id" => "anthropic/claude-sonnet-5.5",
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["tools", "temperature"]
    }
  ]

  setup do
    PhoenixKitAI.RequestCache.clear()

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
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :capture_request_content)
    end)

    :ok
  end

  # A PCM WAV: 16 kHz, mono, 16-bit, `seconds` long.
  defp wav(seconds) do
    data_size = round(32_000 * seconds)

    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, 16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data",
      data_size::little-32, :binary.copy(<<7>>, data_size)::binary>>
  end

  defp endpoint!(attrs \\ %{}) do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "STT-EP-#{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "anthropic/claude-sonnet-5.5",
            api_key: "sk-test-key"
          },
          attrs
        )
      )

    ep
  end

  defp rows(ep),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.uuid))

  defp chat_answer(content, extra \\ %{}) do
    Map.merge(
      %{
        "model" => "google/gemini-2.5-flash",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 120,
          "completion_tokens" => 14,
          "total_tokens" => 134,
          "cost" => 0.0004
        }
      },
      extra
    )
  end

  # The catalogue on GET; on POST the request is sent to the test process
  # (raw body and content type) and `answer` is the reply.
  defp stub(answer, status \\ 200) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{"data" => @catalogue})

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)

          send(
            test_pid,
            {:post, conn.request_path, Plug.Conn.get_req_header(conn, "content-type"), raw}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(answer))
      end
    end)
  end

  defp start_catalogue do
    pid =
      start_supervised!(
        {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    assert :ok = Capabilities.refresh()
    pid
  end

  defp form_field(raw, name) do
    case Regex.run(
           ~r/name="#{name}"(?:; filename="[^"]*")?\r\n(?:[^\r\n]+\r\n)*\r\n(.*?)\r\n--/s,
           raw
         ) do
      [_, value] -> value
      _ -> nil
    end
  end

  describe "the chat path (OpenRouter)" do
    test "sends the audio as input_audio and reads the JSON answer" do
      stub(chat_answer(~s({"text": "  Vaja on 150 lehte 18 mm vineeri.  ", "language": "et"})))
      ep = endpoint!()
      audio = wav(1.5)

      assert {:ok, result} =
               PhoenixKitAI.transcribe(ep.uuid, audio,
                 model: "google/gemini-2.5-flash",
                 instructions: "Sizes as 2500×1250.",
                 source: "InquiryVoice"
               )

      assert %{
               text: "Vaja on 150 lehte 18 mm vineeri.",
               language: "et",
               model: "google/gemini-2.5-flash",
               transport: :chat,
               duration: 1.5,
               request_uuid: request_uuid,
               cost: cost
             } = result

      assert Decimal.equal?(cost, Decimal.new("0.0004"))

      assert_received {:post, "/api/v1/chat/completions", _type, raw}
      body = Jason.decode!(raw)

      assert body["model"] == "google/gemini-2.5-flash"
      assert body["temperature"] == 0
      assert body["response_format"]["type"] == "json_schema"

      [%{"role" => "user", "content" => [prompt, audio_part, _schema_suffix]}] = body["messages"]
      assert prompt["text"] =~ "Further instructions:\nSizes as 2500×1250."

      assert audio_part == %{
               "type" => "input_audio",
               "input_audio" => %{"data" => Base.encode64(audio), "format" => "wav"}
             }

      [row] = rows(ep)
      assert row.uuid == request_uuid
      assert row.request_type == "transcription"
      assert row.model == "google/gemini-2.5-flash"
      assert row.input_tokens == 120
      assert row.status == "success"

      assert %{
               "transport" => "chat",
               "audio_format" => "wav",
               "audio_bytes" => audio_bytes,
               "audio_seconds" => 1.5,
               "language" => "et",
               "response" => "Vaja on 150 lehte 18 mm vineeri.",
               "source" => "InquiryVoice",
               "messages" => [%{"content" => [_, stored_audio, _]}]
             } = row.metadata

      assert audio_bytes == byte_size(audio)

      assert stored_audio == %{
               "type" => "input_audio",
               "input_audio" => %{
                 "format" => "wav",
                 "bytes" => byte_size(audio),
                 "omitted" => true
               }
             }

      refute Jason.encode!(row.metadata) =~ Base.encode64(audio)
    end

    test "no speech is an answer with empty text, not an error" do
      stub(chat_answer(~s({"text": "", "language": ""})))
      ep = endpoint!()

      assert {:ok, %{text: "", language: nil}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.5), model: "google/gemini-2.5-flash")

      assert [%Request{status: "success", metadata: %{"response" => ""}}] = rows(ep)
    end

    test "capture_request_content: false keeps the words and instructions out of the row" do
      stub(chat_answer(~s({"text": "a private order", "language": "en"})))
      ep = endpoint!()

      assert {:ok, %{text: "a private order"}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.2),
                 model: "google/gemini-2.5-flash",
                 instructions: "secret context",
                 capture_request_content: false
               )

      [row] = rows(ep)
      assert row.metadata["content_redacted"] == true
      refute Map.has_key?(row.metadata, "messages")
      refute Map.has_key?(row.metadata, "response")
      refute Jason.encode!(row.metadata) =~ "secret context"
    end

    test "an answer that is not the JSON asked for is billed once and returned as an error" do
      stub(chat_answer("Sure! Here is what they said: hello"))
      ep = endpoint!()

      assert {:error, {:no_json_in_response, "Sure!" <> _}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.2), model: "google/gemini-2.5-flash")

      assert [%Request{status: "success", metadata: %{"unparsed" => true}}] = rows(ep)
    end

    test "a provider error is one error row without the audio" do
      stub(%{"error" => %{"message" => "boom"}}, 500)
      ep = endpoint!()
      audio = wav(0.2)

      assert {:error, {:api_error, 500}} =
               PhoenixKitAI.transcribe(ep.uuid, audio, model: "google/gemini-2.5-flash")

      assert [%Request{status: "error", request_type: "transcription", metadata: metadata}] =
               rows(ep)

      assert metadata["audio_bytes"] == byte_size(audio)
      refute Jason.encode!(metadata) =~ Base.encode64(audio)
    end
  end

  describe "the guard's audio need" do
    test "a model the catalogue says does not hear is refused before any request" do
      stub(chat_answer("{}"))
      ep = endpoint!()
      start_catalogue()

      assert {:error, {:model_unfit, [:audio_input]}} = PhoenixKitAI.transcribe(ep.uuid, wav(0.2))
      refute_received {:post, _, _, _}

      assert [%Request{request_type: "transcription", metadata: %{"refused" => true}}] = rows(ep)
    end

    test "a model: that hears passes" do
      stub(chat_answer(~s({"text": "ok", "language": "en"})))
      ep = endpoint!()
      start_catalogue()

      assert {:ok, %{text: "ok"}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.2), model: "google/gemini-2.5-flash")
    end

    test "complete/3 with an input_audio part is checked the same way" do
      stub(chat_answer("hello"))
      ep = endpoint!()
      start_catalogue()

      messages = [
        %{
          role: "user",
          content: [
            %{"type" => "text", "text" => "Write it down"},
            %{"type" => "input_audio", "input_audio" => %{"data" => "AAAA", "format" => "wav"}}
          ]
        }
      ]

      assert {:error, {:model_unfit, [:audio_input]}} = PhoenixKitAI.complete(ep.uuid, messages)

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, messages, model: "google/gemini-2.5-flash")

      assert [%Request{metadata: %{"refused" => true}}, %Request{metadata: ok}] = rows(ep)

      assert [%{"content" => [_, %{"input_audio" => %{"bytes" => 3, "omitted" => true}}]}] =
               ok["messages"]

      refute Jason.encode!(ok) =~ "AAAA"
    end
  end

  describe "the transcriptions path" do
    test "the configured retry applies when the call names none" do
      Application.put_env(:phoenix_kit_ai, :retry, max_attempts: 2, base_delay: 1, max_delay: 1)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :retry) end)
      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: Plug.Conn.send_resp(conn, 503, "{}"),
          else: Req.Test.json(conn, %{"text" => "Hello."})
      end)

      ep = endpoint!(%{provider: "openai", model: "whisper-1"})

      assert {:ok, %{text: "Hello."}} = PhoenixKitAI.transcribe(ep.uuid, wav(1))
      assert :counters.get(counter, 1) == 2
    end

    test "posts multipart to /audio/transcriptions for a speech-to-text model" do
      stub(%{"text" => " Hello there. ", "usage" => %{"type" => "duration", "seconds" => 2}})
      ep = endpoint!(%{provider: "openai", model: "whisper-1"})
      audio = wav(2)

      assert {:ok,
              %{
                text: "Hello there.",
                transport: :transcriptions,
                model: "whisper-1",
                duration: 2.0,
                cost: nil
              }} =
               PhoenixKitAI.transcribe(ep.uuid, audio,
                 instructions: "Plywood, BB/BB",
                 language: "en"
               )

      assert_received {:post, "/v1/audio/transcriptions", [type], raw}
      assert type =~ "multipart/form-data"
      assert form_field(raw, "model") == "whisper-1"
      assert form_field(raw, "prompt") == "Plywood, BB/BB"
      assert form_field(raw, "language") == "en"
      assert form_field(raw, "temperature") == "0"
      assert raw =~ ~s(name="file"; filename="audio.wav")
      assert raw =~ "content-type: audio/wav"

      [row] = rows(ep)

      assert %{
               "transport" => "transcriptions",
               "input" => "Plywood, BB/BB",
               "response" => "Hello there.",
               "billed_audio_seconds" => 2.0
             } = row.metadata

      refute Map.has_key?(row.metadata, "messages")
    end

    test "Mistral is not sent the prompt" do
      stub(%{"text" => "Bonjour", "language" => "fr"})
      ep = endpoint!(%{provider: "mistral", model: "voxtral-mini-transcribe-2507"})

      assert {:ok, %{text: "Bonjour", language: "fr"}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.2), instructions: "ignored here")

      assert_received {:post, "/v1/audio/transcriptions", _type, raw}
      assert form_field(raw, "prompt") == nil
    end
  end

  describe "the monthly spend cap" do
    setup do
      Budget.reset_warnings()
      on_exit(&Budget.reset_warnings/0)
    end

    test "counts a transcription's cost and refuses the next one before the provider" do
      stub(chat_answer(~s({"text": "Tere.", "language": "et"})))
      ep = endpoint!()
      {:ok, _} = Budget.set_limit(:global_month, "0.0004")
      opts = [model: "google/gemini-2.5-flash"]

      assert {:ok, %{text: "Tere."}} = PhoenixKitAI.transcribe(ep.uuid, wav(0.2), opts)
      assert_received {:post, _, _, _}

      assert {:error, {:budget_exceeded, :global_month}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.3), opts)

      refute_received {:post, _, _, _}

      assert [%Request{metadata: %{"refused" => true}}] =
               Enum.filter(rows(ep), &(&1.status == "error"))
    end
  end

  describe "before any request" do
    test "empty, too large and unreadable audio write no row and call nothing" do
      stub(chat_answer("{}"))
      ep = endpoint!()

      assert {:error, :empty_input} = PhoenixKitAI.transcribe(ep.uuid, "")

      assert {:error, {:audio_too_large, _, 10}} =
               PhoenixKitAI.transcribe(ep.uuid, wav(0.1), max_audio_bytes: 10)

      assert {:error, :unknown_audio_format} = PhoenixKitAI.transcribe(ep.uuid, "not audio")

      refute_received {:post, _, _, _}
      assert rows(ep) == []
    end
  end
end
