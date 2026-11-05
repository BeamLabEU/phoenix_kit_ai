defmodule PhoenixKitAI.TranscriptionUnitTest do
  @moduledoc """
  The pure parts of speech to text and of audio in chat: what a usage row
  keeps of a media part (`MessageParts`), how a recording is read and named
  (`Transcription.normalize/2`, `wav_seconds/1`), which path a call takes
  (`transport/2`), what the guard reads from a call (`:audio_input`), the
  catalogue's audio flag, and the Usage tab's rendering of content parts.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitAI.{Capabilities, Endpoint, Guard, MessageParts, TaskSpec, Transcription}
  alias PhoenixKitAI.Web.Components.MessageContent

  # A PCM WAV: 16 kHz, mono, 16-bit (32 000 bytes a second), `seconds` long.
  defp wav(seconds) do
    data_size = round(32_000 * seconds)

    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, 16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data",
      data_size::little-32, :binary.copy(<<0>>, data_size)::binary>>
  end

  describe "MessageParts.stored/1" do
    test "an input_audio part keeps its format and size, never its data" do
      audio = :binary.copy("x", 3_000)

      [message] =
        MessageParts.stored([
          %{
            role: "user",
            content: [
              %{"type" => "text", "text" => "Write it down"},
              %{
                "type" => "input_audio",
                "input_audio" => %{"data" => Base.encode64(audio), "format" => "wav"}
              }
            ]
          }
        ])

      assert message == %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "Write it down"},
                 %{
                   "type" => "input_audio",
                   "input_audio" => %{"format" => "wav", "bytes" => 3_000, "omitted" => true}
                 }
               ]
             }
    end

    test "atom keys and Mistral's bare base64 string are read the same" do
      [%{"content" => [atom_part, mistral_part]}] =
        MessageParts.stored([
          %{
            role: :user,
            content: [
              %{type: "input_audio", input_audio: %{data: Base.encode64("abcd"), format: "mp3"}},
              %{"type" => "input_audio", "input_audio" => Base.encode64("abcde")}
            ]
          }
        ])

      assert atom_part == %{
               "type" => "input_audio",
               "input_audio" => %{"format" => "mp3", "bytes" => 4, "omitted" => true}
             }

      assert mistral_part == %{
               "type" => "input_audio",
               "input_audio" => %{"bytes" => 5, "omitted" => true}
             }
    end

    test "a data-URL image and a file's data become their size; an http image is kept" do
      png = :binary.copy(<<1>>, 100)
      pdf = :binary.copy(<<2>>, 50)
      http = %{"type" => "image_url", "image_url" => %{"url" => "https://cdn.test/a.png"}}

      [%{"content" => [image, kept, file]}] =
        MessageParts.stored([
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64," <> Base.encode64(png)}
              },
              http,
              %{
                "type" => "file",
                "file" => %{
                  "filename" => "offer.pdf",
                  "file_data" => "data:application/pdf;base64," <> Base.encode64(pdf)
                }
              }
            ]
          }
        ])

      assert image == %{
               "type" => "image_url",
               "image_url" => %{"content_type" => "image/png", "bytes" => 100, "omitted" => true}
             }

      assert kept == http

      assert file == %{
               "type" => "file",
               "file" => %{"filename" => "offer.pdf", "bytes" => 50, "omitted" => true}
             }
    end

    test "string content and tool fields are kept as sent" do
      assert [%{"role" => "user", "content" => "hello"}] =
               MessageParts.stored([%{role: "user", content: "hello"}])
    end

    test "payload_bytes/1 counts decoded bytes, padded or not" do
      for size <- 0..10 do
        bytes = :binary.copy("z", size)
        assert MessageParts.payload_bytes(Base.encode64(bytes)) == size
        assert MessageParts.payload_bytes(Base.encode64(bytes, padding: false)) == size
      end

      assert MessageParts.payload_bytes("data:text/plain,hello") == 5
    end
  end

  describe "Transcription.normalize/2" do
    test "reads the format from the bytes and the length from a WAV header" do
      assert {:ok, %{format: "wav", content_type: "audio/wav", bytes: bytes, seconds: 1.5}} =
               Transcription.normalize(wav(1.5))

      assert bytes == byte_size(wav(1.5))

      for {bytes, format} <- [
            {<<"ID3", 3, 0, 0>>, "mp3"},
            {<<0xFF, 0xFB, 0x90, 0x00>>, "mp3"},
            {<<0xFF, 0xF1, 0x50, 0x80>>, "aac"},
            {<<"fLaC", 0, 0>>, "flac"},
            {<<"OggS", 0, 2>>, "ogg"},
            {<<0x1A, 0x45, 0xDF, 0xA3, 1>>, "webm"},
            {<<0, 0, 0, 32, "ftypM4A ">>, "m4a"}
          ] do
        assert {:ok, %{format: ^format, seconds: nil}} = Transcription.normalize(bytes)
      end
    end

    test "format:, a map's format or content type and a data URL name it too" do
      assert {:ok, %{format: "mp3"}} = Transcription.normalize("unknown bytes", format: "mpeg")
      assert {:ok, %{format: "ogg"}} = Transcription.normalize(%{data: "x", format: :opus})

      assert {:ok, %{format: "webm"}} =
               Transcription.normalize(%{data: "x", content_type: "audio/webm;codecs=opus"})

      assert {:ok, %{format: "flac"}} =
               Transcription.normalize(%{"data" => "x", "format" => "flac"})

      assert {:ok, %{format: "wav", data: "abc"}} =
               Transcription.normalize("data:audio/wav;base64," <> Base.encode64("abc"))
    end

    test "empty, too large, unknown or not audio at all is refused before any call" do
      assert {:error, :empty_input} = Transcription.normalize("")

      assert {:error, {:audio_too_large, 11, 10}} =
               Transcription.normalize(:binary.copy("a", 11), max_audio_bytes: 10)

      assert {:error, :unknown_audio_format} = Transcription.normalize("plain text, not audio")
      assert {:error, :invalid_audio_input} = Transcription.normalize(42)
      assert {:error, :invalid_audio_input} = Transcription.normalize("data:audio/wav,not-base64")
    end

    test "wav_seconds/1 is nil where the header does not say it" do
      assert Transcription.wav_seconds("RIFF") == nil
      assert Transcription.wav_seconds(<<"RIFF", 0::32, "WAVE">>) == nil
      assert Transcription.wav_seconds(wav(2)) == 2.0
    end
  end

  describe "Transcription.transport/2" do
    defp endpoint(provider, model), do: %Endpoint{provider: provider, model: model}

    test "OpenRouter is always the chat path" do
      assert Transcription.transport(endpoint("openrouter", "openai/whisper-1"), []) == :chat
    end

    test "elsewhere a speech-to-text model's name takes the transcriptions path" do
      for model <-
            ~w(whisper-1 gpt-4o-transcribe gpt-4o-mini-transcribe voxtral-mini-transcribe-2507 nova-stt) do
        assert Transcription.transport(endpoint("openai", model), []) == :transcriptions, model
      end

      for model <- ~w(gpt-4o-audio-preview voxtral-small-latest gpt-4o) do
        assert Transcription.transport(endpoint("openai", model), []) == :chat, model
      end
    end

    test "a call's model: and transport: win" do
      ep = endpoint("openai", "gpt-4o-audio-preview")
      assert Transcription.transport(ep, model: "whisper-1") == :transcriptions
      assert Transcription.transport(ep, model: "whisper-1", transport: :chat) == :chat
    end
  end

  describe "the chat path's request" do
    test "the prompt carries the instructions and the language hint" do
      prompt = Transcription.prompt(instructions: "  Sizes as 2500×1250.  ", language: "et")

      assert prompt =~ "word for word"
      assert prompt =~ "empty text"
      assert prompt =~ "The speech is expected to be in et."
      assert prompt =~ "Further instructions:\nSizes as 2500×1250."
      refute Transcription.prompt([]) =~ "Further instructions"
    end

    test "the audio part is %{data, format}, a bare string for Mistral" do
      {:ok, audio} = Transcription.normalize(wav(0.1))

      [%{"content" => [_text, part]}] =
        Transcription.messages(endpoint("openrouter", "m"), audio, [])

      assert part["input_audio"] == %{"data" => Base.encode64(audio.data), "format" => "wav"}

      [%{"content" => [_text, mistral]}] =
        Transcription.messages(endpoint("mistral", "voxtral-small-latest"), audio, [])

      assert mistral["input_audio"] == Base.encode64(audio.data)
    end

    test "from_json/1 trims the words and keeps only a language tag" do
      assert Transcription.from_json(%{"text" => "  Tere  ", "language" => "et"}) ==
               {:ok, %{text: "Tere", language: "et"}}

      assert Transcription.from_json(%{"text" => "", "language" => ""}) ==
               {:ok, %{text: "", language: nil}}

      assert Transcription.from_json(%{"text" => "x", "language" => "Estonian, mostly"}) ==
               {:ok, %{text: "x", language: nil}}

      assert Transcription.from_json(%{"words" => "x"}) == :error
    end
  end

  describe "the guard's :audio_input" do
    defp audio_message(part), do: [%{role: "user", content: [%{type: "text", text: "?"}, part]}]

    test "an input_audio part in a chat call needs a model that takes audio" do
      string_part = %{
        "type" => "input_audio",
        "input_audio" => %{"data" => "AA==", "format" => "wav"}
      }

      atom_part = %{type: "input_audio", input_audio: %{data: "AA==", format: "wav"}}

      assert Guard.implied_needs(:complete, [], audio_message(string_part)) == [:audio_input]
      assert Guard.implied_needs(:complete, [], audio_message(atom_part)) == [:audio_input]
    end

    test "transcribe/3 needs it on the chat path only" do
      assert Guard.implied_needs(:transcribe, transport: :chat) == [:audio_input, :json]
      assert Guard.implied_needs(:transcribe, transport: :transcriptions) == []
    end

    test "it is a hard need and a declarable capability" do
      assert :audio_input in TaskSpec.hard_needs()
      assert :audio_input in Capabilities.declarable()
    end
  end

  describe "the catalogues' audio flag" do
    test "OpenRouter: audio among the input modalities, or in the modality string" do
      heard =
        Capabilities.from_openrouter(%{
          "architecture" => %{"input_modalities" => ["text", "image", "audio"]}
        })

      deaf = Capabilities.from_openrouter(%{"architecture" => %{"input_modalities" => ["text"]}})
      old = Capabilities.from_openrouter(%{"architecture" => %{"modality" => "text+audio->text"}})

      assert heard.audio_input == :yes
      assert deaf.audio_input == :no
      assert old.audio_input == :yes
    end

    test "Anthropic never, DeepSeek as listed, Mistral unknown" do
      assert Capabilities.from_anthropic(%{"id" => "claude"}).audio_input == :no
      assert Capabilities.from_deepseek(%{"input_modalities" => ["text"]}).audio_input == :no
      assert Capabilities.from_mistral(%{"capabilities" => %{}}).audio_input == :unknown
    end
  end

  describe "the Usage tab's message content" do
    test "text parts are text; media parts name what they were, never the bytes" do
      secret = Base.encode64("the recording itself")

      html =
        render_component(&MessageContent.content/1,
          content: [
            %{"type" => "text", "text" => "Write it down"},
            %{"type" => "input_audio", "input_audio" => %{"data" => secret, "format" => "wav"}},
            %{
              "type" => "input_audio",
              "input_audio" => %{"format" => "wav", "bytes" => 5_800_000}
            },
            %{"type" => "image_url", "image_url" => %{"url" => "https://cdn.test/a.png"}},
            %{"type" => "file", "file" => %{"filename" => "offer.pdf", "bytes" => 10}}
          ]
        )

      assert html =~ "Write it down"
      assert html =~ "Audio (wav, "
      assert html =~ "not stored"
      assert html =~ "https://cdn.test/a.png"
      assert html =~ "File (offer.pdf, "
      refute html =~ secret
    end

    test "string content renders as text, and an old payload loses its bytes for display" do
      assert render_component(&MessageContent.content/1, content: "plain") =~ "plain"

      payload = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_audio", "input_audio" => %{"data" => "QUJD"}}]
          }
        ]
      }

      refute Jason.encode!(MessageContent.payload(payload)) =~ "QUJD"
    end
  end
end
