defmodule PhoenixKitAI.Images do
  @moduledoc """
  Generic image processing over any provider: named operations composed
  into one edit, vision (describe an image, optionally as JSON), and a
  before/after check.

  Everything takes an endpoint and returns bytes. The module stores
  nothing — the caller keeps the result wherever it keeps files (core's
  Storage, usually). The logged request row is the only trace.

  ## Editing by operation

      PhoenixKitAI.Images.process(endpoint, [photo_jpeg], [
        :remove_reflections,
        {:clean_background, color: "light grey"},
        {:upscale, resolution: "2K"}
      ])

  Operations (`PhoenixKitAI.Images.Operations`) become one numbered
  instruction list, followed by a preservation clause
  (`preserve: :subject` by default — the subject, its text and logos stay
  as they are; `:scene` for room photos; `false` for none; or your own
  sentence). Options the operations imply (`:remove_background` wants
  `background: "transparent"` + PNG) merge under the caller's options and
  are then fitted to the model: an option the model does not list is
  dropped with a warning, or refused with `strict: true`. When an
  operation loses its implied options it falls back to its plain-prompt
  wording (a white background instead of a transparent one).

  ## Options

  Canonical request options, mapped per provider by the adapter:
  `:aspect_ratio`, `:resolution`, `:size`, `:quality`, `:background`,
  `:output_format`, `:output_compression`, `:n`, `:seed`,
  `:response_format`. Control options: `:model` (override the endpoint's
  model — e.g. to compare two OpenRouter models on one endpoint),
  `:transport`, `:provider_options` (passed through untouched),
  `:provider_routing` (OpenRouter), `:strict`, `:preserve`, `:finish`,
  `:prompt_overrides`.

  Endpoint defaults apply underneath: `provider_settings["aspect_ratio"]`
  / `["resolution"]`, and the `image_size` / `image_quality` columns.

  ## Vision

      {:ok, %{json: %{"brand" => _}}} =
        PhoenixKitAI.Images.describe(endpoint, [label_jpeg],
          prompt: "Read the label.",
          schema: %{"type" => "object", "properties" => %{"brand" => %{"type" => "string"}}})

  `describe/3` runs a chat completion with the images attached; with
  `schema:` (a JSON Schema map) or `json: true` the answer is parsed and
  returned under `:json`. `compare/4` is a fixed-schema `describe/3` over
  an original and its edit, answering whether the subject survived.
  """

  alias PhoenixKitAI.{Completion, Endpoint, Provider}
  alias PhoenixKitAI.Images.{ImageModel, ImageModels, Operations}
  alias PhoenixKitAI.Providers.OpenAICompatible

  @request_options ~w(aspect_ratio resolution size quality background output_format output_compression n seed response_format style)a
  @control_options ~w(model transport provider_options provider_routing image_config strict preserve finish prompt_overrides)a

  @type input ::
          binary() | String.t() | %{data: binary(), content_type: String.t()} | %{url: String.t()}

  @type result :: %{
          images: [Provider.image()],
          text: String.t() | nil,
          usage: map(),
          latency_ms: non_neg_integer(),
          model: String.t() | nil,
          prompt: String.t(),
          operations: [atom()],
          warnings: [term()]
        }

  @doc "The canonical request option names."
  @spec request_options() :: [atom()]
  def request_options, do: @request_options

  # ── Inputs ─────────────────────────────────────────────────────────────

  @doc """
  Turns caller inputs into what adapters take: data URLs (bytes inlined)
  or http(s) URLs. Accepts raw bytes (type sniffed), `%{data, content_type}`,
  `%{url}`, and bare `data:` / `http(s):` strings. Never hand a provider a
  permanent URL it could cache — pass bytes.
  """
  @spec normalize_inputs([input()]) ::
          {:ok, [String.t()]} | {:error, :invalid_image_input | :empty_input}
  def normalize_inputs([]), do: {:error, :empty_input}

  def normalize_inputs(images) when is_list(images) do
    refs = Enum.map(images, &image_ref/1)
    if Enum.all?(refs, &is_binary/1), do: {:ok, refs}, else: {:error, :invalid_image_input}
  end

  def normalize_inputs(_other), do: {:error, :invalid_image_input}

  defp image_ref(%{data: data, content_type: type})
       when is_binary(data) and byte_size(data) > 0 and is_binary(type) and type != "",
       do: "data:#{type};base64,#{Base.encode64(data)}"

  defp image_ref(%{data: data}) when is_binary(data) and byte_size(data) > 0, do: image_ref(data)
  defp image_ref(%{url: url}) when is_binary(url), do: image_ref(url)
  defp image_ref("data:" <> _ = url), do: url
  defp image_ref("http://" <> _ = url), do: url
  defp image_ref("https://" <> _ = url), do: url

  defp image_ref(bytes) when is_binary(bytes) do
    case OpenAICompatible.sniff(bytes) do
      nil -> nil
      type -> "data:#{type};base64,#{Base.encode64(bytes)}"
    end
  end

  defp image_ref(_other), do: nil

  # ── Options ────────────────────────────────────────────────────────────

  @doc """
  The option map an adapter receives: the endpoint's stored defaults
  underneath the caller's keyword options, canonical keys only.
  """
  @spec options(Endpoint.t(), keyword() | map()) :: map()
  def options(endpoint, opts) do
    given =
      opts
      |> Map.new()
      |> Map.take(@request_options ++ @control_options)
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    endpoint |> endpoint_defaults() |> Map.merge(given)
  end

  defp endpoint_defaults(endpoint) do
    settings = endpoint.provider_settings || %{}

    %{}
    |> put_default(:aspect_ratio, settings["aspect_ratio"])
    |> put_default(:resolution, settings["resolution"])
    |> put_default(:size, Map.get(endpoint, :image_size))
    |> put_default(:quality, Map.get(endpoint, :image_quality))
  end

  defp put_default(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_default(map, _key, _value), do: map

  @doc """
  Keeps `options` inside what the model accepts (or, without a listing,
  what the adapter can send). Returns the fitted options and a warning
  per change, `{:dropped_option, key, value}`, in the canonical option
  order; with `strict: true` the first offender is an error instead.
  """
  @spec fit_options(map(), ImageModel.t() | nil, [atom()], boolean()) ::
          {:ok, map(), [term()]} | {:error, {:unsupported_option, atom(), term()}}
  def fit_options(options, model, adapter_options, strict) do
    {request, control} = Map.split(options, @request_options)

    {kept, warnings} =
      Enum.reduce(@request_options, {%{}, []}, fn key, acc ->
        fit_option(acc, key, Map.fetch(request, key), model, adapter_options)
      end)

    case {strict, Enum.reverse(warnings)} do
      {true, [{:dropped_option, key, value} | _]} -> {:error, {:unsupported_option, key, value}}
      {_, warnings} -> {:ok, Map.merge(control, kept), warnings}
    end
  end

  defp fit_option(acc, _key, :error, _model, _adapter_options), do: acc

  defp fit_option({kept, warnings}, key, {:ok, value}, model, adapter_options) do
    if option_ok?(model, adapter_options, key, value),
      do: {Map.put(kept, key, value), warnings},
      else: {kept, [{:dropped_option, key, value} | warnings]}
  end

  # With a model listing, both the key and the value must be listed —
  # the listing is what that model accepts. Without one, the adapter's
  # static option set decides and values go unchecked.
  defp option_ok?(%ImageModel{} = model, _adapter_options, key, value),
    do: ImageModel.allows?(model, key, value)

  defp option_ok?(nil, adapter_options, key, _value), do: key in adapter_options

  # ── Processing ─────────────────────────────────────────────────────────

  @doc """
  Edits `images` (the first is the subject, the rest are references)
  with the given `operations` on `endpoint`. See the moduledoc.
  """
  @spec process(Endpoint.t(), [input()], [term()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def process(endpoint, images, operations, opts \\ []) do
    adapter = Provider.for_endpoint(endpoint)
    options = options(endpoint, opts)
    model_id = options[:model] || endpoint.model

    with {:ok, refs} <- normalize_inputs(images),
         {:ok, pairs} <- Operations.normalize(operations),
         :ok <- check_references(pairs, refs),
         model = ImageModels.get(endpoint, model_id),
         {:ok, fitted, warnings} <-
           fit_options(
             Map.merge(Operations.options(pairs), options),
             model,
             adapter.image_options(endpoint),
             Keyword.get(opts, :strict, false)
           ),
         :ok <- check_reference_count(model, refs, warnings, opts),
         {:ok, prompt} <- build_prompt(pairs, Keyword.put(opts, :warnings, warnings)),
         {:ok, result} <- adapter.image_edit(endpoint, prompt, refs, fitted) do
      {:ok,
       Map.merge(result, %{
         prompt: prompt,
         operations: Enum.map(pairs, &elem(&1, 0)),
         warnings: warnings,
         model: result[:model] || model_id
       })}
    end
  end

  defp check_references(pairs, refs) do
    if Operations.references_required?(pairs) and length(refs) < 2,
      do: {:error, :reference_image_required},
      else: :ok
  end

  defp check_reference_count(%ImageModel{} = model, refs, _warnings, opts) do
    case ImageModel.max_references(model) do
      max when is_integer(max) and length(refs) > max ->
        if Keyword.get(opts, :strict, false),
          do: {:error, {:too_many_images, length(refs), max}},
          else: :ok

      _ ->
        :ok
    end
  end

  defp check_reference_count(_model, _refs, _warnings, _opts), do: :ok

  @preserve %{
    subject:
      "Keep the subject itself — its shape, proportions, printed text, logos, labels and colours — exactly as it is. Add nothing and remove nothing beyond what is asked.",
    scene:
      "Keep the scene's geometry, camera angle, framing and every object in place; change only what is asked."
  }

  @finish "Output one photorealistic image with the same framing as image 1. No added text or watermark."

  @doc """
  The prompt `process/4` sends for `operations` (normalised or not):
  numbered instructions, the preservation clause (`preserve:`), the
  closing line (`finish: false` drops it). Public so admin pages can
  preview it and tests can pin it.
  """
  @spec build_prompt([term()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_prompt(operations, opts \\ []) do
    warnings = Keyword.get(opts, :warnings, [])
    dropped = for {:dropped_option, key, _} <- warnings, do: key
    render_opts = Keyword.take(opts, [:prompt_overrides])

    with {:ok, pairs} <- Operations.normalize(operations),
         {:ok, sentences} <- render_all(pairs, dropped, render_opts) do
      {:ok,
       [numbered(sentences), preserve_clause(opts[:preserve]), finish_clause(opts[:finish])]
       |> Enum.reject(&is_nil/1)
       |> Enum.join("\n\n")}
    end
  end

  defp numbered([single]), do: single

  defp numbered(sentences) do
    sentences
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {sentence, index} -> "#{index}. #{sentence}" end)
  end

  defp render_all(pairs, dropped, render_opts) do
    Enum.reduce_while(pairs, {:ok, []}, fn {name, params}, {:ok, acc} ->
      fallback = fallback?(name, dropped)

      case Operations.render(name, params, Keyword.put(render_opts, :fallback, fallback)) do
        {:ok, text} -> {:cont, {:ok, acc ++ [text]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # An operation whose implied option was dropped uses its fallback wording.
  defp fallback?(_name, []), do: false

  defp fallback?(name, dropped) do
    case Operations.fetch(name) do
      {:ok, %{options: implied}} -> Enum.any?(Map.keys(implied), &(&1 in dropped))
      _ -> false
    end
  end

  defp preserve_clause(nil), do: @preserve.subject
  defp preserve_clause(false), do: nil
  defp preserve_clause(key) when is_atom(key), do: Map.get(@preserve, key, @preserve.subject)
  defp preserve_clause(text) when is_binary(text), do: text

  defp finish_clause(false), do: nil
  defp finish_clause(text) when is_binary(text), do: text
  defp finish_clause(_), do: @finish

  # ── Vision ─────────────────────────────────────────────────────────────

  @doc """
  Asks a vision-capable chat endpoint about `images`.

  Options: `:prompt` (default "Describe this image in detail."),
  `:system`, `:schema` (JSON Schema map → the answer is requested and
  parsed as that object), `:json` (true → any JSON object), `:model`,
  and the chat sampling options (`:temperature`, `:max_tokens`, `:top_p`,
  `:seed`).

  Returns `{:ok, %{text, json, usage, latency_ms, model}}`; `json` is nil
  unless requested. A JSON answer that does not parse is
  `{:error, {:no_json_in_response, text}}`.
  """
  @spec describe(Endpoint.t(), [input()], keyword()) :: {:ok, map()} | {:error, term()}
  def describe(endpoint, images, opts \\ []) do
    endpoint = if opts[:model], do: %{endpoint | model: opts[:model]}, else: endpoint

    with {:ok, refs} <- normalize_inputs(images) do
      {question, response_format} = question_and_format(opts)

      content = [
        %{"type" => "text", "text" => question}
        | Enum.map(refs, &%{"type" => "image_url", "image_url" => %{"url" => &1}})
      ]

      messages =
        case opts[:system] do
          system when is_binary(system) and system != "" ->
            [%{role: "system", content: system}, %{role: "user", content: content}]

          _ ->
            [%{role: "user", content: content}]
        end

      chat_opts =
        opts
        |> Keyword.take([:temperature, :max_tokens, :top_p, :seed])
        |> Keyword.put(:response_format, response_format)

      with {:ok, response} <- chat_with_json_fallback(endpoint, messages, chat_opts),
           text = content_text(response),
           {:ok, json} <- parse_json(text, json_requested?(opts)) do
        {:ok,
         %{
           text: text,
           json: json,
           usage: Completion.extract_usage(response),
           latency_ms: response["latency_ms"],
           model: response["model"] || endpoint.model
         }}
      end
    end
  end

  defp json_requested?(opts), do: is_map(opts[:schema]) or opts[:json] == true

  # Not every model behind a chat endpoint takes `response_format`
  # (image-output models on OpenRouter answer 400). The prompt already
  # asks for JSON, so a 4xx on a JSON request is retried once without the
  # field and the answer parsed as text.
  defp chat_with_json_fallback(endpoint, messages, chat_opts) do
    case Completion.chat_completion(endpoint, messages, chat_opts) do
      {:error, {:api_error, status}}
      when status in 400..499 and status != 401 and status != 402 and status != 429 ->
        if chat_opts[:response_format],
          do:
            Completion.chat_completion(
              endpoint,
              messages,
              Keyword.delete(chat_opts, :response_format)
            ),
          else: {:error, {:api_error, status}}

      other ->
        other
    end
  end

  defp content_text(response) do
    case Completion.extract_content(response) do
      {:ok, text} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp question_and_format(opts) do
    question = opts[:prompt] || opts[:question] || "Describe this image in detail."

    cond do
      is_map(opts[:schema]) ->
        {question <> "\n\nAnswer only with a JSON object matching the given schema.",
         %{
           "type" => "json_schema",
           "json_schema" => %{
             "name" => opts[:schema_name] || "answer",
             "strict" => true,
             "schema" => opts[:schema]
           }
         }}

      opts[:json] == true ->
        {question <> "\n\nAnswer only with a JSON object.", %{"type" => "json_object"}}

      true ->
        {question, nil}
    end
  end

  defp parse_json(_text, false), do: {:ok, nil}

  defp parse_json(text, true) when is_binary(text) do
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```\z/, "")

    case Jason.decode(cleaned) do
      {:ok, json} when is_map(json) or is_list(json) -> {:ok, json}
      _ -> {:error, {:no_json_in_response, text}}
    end
  end

  defp parse_json(text, true), do: {:error, {:no_json_in_response, text}}

  @compare_schema %{
    "type" => "object",
    "properties" => %{
      "same_subject" => %{
        "type" => "boolean",
        "description" =>
          "The edited image shows the same subject with the same shape and proportions"
      },
      "text_and_logos_preserved" => %{
        "type" => "boolean",
        "description" => "Printed text, logos and labels on the subject are unchanged and legible"
      },
      "unwanted_changes" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Changes that were not asked for, one short sentence each"
      },
      "summary" => %{"type" => "string", "description" => "One sentence on what changed"}
    },
    "required" => ["same_subject", "text_and_logos_preserved", "unwanted_changes", "summary"],
    "additionalProperties" => false
  }

  @doc """
  Checks an edit against its original with a vision model: did the
  subject, its text and logos survive, and what changed that was not
  asked for. `intent:` describes the edit that was requested.

  Returns `{:ok, %{passed: boolean, same_subject, text_and_logos_preserved,
  unwanted_changes, summary, usage, latency_ms, model}}`.
  """
  @spec compare(Endpoint.t(), input(), input(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare(endpoint, before, after_image, opts \\ []) do
    intent = opts[:intent] || "an edit"

    prompt =
      "Image 1 is the original photograph. Image 2 is an edited version of it; the requested edit was: #{intent}. " <>
        "Judge only image 2 against image 1."

    describe_opts =
      opts
      |> Keyword.take([:model, :temperature, :max_tokens])
      |> Keyword.merge(prompt: prompt, schema: @compare_schema, schema_name: "edit_check")

    case describe(endpoint, [before, after_image], describe_opts) do
      {:ok, %{json: json} = result} when is_map(json) -> {:ok, verdict(json, result)}
      {:ok, %{text: text}} -> {:error, {:no_json_in_response, text}}
      {:error, _} = error -> error
    end
  end

  defp verdict(json, result) do
    same = json["same_subject"] == true
    text_ok = json["text_and_logos_preserved"] == true
    unwanted = List.wrap(json["unwanted_changes"])

    %{
      passed: same and text_ok and unwanted == [],
      same_subject: same,
      text_and_logos_preserved: text_ok,
      unwanted_changes: unwanted,
      summary: json["summary"],
      usage: result.usage,
      latency_ms: result.latency_ms,
      model: result.model
    }
  end
end
