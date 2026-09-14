defmodule PhoenixKitAI.StructuredOutput do
  @moduledoc """
  Machine-readable answers from chat models, shared by `PhoenixKitAI.ask/3`,
  `PhoenixKitAI.complete/3` and `PhoenixKitAI.describe_image/3`.

  Two options turn it on:

    * `schema:` — a JSON Schema map; the answer is requested as that object
      (`response_format: json_schema`, strict) and parsed.
    * `json: true` — any JSON object (`response_format: json_object`).

  The schema also rides in the prompt, so a model that rejects
  `response_format` (the request is retried once without it on 400/422 —
  any 400, so an unrelated bad request costs one extra call) still knows
  the shape. The parsed object comes back under `"json"` on a chat
  response and `:json` on a vision result; an answer that does not parse
  is `{:error, {:no_json_in_response, text}}` and is never cached, though
  the provider call is logged with its usage. Nothing validates the
  object against the schema locally: `strict` schemas are enforced by the
  provider on the first attempt and advisory on the retry, so check the
  keys you depend on.
  """

  @type format :: %{String.t() => term()} | nil

  @doc "Whether the caller asked for a JSON answer."
  @spec requested?(keyword()) :: boolean()
  def requested?(opts), do: is_map(opts[:schema]) or opts[:json] == true

  @doc """
  The sentence to append to the user's prompt and the `response_format`
  to send, or `{nil, nil}` when no JSON was asked for.
  """
  @spec request(keyword()) :: {String.t() | nil, format()}
  def request(opts) do
    cond do
      is_map(opts[:schema]) ->
        {"Answer only with a JSON object matching this JSON Schema:\n" <>
           Jason.encode!(opts[:schema]),
         %{
           "type" => "json_schema",
           "json_schema" => %{
             "name" => opts[:schema_name] || "answer",
             "strict" => true,
             "schema" => opts[:schema]
           }
         }}

      opts[:json] == true ->
        {"Answer only with a JSON object.", %{"type" => "json_object"}}

      true ->
        {nil, nil}
    end
  end

  @doc """
  Appends `suffix` to the last user message (string content or content
  parts). Messages with atom or string keys are both handled.
  """
  @spec attach(list(), String.t() | nil) :: list()
  def attach(messages, nil), do: messages

  def attach(messages, suffix) when is_list(messages) do
    index = Enum.find_index(Enum.reverse(messages), &user?/1)

    case index do
      nil -> messages ++ [%{role: "user", content: suffix}]
      i -> List.update_at(messages, length(messages) - 1 - i, &append(&1, suffix))
    end
  end

  defp user?(message), do: to_string(message[:role] || message["role"]) == "user"

  defp append(message, suffix) do
    key = if Map.has_key?(message, :content), do: :content, else: "content"

    content =
      case Map.get(message, key) do
        text when is_binary(text) -> text <> "\n\n" <> suffix
        parts when is_list(parts) -> parts ++ [%{"type" => "text", "text" => suffix}]
        nil -> suffix
      end

    Map.put(message, key, content)
  end

  @doc """
  Parses the model's text as a JSON object (or array): the whole text
  first, then a fenced block anywhere in it, then the outermost `{…}` —
  models wrap answers in prose and fences however they were told. With
  `requested?` false returns `{:ok, nil}`.
  """
  @spec parse(String.t() | nil, boolean()) ::
          {:ok, map() | list() | nil} | {:error, {:no_json_in_response, String.t() | nil}}
  def parse(_text, false), do: {:ok, nil}

  def parse(text, true) when is_binary(text) do
    candidates = [String.trim(text), fenced(text), braced(text)]

    Enum.find_value(candidates, {:error, {:no_json_in_response, text}}, fn
      nil -> nil
      candidate -> decode(candidate)
    end)
  end

  def parse(text, true), do: {:error, {:no_json_in_response, text}}

  defp decode(candidate) do
    case Jason.decode(candidate) do
      {:ok, json} when is_map(json) or is_list(json) -> {:ok, json}
      _ -> nil
    end
  end

  defp fenced(text) do
    case Regex.run(~r/```(?:json)?\s*(.*?)\s*```/is, text) do
      [_, inner] -> inner
      _ -> nil
    end
  end

  defp braced(text) do
    with first when first != nil <- first_index(text, ["{", "["]),
         last when last != nil <- last_index(text, ["}", "]"]),
         true <- last > first do
      binary_part(text, first, last - first + 1)
    else
      _ -> nil
    end
  end

  defp first_index(text, chars) do
    case :binary.match(text, chars) do
      {index, _} -> index
      :nomatch -> nil
    end
  end

  defp last_index(text, chars) do
    case :binary.matches(text, chars) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @doc """
  Runs `fun.(response_format)`; when a JSON answer was requested and the
  provider answers 400/422 (a model that takes no `response_format`), runs
  it once more with `nil`.
  """
  @spec with_fallback(format(), (format() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_fallback(nil, fun), do: fun.(nil)

  def with_fallback(format, fun) do
    case fun.(format) do
      {:error, {:api_error, status}} when status in [400, 422] -> fun.(nil)
      other -> other
    end
  end
end
