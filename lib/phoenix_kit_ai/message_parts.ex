defmodule PhoenixKitAI.MessageParts do
  @moduledoc """
  Chat messages as a usage row keeps them: everything that was sent except
  the bytes of media parts, which become a placeholder with their size.

  A message's `content` is a string or a list of parts. The parts that carry
  bytes are replaced; every other part, and string content, is kept as sent:

  | sent | stored |
  |---|---|
  | `input_audio` with `data` (OpenAI, OpenRouter) or a base64 string (Mistral) | `%{"type" => "input_audio", "input_audio" => %{"format" => "wav", "bytes" => n, "omitted" => true}}` |
  | `image_url` with a `data:` URL | `%{"type" => "image_url", "image_url" => %{"content_type" => "image/png", "bytes" => n, "omitted" => true}}` |
  | `file` with `file_data` | the `file` map without `file_data`, plus `"bytes"` and `"omitted"` |

  An `image_url` with an http(s) URL is kept as sent. Keys of the stored
  parts are strings; a part given with atom keys is read the same.

  A recording is megabytes (three minutes of 16 kHz WAV is about 5.8 MB, 7.7
  MB as base64), and the row stored the messages twice (`messages` and
  `request_payload.messages`), forever unless a retention period is set —
  and an error raised while rendering one carried the start of the bytes
  into the log.
  """

  @doc "The messages as a usage row stores them (see the moduledoc)."
  @spec stored([map()]) :: [map()]
  def stored(messages) when is_list(messages),
    do:
      Enum.map(messages, &(&1 |> PhoenixKitAI.Completion.normalize_message() |> stored_message()))

  defp stored_message(%{"content" => parts} = message) when is_list(parts),
    do: %{message | "content" => Enum.map(parts, &stored_part/1)}

  defp stored_message(message), do: message

  @doc "One content part as a usage row stores it."
  @spec stored_part(term()) :: term()
  def stored_part(part) when is_map(part) do
    case get(part, "type") do
      "input_audio" -> audio_part(get(part, "input_audio"), part)
      "image_url" -> image_part(get(part, "image_url"), part)
      "file" -> file_part(get(part, "file"), part)
      _other -> part
    end
  end

  def stored_part(part), do: part

  defp audio_part(%{} = audio, _part) do
    placeholder =
      %{"bytes" => payload_bytes(get(audio, "data")), "omitted" => true}
      |> put_present("format", get(audio, "format"))

    %{"type" => "input_audio", "input_audio" => placeholder}
  end

  defp audio_part(data, _part) when is_binary(data),
    do: %{
      "type" => "input_audio",
      "input_audio" => %{"bytes" => payload_bytes(data), "omitted" => true}
    }

  defp audio_part(_other, part), do: part

  defp image_part(%{} = image, part), do: image_url(get(image, "url"), part)
  defp image_part(url, part) when is_binary(url), do: image_url(url, part)
  defp image_part(_other, part), do: part

  defp image_url("data:" <> _ = url, _part) do
    placeholder =
      %{"bytes" => payload_bytes(url), "omitted" => true}
      |> put_present("content_type", data_url_type(url))

    %{"type" => "image_url", "image_url" => placeholder}
  end

  defp image_url(_url, part), do: part

  defp file_part(%{} = file, _part) do
    case get(file, "file_data") do
      data when is_binary(data) ->
        kept =
          file
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.delete("file_data")

        %{
          "type" => "file",
          "file" => Map.merge(kept, %{"bytes" => payload_bytes(data), "omitted" => true})
        }

      _ ->
        %{"type" => "file", "file" => file}
    end
  end

  defp file_part(_other, part), do: part

  @doc """
  The size in bytes of what a media payload carries: a `data:` URL's or a
  bare base64 string's decoded bytes (a non-base64 data URL: its text).
  """
  @spec payload_bytes(term()) :: non_neg_integer() | nil
  def payload_bytes("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [meta, payload] ->
        if String.ends_with?(meta, ";base64"), do: base64_bytes(payload), else: byte_size(payload)

      _ ->
        nil
    end
  end

  def payload_bytes(data) when is_binary(data), do: base64_bytes(data)
  def payload_bytes(_data), do: nil

  # The decoded size of base64 text, without decoding it: four characters
  # are three bytes, less one per `=` of padding.
  defp base64_bytes(text) do
    length = byte_size(text)
    padding = text |> binary_part(max(length - 2, 0), min(length, 2)) |> count_padding()

    # Unpadded base64 ends in two or three characters: one or two bytes.
    tail =
      case rem(length, 4) do
        2 -> 1
        3 -> 2
        _ -> 0
      end

    max(div(length, 4) * 3 + tail - padding, 0)
  end

  defp count_padding("=="), do: 2
  defp count_padding(<<_, ?=>>), do: 1
  defp count_padding(_tail), do: 0

  defp data_url_type("data:" <> rest) do
    case String.split(rest, [";", ","], parts: 2) do
      [type, _] when type != "" -> type
      _ -> nil
    end
  end

  # The keys read, with their atom form: a part may come with either.
  @keys %{
    "type" => :type,
    "input_audio" => :input_audio,
    "image_url" => :image_url,
    "file" => :file,
    "file_data" => :file_data,
    "data" => :data,
    "format" => :format,
    "url" => :url
  }

  defp get(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Map.fetch!(@keys, key)))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
