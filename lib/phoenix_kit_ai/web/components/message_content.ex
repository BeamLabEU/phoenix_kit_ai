defmodule PhoenixKitAI.Web.Components.MessageContent do
  @moduledoc """
  A stored chat message's `content` on the Usage tab's request details: a
  string as text; a list of parts with each text part as text and each
  media part as a line naming what it was (audio, image, file) and its size.
  The bytes are never shown — rows written before
  `PhoenixKitAI.MessageParts` may still hold them, and they are not
  rendered from those either.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  alias PhoenixKit.Utils.Format
  alias PhoenixKitAI.MessageParts

  @doc """
  A stored `request_payload` for display: its `messages` with media bytes
  replaced as `PhoenixKitAI.MessageParts` stores them, for rows written
  before it did.
  """
  @spec payload(term()) :: term()
  def payload(%{"messages" => messages} = payload) when is_list(messages),
    do: %{payload | "messages" => Enum.map(messages, &stored_message/1)}

  def payload(payload), do: payload

  defp stored_message(%{"content" => parts} = message) when is_list(parts),
    do: %{message | "content" => Enum.map(parts, &MessageParts.stored_part/1)}

  defp stored_message(message), do: message

  attr(:content, :any, required: true)

  def content(%{content: text} = assigns) when is_binary(text) do
    ~H"""
    <div class="text-sm whitespace-pre-wrap">{@content}</div>
    """
  end

  def content(%{content: parts} = assigns) when is_list(parts) do
    ~H"""
    <div class="flex flex-col gap-1">
      <.part :for={part <- @content} part={part} />
    </div>
    """
  end

  def content(%{content: nil} = assigns), do: ~H""

  def content(assigns) do
    ~H"""
    <div class="text-sm whitespace-pre-wrap break-all">{other(@content)}</div>
    """
  end

  attr(:part, :any, required: true)

  defp part(%{part: %{"type" => "text", "text" => text}} = assigns) when is_binary(text) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="text-sm whitespace-pre-wrap">{@text}</div>
    """
  end

  defp part(%{part: %{"type" => "image_url", "image_url" => image}} = assigns) do
    case image_link(image) do
      nil -> media(assigns)
      url -> image_line(assign(assigns, :url, url))
    end
  end

  defp part(%{part: %{"type" => type}} = assigns) when type in ["input_audio", "file"],
    do: media(assigns)

  defp part(assigns) do
    ~H"""
    <div class="text-xs text-base-content/70 whitespace-pre-wrap break-all">{other(@part)}</div>
    """
  end

  defp image_link(%{"url" => "http" <> _ = url}), do: url
  defp image_link("http" <> _ = url), do: url
  defp image_link(_image), do: nil

  defp image_line(assigns) do
    ~H"""
    <div class="text-xs text-base-content/70 break-all" data-part="image_url">
      {gettext("Image")}: {@url}
    </div>
    """
  end

  defp media(%{part: %{"type" => type} = part} = assigns) do
    assigns = assign(assigns, :label, media_label(type, part))

    ~H"""
    <div data-part={@part["type"]}>
      <span class="badge badge-ghost badge-sm h-auto">{@label}</span>
    </div>
    """
  end

  # What a media part was: its kind, its format or name, its size, and that
  # the bytes were not kept.
  defp media_label(type, part) do
    stored = MessageParts.stored_part(part)
    details = Map.get(stored, type)
    details = if is_map(details), do: details, else: %{}

    kind =
      case type do
        "input_audio" -> gettext("Audio")
        "image_url" -> gettext("Image")
        "file" -> gettext("File")
      end

    facts =
      [
        details["format"] || details["content_type"] || details["filename"],
        size(details["bytes"])
      ]
      |> Enum.reject(&is_nil/1)

    case facts do
      [] ->
        gettext("%{kind}, not stored", kind: kind)

      facts ->
        gettext("%{kind} (%{facts}), not stored", kind: kind, facts: Enum.join(facts, ", "))
    end
  end

  defp size(bytes) when is_integer(bytes), do: Format.bytes(bytes)
  defp size(_bytes), do: nil

  # A content shape this page does not know: as JSON, cut short. Bytes of a
  # known media part never reach here (they were matched above).
  defp other(value) do
    text =
      case Jason.encode(value) do
        {:ok, json} -> json
        {:error, _} -> inspect(value, limit: 20, printable_limit: 200)
      end

    if String.length(text) > 2_000, do: String.slice(text, 0, 2_000) <> "…", else: text
  end
end
