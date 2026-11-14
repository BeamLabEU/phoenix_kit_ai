defmodule PhoenixKitAI.Providers.BedrockConverse do
  @moduledoc """
  Chat on Amazon Bedrock through its native Converse API
  (`POST https://bedrock-runtime.<region>.amazonaws.com/model/<model id>/converse`),
  for the models Bedrock's OpenAI-compatible URL does not serve — Claude
  above all, by its inference profiles (`eu.anthropic.claude-opus-4-6-v1`,
  `global.anthropic.claude-sonnet-5`) or a model or profile ARN.

  `PhoenixKitAI.Completion.chat_completion/3` takes this path for an endpoint
  on core's `amazon_bedrock` integration whose model is not an `openai.*`
  one (`converse?/2`); the `openai.gpt-oss-*` models stay on the
  OpenAI-compatible URL, as before. Callers see no difference: the request
  is translated from the chat-completions shape and the answer back into it,
  so `PhoenixKitAI.Completion.extract_content/1`, `extract_tool_calls/1`,
  `extract_usage/1` and the usage rows read it as any other provider's.

  ## Connection

    * **Key** — the integration's Bedrock API key (`ABSK…`), sent as a Bearer
      token, which Converse accepts as the OpenAI-compatible URL does. Its IAM
      identity needs `bedrock:CallWithBearerToken` and `bedrock:InvokeModel`
      on the model or inference profile (and on the models the profile routes
      to). No SigV4: the integration holds no access key pair.
    * **Region** — the host of the endpoint's base URL; its path (`/openai/v1`)
      is not used, so one base URL serves both APIs.

  ## Request

    * `system` messages → `system`; `user` and `assistant` messages →
      `messages`, consecutive ones of a role merged into one, so the results
      of parallel tool calls go back in one `user` message, as Claude expects;
      `tool` messages → `toolResult` blocks; an assistant's `tool_calls` → `toolUse` blocks (their
      `arguments` decoded from JSON).
    * Content parts: `text`, and `image_url` with a `data:` URL of a PNG,
      JPEG, GIF or WebP image → an `image` block with its bytes. Converse
      takes no image link, so an http(s) `image_url` is `{:error,
      :not_supported}`, as are audio and file parts; a `data:` URL that does
      not decode is `{:error, :invalid_image_input}`.
    * `:max_tokens`, `:temperature`, `:top_p`, `:stop` → `inferenceConfig`.
      For an Anthropic model the rules of the Anthropic path apply: never
      `temperature` and `top_p` together (`temperature` is kept), and no
      sampling at all from Claude Opus 4.7 on (decided from the model id, as
      there); `:top_k` goes in `additionalModelRequestFields` for an
      Anthropic model that takes sampling, and nowhere for the others. An
      application inference profile ARN does not name its model, so it is
      sent sampling as a model of another family is: clear the endpoint's
      temperature for a Claude from Opus 4.7 on behind one.
    * A `system` message takes text only: Converse's `system` has no place
      for an image, so an image part there is `{:error, :not_supported}`
      before any request is sent. Several `system` messages are joined in
      order. A transcript may open with an `assistant` message: Converse
      takes it as it is (checked live with Claude Haiku 4.5 and Sonnet 4.6).
    * `:tools` (OpenAI function tools) → `toolConfig.tools[].toolSpec`, a
      tool with no or empty `parameters` given the empty object schema
      (`{"type": "object", "properties": {}}`; Converse refuses a schema
      without `"type": "object"`). `:tool_choice` `"auto"` / `"required"` /
      a function → `auto` / `any` / `tool`. Converse has no `"none"`: the
      tools are still offered.
    * Forced tool choice (`"required"` or a function) is refused with a 400
      by the Claude models that do not take it: Claude Fable 5.1, Mythos
      5.1, Opus 5.5 and Sonnet 5.5 refuse it always, and an older Claude
      refuses it while thinking. Send `"auto"` and name the tool in the
      prompt for those.
    * Converse refuses `toolUse` / `toolResult` blocks in a request that
      defines no tools (400 "The toolConfig field must be defined…"). When a
      transcript holds a tool round but the call passes no `:tools`, the
      tools are declared from the history itself: each name the assistant
      called, with the empty object schema and no description. The model
      may call one of them again; a caller runs only the tools it offered.
    * Not sent, as Converse has no field for them: `:response_format` (the
      JSON schema still rides in the prompt — `PhoenixKitAI.StructuredOutput`),
      `:seed`, the penalties and `:parallel_tool_calls`.
    * Reasoning: the endpoint's and the call's reasoning options
      (`reasoning_enabled`, `reasoning_effort`, `reasoning_max_tokens`,
      `reasoning_exclude`) are ignored — nothing is sent, and a model thinks
      or not by its own default (the Claude 5 models think by default).

  ## Answer

  `output.message.content` → one chat choice: the text blocks joined as
  `content` (`nil` when there is none), `toolUse` blocks → `tool_calls`
  (`arguments` as a JSON string), reasoning text → `reasoning`.
  `stopReason` → `finish_reason`, Bedrock's own word kept in
  `native_finish_reason`:

    * `end_turn` / `stop_sequence` → `"stop"`; `tool_use` → `"tool_calls"`;
    * `max_tokens` / `model_context_window_exceeded` → `"length"`, and so
      are `malformed_model_output` and `malformed_tool_use`: the answer is
      not whole, so `PhoenixKitAI.Completion.truncated?/1` keeps a caller
      from taking it as one (raising `max_tokens` may not help there);
    * `content_filtered` / `guardrail_intervened` / `refusal` →
      `"content_filter"`, which `PhoenixKitAI.Completion.filtered?/1` reads;
    * any other word passes through as it is.

  `usage.inputTokens` / `outputTokens` / `totalTokens` → `prompt_tokens` /
  `completion_tokens` / `total_tokens` (the sum when Bedrock sends no
  total).

  **Cost and budgets.** Converse reports no cost: a call is priced only by
  the endpoint's manual price (`PhoenixKitAI.CallCost`). Without one, its
  rows carry no cost, and the money limits of `PhoenixKitAI.Budget` count it
  as nothing — set the manual price on a Bedrock endpoint before relying on
  a budget.

  **Thinking is not replayed.** Reasoning blocks of an answer come back as
  `reasoning`, but a chat message has no place for their signature, so they
  are not sent back on the next turn. Claude takes a history without them
  (no 400); a thinking model starts each tool round without its earlier
  reasoning.

  ## Errors

  Bedrock's error body is `{"message": …}` (or `"Message"`). It is read into
  the module's vocabulary, and the request row keeps Bedrock's own status
  and words (`metadata.provider_error`, `provider_error_message`):

    * a 403 about the key itself (its format, an invalid token or
      signature) is `:invalid_api_key` — the row still says 403;
    * a 400 "The provided model identifier is invalid." and a 404 for a
      model past its end of life are `:model_not_found`;
    * a 404 about access to a model that exists — the Anthropic use-case
      form not submitted, a Legacy model not used lately ("Access denied") —
      is `{:api_error, 404}`, its words in the row; so is a 403 such as
      "… is not available for this account";
    * 429 is `:rate_limited`; any other status is `{:api_error, status}`.
  """

  alias PhoenixKitAI.{Completion, Endpoint, OpenRouterClient}

  @provider "amazon_bedrock"
  # The geographic and global prefixes of Bedrock's cross-region inference
  # profiles (`eu.anthropic.…`, `global.anthropic.…`).
  @geo_prefixes ~w(us eu apac jp au ca us-gov global)
  # The keys `field/2` also reads as atoms.
  @atom_keys %{
    "type" => :type,
    "text" => :text,
    "image_url" => :image_url,
    "url" => :url,
    "function" => :function,
    "name" => :name,
    "arguments" => :arguments,
    "parameters" => :parameters,
    "description" => :description,
    "id" => :id
  }
  @image_formats %{
    "image/png" => "png",
    "image/jpeg" => "jpeg",
    "image/jpg" => "jpeg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @doc """
  Whether a chat call to `endpoint` with `model` goes through Converse: the
  endpoint is on the `amazon_bedrock` integration and the model is not one of
  the `openai.*` models of Bedrock's OpenAI-compatible URL.
  """
  @spec converse?(Endpoint.t() | map(), String.t() | nil) :: boolean()
  def converse?(%{provider: provider}, model) when is_binary(provider) and is_binary(model) do
    Endpoint.base_provider(provider) == @provider and
      not String.starts_with?(bare_model(model), "openai.")
  end

  def converse?(_endpoint, _model), do: false

  @doc false
  # The model id without an ARN around it nor a cross-region prefix:
  # `arn:…:inference-profile/eu.anthropic.claude-x-v1:0` and
  # `eu.anthropic.claude-x-v1:0` are both `anthropic.claude-x-v1:0`.
  @spec bare_model(String.t()) :: String.t()
  def bare_model(model) when is_binary(model) do
    id = model |> String.split("/") |> List.last()

    case String.split(id, ".", parts: 2) do
      [prefix, rest] when prefix in @geo_prefixes ->
        if String.contains?(rest, "."), do: rest, else: id

      _ ->
        id
    end
  end

  @doc false
  # The Anthropic model id of a Bedrock Claude id (`claude-opus-4-6`,
  # `claude-haiku-4-5-20251001`), or nil for any other model.
  @spec claude_id(String.t() | nil) :: String.t() | nil
  def claude_id(model) when is_binary(model) do
    case bare_model(model) do
      "anthropic." <> id -> Regex.replace(~r/-v\d+(?::\d+)?$/, id, "")
      _ -> nil
    end
  end

  def claude_id(_model), do: nil

  @doc false
  # `scheme://host[:port]/model/<model id>/converse`, the model id
  # percent-encoded (`:` and `/` of a version or an ARN included).
  @spec url(Endpoint.t(), String.t()) :: String.t()
  def url(endpoint, model) do
    base = URI.parse(Completion.url(endpoint, ""))
    path = "/model/" <> URI.encode(model, &URI.char_unreserved?/1) <> "/converse"

    URI.to_string(%{base | path: path, query: nil, fragment: nil, userinfo: nil})
  end

  @doc false
  # The Bedrock API key as a Bearer token; no header when there is none
  # (Bedrock answers 403, read as `:invalid_api_key`).
  @spec headers(Endpoint.t()) :: [{String.t(), String.t()}]
  def headers(endpoint) do
    base = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]

    case OpenRouterClient.resolve_api_key(endpoint) do
      key when is_binary(key) and key != "" ->
        [{"Authorization", "Bearer " <> String.trim(key)} | base]

      _ ->
        base
    end
  end

  @doc false
  # The Converse request body for chat `messages` and the call's `opts`, or
  # `{:error, reason}` for content Converse cannot take.
  @spec request(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def request(model, messages, opts) do
    with {:ok, system, turns} <- translate_messages(messages) do
      claude = claude_id(model)

      body =
        %{"messages" => turns}
        |> put_present("system", system)
        |> put_present("inferenceConfig", inference_config(opts, claude))
        |> put_present("additionalModelRequestFields", additional_fields(opts, claude))
        |> put_present("toolConfig", tool_config(opts[:tools], opts[:tool_choice], turns))

      {:ok, body}
    end
  end

  @doc false
  # A Converse answer in the chat-completions shape.
  @spec response(map(), String.t()) :: map()
  def response(%{} = answer, model) do
    blocks = get_in(answer, ["output", "message", "content"]) || []
    blocks = if is_list(blocks), do: blocks, else: []

    message =
      %{"role" => "assistant", "content" => joined(blocks, &text_of/1)}
      |> put_present("tool_calls", Enum.flat_map(blocks, &tool_call/1))
      |> put_present("reasoning", joined(blocks, &reasoning_of/1))

    %{
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => finish_reason(answer["stopReason"])
        }
        |> put_present("native_finish_reason", answer["stopReason"])
      ],
      "usage" => usage(answer["usage"])
    }
  end

  @doc false
  # Bedrock's error answer as the chat-completions error body
  # `PhoenixKitAI.Completion` reads, and the reason it names where the status
  # alone would mislead (nil: go by the status). The status itself is never
  # rewritten, so the request row keeps the one Bedrock sent.
  @spec error(integer(), String.t()) :: {String.t(), :invalid_api_key | :model_not_found | nil}
  def error(status, body) do
    message =
      case Jason.decode(body) do
        {:ok, %{"message" => message}} when is_binary(message) -> message
        {:ok, %{"Message" => message}} when is_binary(message) -> message
        _ -> nil
      end

    error = put_present(%{}, "message", message)

    {Jason.encode!(%{"error" => error}), reason(status, message || "")}
  end

  defp reason(403, message) do
    if message =~ ~r/api key|security token|signature|credential/i, do: :invalid_api_key
  end

  # A 404 about access to a model that exists is not an unknown model.
  defp reason(404, message) do
    unless message =~ ~r/use case|access denied|not available|not authorized|agreement/i,
      do: :model_not_found
  end

  defp reason(400, message) do
    if message =~ ~r/model identifier|resolve the foundation model/i, do: :model_not_found
  end

  defp reason(_status, _message), do: nil

  # ── messages ──────────────────────────────────────────────────────

  defp translate_messages(messages) do
    messages
    |> Enum.map(&Completion.normalize_message/1)
    |> Enum.reduce_while({:ok, [], []}, fn message, {:ok, system, turns} ->
      case translate(message) do
        {:system, blocks} -> {:cont, {:ok, system ++ blocks, turns}}
        {:turn, _role, []} -> {:cont, {:ok, system, turns}}
        {:turn, role, blocks} -> {:cont, {:ok, system, append_turn(turns, role, blocks)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, system, turns} -> {:ok, system, Enum.reverse(turns)}
      error -> error
    end
  end

  # `turns` is newest first; a message of the role of the newest is merged
  # into it.
  defp append_turn([%{"role" => role, "content" => content} | rest], role, blocks),
    do: [%{"role" => role, "content" => content ++ blocks} | rest]

  defp append_turn(turns, role, blocks), do: [%{"role" => role, "content" => blocks} | turns]

  # Converse's `system` takes text blocks only.
  defp translate(%{"role" => "system", "content" => content}) do
    with {:ok, blocks} <- content_blocks(content) do
      if Enum.all?(blocks, &Map.has_key?(&1, "text")),
        do: {:system, blocks},
        else: {:error, :not_supported}
    end
  end

  defp translate(%{"role" => "assistant"} = message) do
    with {:ok, blocks} <- content_blocks(message["content"]) do
      {:turn, "assistant", blocks ++ Enum.map(message["tool_calls"] || [], &tool_use/1)}
    end
  end

  defp translate(%{"role" => "tool"} = message) do
    result =
      %{
        "toolUseId" => message["tool_call_id"],
        "content" => [%{"text" => tool_text(message["content"])}]
      }

    {:turn, "user", [%{"toolResult" => result}]}
  end

  defp translate(%{"content" => content}) do
    with {:ok, blocks} <- content_blocks(content), do: {:turn, "user", blocks}
  end

  defp content_blocks(nil), do: {:ok, []}
  defp content_blocks(text) when is_binary(text), do: {:ok, text_block(text)}

  defp content_blocks(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case part_blocks(part) do
        {:ok, blocks} -> {:cont, {:ok, acc ++ blocks}}
        error -> {:halt, error}
      end
    end)
  end

  defp content_blocks(_content), do: {:error, :not_supported}

  # Converse refuses an empty text block.
  defp text_block(text) do
    if String.trim(text) == "", do: [], else: [%{"text" => text}]
  end

  defp part_blocks(part) when is_map(part) do
    case field(part, "type") do
      "text" -> {:ok, text_block(to_string(field(part, "text") || ""))}
      "image_url" -> image_block(field(part, "image_url"))
      _other -> {:error, :not_supported}
    end
  end

  defp part_blocks(_part), do: {:error, :not_supported}

  defp image_block(%{} = image_url), do: image_block(field(image_url, "url"))

  defp image_block("data:" <> _ = url) do
    case Completion.decode_image_url(url) do
      %{data: data, content_type: type} when is_binary(data) ->
        case Map.fetch(@image_formats, type && String.downcase(type)) do
          {:ok, format} ->
            {:ok,
             [%{"image" => %{"format" => format, "source" => %{"bytes" => Base.encode64(data)}}}]}

          :error ->
            {:error, :not_supported}
        end

      _ ->
        {:error, :invalid_image_input}
    end
  end

  defp image_block(_url), do: {:error, :not_supported}

  defp tool_use(call) do
    function = field(call, "function") || %{}

    %{
      "toolUse" => %{
        "toolUseId" => field(call, "id"),
        "name" => field(function, "name"),
        "input" => tool_input(field(function, "arguments"))
      }
    }
  end

  # Converse wants the arguments as a JSON object; a model's call that was
  # not one is sent back as an empty object.
  defp tool_input(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = input} -> input
      _ -> %{}
    end
  end

  defp tool_input(%{} = arguments), do: arguments
  defp tool_input(_arguments), do: %{}

  defp tool_text(text) when is_binary(text), do: text
  defp tool_text(nil), do: ""
  defp tool_text(other), do: Jason.encode!(other)

  # ── options ───────────────────────────────────────────────────────

  defp inference_config(opts, claude) do
    sampling = sampling(opts, claude)

    %{}
    |> put_present("maxTokens", opts[:max_tokens])
    |> put_present("temperature", sampling[:temperature])
    |> put_present("topP", sampling[:top_p])
    |> put_present("stopSequences", stop_sequences(opts[:stop]))
  end

  defp additional_fields(opts, claude) do
    if claude, do: put_present(%{}, "top_k", sampling(opts, claude)[:top_k]), else: %{}
  end

  # The sampling a model takes: an Anthropic model the rules of the Anthropic
  # path, any other model `temperature` and `top_p` as given (no `top_k`:
  # Converse has no common field for it).
  defp sampling(opts, nil), do: [temperature: opts[:temperature], top_p: opts[:top_p]]

  defp sampling(opts, claude) do
    cond do
      not Completion.anthropic_sampling?(claude) -> []
      opts[:temperature] != nil -> [temperature: opts[:temperature], top_k: opts[:top_k]]
      true -> [top_p: opts[:top_p], top_k: opts[:top_k]]
    end
  end

  defp stop_sequences(stop) when is_binary(stop), do: [stop]
  defp stop_sequences(stop) when is_list(stop), do: stop
  defp stop_sequences(_stop), do: nil

  defp tool_config(tools, choice, _turns) when is_list(tools) and tools != [] do
    %{"tools" => Enum.map(tools, &tool_spec/1)}
    |> put_present("toolChoice", tool_choice(choice))
  end

  # No tools offered, but the history holds a tool round: Converse refuses
  # it without a `toolConfig`, so the tools the assistant called are
  # declared, by name only.
  defp tool_config(_tools, _choice, turns) do
    turns
    |> Enum.flat_map(& &1["content"])
    |> Enum.flat_map(fn
      %{"toolUse" => %{"name" => name}} when is_binary(name) and name != "" -> [name]
      _block -> []
    end)
    |> Enum.uniq()
    |> case do
      [] -> nil
      names -> %{"tools" => Enum.map(names, &%{"toolSpec" => tool_spec_json(&1, nil, nil)})}
    end
  end

  defp tool_spec(tool) do
    function = field(tool, "function") || tool

    spec =
      tool_spec_json(
        field(function, "name"),
        field(function, "parameters"),
        field(function, "description")
      )

    %{"toolSpec" => spec}
  end

  defp tool_spec_json(name, parameters, description) do
    %{"name" => name, "inputSchema" => %{"json" => input_schema(parameters)}}
    |> put_present("description", blank_to_nil(description))
  end

  # Converse refuses a schema without `"type": "object"`.
  defp input_schema(parameters) when is_map(parameters) and map_size(parameters) > 0,
    do: parameters

  defp input_schema(_parameters), do: %{"type" => "object", "properties" => %{}}

  defp tool_choice("auto"), do: %{"auto" => %{}}
  defp tool_choice("required"), do: %{"any" => %{}}

  defp tool_choice(%{} = choice) do
    case field(field(choice, "function") || %{}, "name") do
      name when is_binary(name) -> %{"tool" => %{"name" => name}}
      _ -> nil
    end
  end

  defp tool_choice(_choice), do: nil

  # ── answer ────────────────────────────────────────────────────────

  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(_block), do: nil

  defp reasoning_of(%{"reasoningContent" => %{"reasoningText" => %{"text" => text}}})
       when is_binary(text),
       do: text

  defp reasoning_of(_block), do: nil

  defp joined(blocks, reader) do
    case blocks |> Enum.map(reader) |> Enum.filter(&is_binary/1) do
      [] -> nil
      texts -> Enum.join(texts)
    end
  end

  defp tool_call(%{"toolUse" => %{} = use}) do
    [
      %{
        "id" => use["toolUseId"],
        "type" => "function",
        "function" => %{"name" => use["name"], "arguments" => Jason.encode!(use["input"] || %{})}
      }
    ]
  end

  defp tool_call(_block), do: []

  defp finish_reason(reason) when reason in ["end_turn", "stop_sequence"], do: "stop"

  # An answer the model could not finish whole is read as cut short.
  defp finish_reason(reason)
       when reason in ~w(max_tokens model_context_window_exceeded malformed_model_output
                         malformed_tool_use),
       do: "length"

  defp finish_reason("tool_use"), do: "tool_calls"

  defp finish_reason(reason) when reason in ~w(content_filtered guardrail_intervened refusal),
    do: "content_filter"

  defp finish_reason(reason), do: reason

  defp usage(%{} = usage) do
    input = integer(usage["inputTokens"])
    output = integer(usage["outputTokens"])

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => integer(usage["totalTokens"]) || (input || 0) + (output || 0)
    }
  end

  defp usage(_usage), do: %{}

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  # ── helpers ───────────────────────────────────────────────────────

  # A part or tool given with atom keys is read as one with string keys.
  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@atom_keys, key))
    end
  end

  defp field(_map, _key), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
