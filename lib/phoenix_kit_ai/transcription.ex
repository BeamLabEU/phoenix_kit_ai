defmodule PhoenixKitAI.Transcription do
  @moduledoc """
  Speech to text for `PhoenixKitAI.transcribe/3`: the audio checked and
  named, the path chosen, the request built and the answer read.

  ## Two paths

    * `:chat` — a chat request whose user message carries the audio as an
      `input_audio` part next to the instructions, answered as a JSON object
      `{text, language}` (`schema/0`). OpenRouter serves audio this way only
      (Gemini, GPT-4o audio and the other models that list `audio` among
      their input modalities), and so do OpenAI's and Mistral's chat models
      that hear. The guard checks the model for `:audio_input`.
    * `:transcriptions` — `POST <base_url>/audio/transcriptions`, OpenAI's
      speech-to-text shape (multipart: `file`, `model`, `prompt`,
      `language`), also served by Groq, Mistral and other OpenAI-compatible
      APIs, for speech-to-text models (`whisper-1`, `gpt-4o-transcribe`,
      `voxtral-mini-transcribe`). No guard need: a speech-to-text model is
      not in any chat catalogue.

  `transport/2` picks one: the call's `transport:`, else the endpoint's
  adapter (`PhoenixKitAI.Provider`'s optional `transcription_transport/2`;
  OpenRouter's says `:chat`), else the model's name — one that reads as a
  speech-to-text model (`whisper`, `transcribe`, `stt`, `asr`) takes
  `:transcriptions`, any other `:chat`.

  ## Audio

  Bytes (WAV, MP3, FLAC, OGG, WebM, M4A — the format is read from the
  bytes when not given), `%{data: bytes, format: "wav"}`,
  `%{data: bytes, content_type: "audio/wav"}`, or a `data:audio/…;base64,`
  URL. Empty audio is `{:error, :empty_input}`; more than `max_bytes/1`
  (`config :phoenix_kit_ai, max_audio_bytes:`, 25 MB — OpenAI's limit) is
  `{:error, {:audio_too_large, bytes, max}}`; a format that cannot be told
  is `{:error, :unknown_audio_format}`. Which formats a model takes is the
  provider's business: OpenRouter documents `wav` and `mp3` for every audio
  model, others more.
  """

  alias PhoenixKitAI.{Endpoint, Provider}

  @max_bytes 25_000_000

  @type audio :: %{
          data: binary(),
          format: String.t(),
          content_type: String.t(),
          bytes: non_neg_integer(),
          seconds: float() | nil
        }

  @formats %{
    "wav" => "audio/wav",
    "mp3" => "audio/mpeg",
    "flac" => "audio/flac",
    "ogg" => "audio/ogg",
    "webm" => "audio/webm",
    "m4a" => "audio/mp4",
    "aac" => "audio/aac",
    "aiff" => "audio/aiff"
  }

  @content_types %{
    "audio/wav" => "wav",
    "audio/wave" => "wav",
    "audio/x-wav" => "wav",
    "audio/vnd.wave" => "wav",
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/flac" => "flac",
    "audio/x-flac" => "flac",
    "audio/ogg" => "ogg",
    "audio/opus" => "ogg",
    "audio/webm" => "webm",
    "audio/mp4" => "m4a",
    "audio/x-m4a" => "m4a",
    "audio/m4a" => "m4a",
    "audio/aac" => "aac",
    "audio/aiff" => "aiff",
    "audio/x-aiff" => "aiff"
  }

  @doc "The largest audio accepted, in bytes (`:max_audio_bytes`, a call's `max_audio_bytes:` wins)."
  @spec max_bytes(keyword()) :: pos_integer()
  def max_bytes(opts \\ []) do
    case opts[:max_audio_bytes] || Application.get_env(:phoenix_kit_ai, :max_audio_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_bytes
    end
  end

  @doc """
  The audio as the verb sends it: bytes, format, content type, size, and
  the length in seconds where the bytes say it (a PCM WAV header).
  `format:` in `opts` wins over what the input or the bytes say.
  """
  @spec normalize(term(), keyword()) :: {:ok, audio()} | {:error, term()}
  def normalize(input, opts \\ [])

  def normalize("data:" <> _ = url, opts) do
    case decode_data_url(url) do
      {:ok, data, type} -> normalize(%{data: data, content_type: type}, opts)
      :error -> {:error, :invalid_audio_input}
    end
  end

  def normalize(data, opts) when is_binary(data), do: normalize(%{data: data}, opts)

  def normalize(%{data: data} = input, opts) when is_binary(data) do
    max = max_bytes(opts)

    cond do
      data == "" ->
        {:error, :empty_input}

      byte_size(data) > max ->
        {:error, {:audio_too_large, byte_size(data), max}}

      true ->
        input |> format_of(opts) |> audio(data)
    end
  end

  def normalize(%{"data" => _} = input, opts),
    do: normalize(Map.new(input, fn {key, value} -> {atom_key(key), value} end), opts)

  def normalize(_input, _opts), do: {:error, :invalid_audio_input}

  defp format_of(input, opts) do
    known_format(opts[:format]) || known_format(input[:format]) ||
      from_content_type(input[:content_type]) || sniff(input.data)
  end

  defp audio(nil, _data), do: {:error, :unknown_audio_format}

  defp audio(format, data),
    do:
      {:ok,
       %{
         data: data,
         format: format,
         content_type: Map.fetch!(@formats, format),
         bytes: byte_size(data),
         seconds: if(format == "wav", do: wav_seconds(data))
       }}

  defp atom_key("data"), do: :data
  defp atom_key("format"), do: :format
  defp atom_key("content_type"), do: :content_type
  defp atom_key(other), do: other

  defp decode_data_url("data:" <> rest) do
    with [meta, payload] <- String.split(rest, ",", parts: 2),
         true <- String.ends_with?(meta, ";base64"),
         {:ok, data} <- Base.decode64(payload, ignore: :whitespace) do
      {:ok, data, meta |> String.split(";") |> hd()}
    else
      _ -> :error
    end
  end

  defp known_format(format) when is_atom(format) and not is_nil(format),
    do: known_format(Atom.to_string(format))

  defp known_format(format) when is_binary(format) do
    format = format |> String.trim() |> String.downcase()

    cond do
      Map.has_key?(@formats, format) -> format
      format == "wave" -> "wav"
      format in ["mpeg", "mpga"] -> "mp3"
      format in ["mp4", "m4a"] -> "m4a"
      format == "opus" -> "ogg"
      true -> nil
    end
  end

  defp known_format(_format), do: nil

  defp from_content_type(type) when is_binary(type) do
    type
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> then(&@content_types[&1])
  end

  defp from_content_type(_type), do: nil

  # The container from the first bytes.
  defp sniff(<<"RIFF", _size::binary-size(4), "WAVE", _::binary>>), do: "wav"
  defp sniff(<<"FORM", _size::binary-size(4), "AIF", _::binary>>), do: "aiff"
  defp sniff(<<"ID3", _::binary>>), do: "mp3"
  defp sniff(<<"fLaC", _::binary>>), do: "flac"
  defp sniff(<<"OggS", _::binary>>), do: "ogg"
  defp sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "webm"
  defp sniff(<<_size::binary-size(4), "ftyp", _::binary>>), do: "m4a"
  # An ADTS AAC frame header (sync word, layer 0) before an MPEG audio one.
  defp sniff(<<0xFF, second, _::binary>>) when Bitwise.band(second, 0xF6) == 0xF0, do: "aac"
  defp sniff(<<0xFF, second, _::binary>>) when Bitwise.band(second, 0xE0) == 0xE0, do: "mp3"
  defp sniff(_data), do: nil

  @doc """
  A WAV's length in seconds from its header: the `fmt ` chunk's byte rate
  and the `data` chunk's size. `nil` when the bytes do not say (not RIFF,
  no byte rate, a streamed header with an unknown size).
  """
  @spec wav_seconds(binary()) :: float() | nil
  def wav_seconds(<<"RIFF", _size::binary-size(4), "WAVE", chunks::binary>>),
    do: wav_chunks(chunks, nil)

  def wav_seconds(_data), do: nil

  defp wav_chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _rate) do
    rate =
      case body do
        <<_format::little-16, _channels::little-16, _sample_rate::little-32, byte_rate::little-32,
          _::binary>> ->
          byte_rate

        _ ->
          nil
      end

    wav_chunks(skip_pad(rest, size), rate)
  end

  defp wav_chunks(<<"data", size::little-32, _::binary>>, rate)
       when is_integer(rate) and rate > 0 and size not in [0, 0xFFFFFFFF],
       do: Float.round(size / rate, 2)

  defp wav_chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, rate)
       when byte_size(rest) >= size,
       do: wav_chunks(rest |> binary_part(size, byte_size(rest) - size) |> skip_pad(size), rate)

  defp wav_chunks(_rest, _rate), do: nil

  # Chunks are padded to an even size.
  defp skip_pad(<<_pad, rest::binary>>, size) when rem(size, 2) == 1, do: rest
  defp skip_pad(rest, _size), do: rest

  @doc """
  The path a call takes (see the moduledoc): `transport:` in `opts`, else
  the adapter's `transcription_transport/2`, else the model's name.
  """
  @spec transport(Endpoint.t(), keyword()) :: :chat | :transcriptions
  def transport(endpoint, opts) do
    model = opts[:model] || endpoint.model

    case opts[:transport] do
      transport when transport in [:chat, :transcriptions] ->
        transport

      _ ->
        adapter = Provider.for_endpoint(endpoint)

        if Code.ensure_loaded?(adapter) and
             function_exported?(adapter, :transcription_transport, 2),
           do: adapter.transcription_transport(endpoint, model),
           else: by_model(model)
    end
  end

  @doc "`:transcriptions` for a model whose name reads as speech to text, else `:chat`."
  @spec by_model(String.t() | nil) :: :chat | :transcriptions
  def by_model(model) when is_binary(model) do
    id = model |> String.split("/") |> List.last() |> String.downcase()

    if id =~ ~r/whisper|transcri|(^|[-_.])(stt|asr)([-_.]|$)/,
      do: :transcriptions,
      else: :chat
  end

  def by_model(_model), do: :chat

  @doc "What the chat path asks the model, its instructions and language hint included."
  @spec prompt(keyword()) :: String.t()
  def prompt(opts) do
    [
      "Write down the speech in this audio recording word for word, in the language it " <>
        "is spoken in. Do not translate, summarise, answer or comment on it. If the " <>
        "recording has no speech, return an empty text.",
      language_hint(opts[:language]),
      instructions(opts[:instructions])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp language_hint(language) when is_binary(language) and language != "",
    do: "The speech is expected to be in #{String.trim(language)}."

  defp language_hint(_language), do: nil

  defp instructions(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> "Further instructions:\n" <> text
    end
  end

  defp instructions(_text), do: nil

  @doc "The answer the chat path asks for: the words and the spoken language."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{
          "type" => "string",
          "description" => "What was said, word for word; an empty string when nothing was said."
        },
        "language" => %{
          "type" => "string",
          "description" =>
            "The spoken language as a BCP 47 tag such as en, de, ru or et; an empty string when nothing was said."
        }
      },
      "required" => ["text", "language"],
      "additionalProperties" => false
    }
  end

  @doc """
  The chat path's messages: one user message with the prompt and the audio.
  Mistral's chat takes the audio as a bare base64 string; everyone else as
  `%{data, format}`.
  """
  @spec messages(Endpoint.t(), audio(), keyword()) :: [map()]
  def messages(endpoint, audio, opts) do
    [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => prompt(opts)},
          audio_part(endpoint, audio)
        ]
      }
    ]
  end

  defp audio_part(endpoint, audio) do
    data = Base.encode64(audio.data)

    value =
      if Endpoint.base_provider(endpoint.provider || "") == "mistral",
        do: data,
        else: %{"data" => data, "format" => audio.format}

    %{"type" => "input_audio", "input_audio" => value}
  end

  @doc """
  The words and language out of the chat path's JSON answer: `{:ok,
  %{text, language}}` (text trimmed, `""` for no speech; language a tag or
  nil), or `:error` when `text` is missing or not a string.
  """
  @spec from_json(term()) :: {:ok, %{text: String.t(), language: String.t() | nil}} | :error
  def from_json(%{"text" => text} = json) when is_binary(text),
    do: {:ok, %{text: String.trim(text), language: language_tag(json["language"])}}

  def from_json(_json), do: :error

  @doc "A language tag (`en`, `pt-BR`), or nil for anything else."
  @spec language_tag(term()) :: String.t() | nil
  def language_tag(value) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}\z/, value), do: value
  end

  def language_tag(_value), do: nil
end
