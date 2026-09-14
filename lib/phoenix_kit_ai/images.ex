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
  `:response_format`, `:style`, `:mask`. Control options: `:model` (override the endpoint's
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

  import Bitwise

  alias PhoenixKitAI.{Completion, Endpoint, Provider, StructuredOutput}
  alias PhoenixKitAI.Images.{ImageModel, ImageModels, Operations}
  alias PhoenixKitAI.Providers.{HTTP, OpenAICompatible}

  @request_options ~w(aspect_ratio resolution size quality background output_format output_compression n seed response_format style mask)a
  @control_options ~w(model transport provider_options provider_routing image_config strict preserve finish prompt_overrides dry_run fetch_outputs max_input_bytes)a

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

  @typedoc """
  Every error the image verbs return, so a caller can match exhaustively.
  Transport and provider errors come from `PhoenixKitAI.Completion`
  (`:rate_limited`, `:request_timeout`, `{:api_error, status}`,
  `{:connection_error, reason}`, …).
  """
  @type error ::
          :empty_input
          | :invalid_image_input
          | :reference_image_required
          | :not_supported
          | {:image_too_large, pos_integer(), pos_integer()}
          | {:unsafe_url, String.t()}
          | {:fetch_failed, String.t(), term()}
          | {:unknown_operation, term()}
          | {:missing_parameter, atom(), atom()}
          | {:conflicting_operations, atom(), atom()}
          | {:unsupported_option, atom(), term()}
          | {:too_many_images, pos_integer(), pos_integer()}
          | {:model_not_listed, String.t()}
          | {:capabilities_unavailable, term()}
          | {:no_image_in_response, String.t() | nil}
          | {:no_json_in_response, String.t() | nil}
          | {:content_policy, String.t()}
          | atom()
          | {atom(), term()}

  @typedoc "What `process/4` returns for `dry_run: true`: the plan, no images."
  @type plan :: %{
          prompt: String.t(),
          operations: [atom()],
          warnings: [term()],
          model: String.t() | nil,
          options: map(),
          images: [],
          text: nil,
          usage: map(),
          latency_ms: 0,
          dry_run: true
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
  @spec normalize_inputs([input()], keyword()) :: {:ok, [String.t()]} | {:error, error()}
  def normalize_inputs(images, opts \\ [])
  def normalize_inputs([], _opts), do: {:error, :empty_input}

  def normalize_inputs(images, opts) when is_list(images) do
    max = Keyword.get(opts, :max_input_bytes, HTTP.max_image_bytes())
    # All inputs together may take four times one image's allowance.
    total_max = Keyword.get(opts, :max_total_input_bytes, max * 4)

    images
    |> Enum.reduce_while({:ok, [], 0}, fn image, {:ok, acc, total} ->
      total = total + (image_bytes(image) || 0)

      if total > total_max,
        do: {:halt, {:error, {:image_too_large, total, total_max}}},
        else: collect_ref(checked_ref(image, max), acc, total)
    end)
    |> case do
      {:ok, refs, _total} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  def normalize_inputs(_other, _opts), do: {:error, :invalid_image_input}

  defp collect_ref({:ok, ref}, acc, total), do: {:cont, {:ok, [ref | acc], total}}
  defp collect_ref({:error, _} = error, _acc, _total), do: {:halt, error}

  # Size is checked on the bytes we were handed; a remote URL is checked
  # against the fetch policy (scheme, no internal hosts).
  defp checked_ref(image, max) do
    case {image_bytes(image), image_ref(image)} do
      {bytes, _} when is_integer(bytes) and bytes > max ->
        {:error, {:image_too_large, bytes, max}}

      {_, nil} ->
        {:error, :invalid_image_input}

      {_, "http" <> _ = url} ->
        if HTTP.safe_url?(url), do: {:ok, url}, else: {:error, {:unsafe_url, url}}

      {_, ref} ->
        {:ok, ref}
    end
  end

  defp image_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp image_bytes(%{url: "data:" <> _ = url}), do: image_bytes(url)
  # A base64 data URL carries three bytes for every four characters.
  defp image_bytes("data:" <> rest), do: div(byte_size(rest) * 3, 4)
  defp image_bytes("http" <> _), do: nil
  defp image_bytes(bytes) when is_binary(bytes), do: byte_size(bytes)
  defp image_bytes(_other), do: nil

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

    endpoint
    |> endpoint_defaults(Provider.for_endpoint(endpoint).image_options(endpoint))
    |> Map.merge(given)
  end

  # Stored defaults only where the provider can take them: an xAI endpoint
  # with an `image_size` column set must not grow a `size` it cannot send.
  defp endpoint_defaults(endpoint, accepted) do
    settings = endpoint.provider_settings || %{}

    %{}
    |> put_default(:aspect_ratio, settings["aspect_ratio"])
    |> put_default(:resolution, settings["resolution"])
    |> put_default(:size, Map.get(endpoint, :image_size))
    |> put_default(:quality, Map.get(endpoint, :image_quality))
    |> Map.take(accepted)
  end

  defp put_default(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_default(map, _key, _value), do: map

  @doc """
  Keeps `options` inside what the adapter can send (`adapter_options`)
  and, when there is a model listing, what the model accepts. Returns the
  fitted options and a warning per change, `{:dropped_option, key,
  value}`, in the canonical option order; with `strict: true` the first
  offender is an error instead.
  """
  @adapter_controls ~w(model transport provider_options provider_routing image_config)a

  @spec fit_options(map(), ImageModel.t() | nil, [atom()], boolean()) ::
          {:ok, map(), [term()]} | {:error, {:unsupported_option, atom(), term()}}
  def fit_options(options, model, adapter_options, strict) do
    {request, control} = Map.split(options, @request_options)
    control = Map.take(control, @adapter_controls)

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
      else: {kept, [redact_warning({:dropped_option, key, value}) | warnings]}
  end

  # A key the adapter does not send on this call is dropped whatever the
  # listing says (OpenRouter's chat transport sends only an aspect ratio,
  # though the model behind it lists more). With a model listing the key
  # and the value must also be listed — the listing is what that model
  # accepts; without one, values go unchecked.
  defp option_ok?(model, adapter_options, key, value),
    do: key in adapter_options and (is_nil(model) or ImageModel.allows?(model, key, value))

  # ── Processing ─────────────────────────────────────────────────────────

  @doc """
  Edits `images` (the first is the subject, the rest are references)
  with the given `operations` on `endpoint`. See the moduledoc.
  """
  @spec process(Endpoint.t(), [input()], [term()], keyword()) ::
          {:ok, result() | plan()} | {:error, error()}
  def process(endpoint, images, operations, opts \\ []) do
    adapter = Provider.for_endpoint(endpoint)
    options = options(endpoint, opts)
    model_id = options[:model] || endpoint.model
    strict = Keyword.get(opts, :strict, false)
    sendable = Provider.edit_options(adapter, endpoint, options)

    with {:ok, refs} <- normalize_inputs(images, opts),
         {:ok, options} <- normalize_mask(options, opts[:mask], opts),
         {:ok, pairs} <- Operations.normalize(operations),
         :ok <- check_references(pairs, refs),
         {:ok, model, capability_warnings} <- capabilities(endpoint, model_id, strict),
         {merged, conflict_warnings} =
           resolve_conflicts(layer_options(endpoint, sendable, pairs, opts, options)),
         {:ok, fitted, fit_warnings} <- fit_options(merged, model, sendable, strict),
         :ok <- check_reference_count(model, refs),
         warnings = capability_warnings ++ conflict_warnings ++ fit_warnings,
         {:ok, prompt} <- build_prompt(pairs, Keyword.put(opts, :warnings, warnings)) do
      plan = %{
        prompt: prompt,
        operations: Enum.map(pairs, &elem(&1, 0)),
        warnings: warnings,
        model: model_id,
        options: fitted
      }

      if Keyword.get(opts, :dry_run, false),
        do:
          {:ok,
           Map.merge(plan, %{images: [], text: nil, usage: %{}, latency_ms: 0, dry_run: true})},
        else: run(adapter, endpoint, refs, plan, opts)
    end
  end

  defp run(adapter, endpoint, refs, plan, opts) do
    with {:ok, result} <- adapter.image_edit(endpoint, plan.prompt, refs, plan.options),
         {:ok, result} <- fetch_outputs(result, opts) do
      {:ok,
       result
       |> Map.merge(Map.drop(plan, [:options, :warnings]))
       |> Map.put(:model, result[:model] || plan.model)
       |> Map.update(:warnings, plan.warnings, &(plan.warnings ++ &1))}
    end
  end

  # Endpoint defaults underneath (only the ones this edit can send — a
  # stored `image_size` is no warning on a chat edit that never sends one),
  # the operations' implied options on top of those, the caller's own
  # options on top of everything — an operation's `resolution: "4K"` beats
  # a stored "1K", and a caller beats both.
  defp layer_options(endpoint, sendable, pairs, opts, options) do
    # The caller's own request options (a normalised mask is not "given").
    given = opts |> Map.new() |> Map.take(Map.keys(options) -- [:mask])

    endpoint
    |> endpoint_defaults(sendable)
    |> Map.merge(Operations.options(pairs))
    # Control options and the normalised mask; request options come from `given`.
    |> Map.merge(Map.drop(options, @request_options -- [:mask]))
    |> Map.merge(Map.reject(given, fn {_k, v} -> v in [nil, ""] end))
  end

  @doc """
  Normalises a `mask:` input into the request option adapters receive (a
  data URL) — the OpenAI adapter sends it as the `mask` file, the others
  drop it with a `{:dropped_option, :mask, _}` warning. Used by
  `process/4` and by the thin `PhoenixKitAI.Completion.edit_image/4`.
  """
  @spec normalize_mask(map(), input() | nil, keyword()) :: {:ok, map()} | {:error, error()}
  def normalize_mask(options, nil, _opts), do: {:ok, Map.delete(options, :mask)}

  def normalize_mask(options, mask, opts) do
    with {:ok, [ref]} <- normalize_inputs([mask], opts), do: {:ok, Map.put(options, :mask, ref)}
  end

  @doc "The question `describe/3` asks when the caller gives none."
  @spec default_question() :: String.t()
  def default_question, do: "Describe this image in detail."

  @doc """
  A warning with any long binary payload replaced by its size — a dropped
  `:mask` carries a whole data URL; logs and screens get
  `{:dropped_option, :mask, {:bytes, 12345}}` instead.
  """
  @spec redact_warning(term()) :: term()
  def redact_warning(warning) when is_tuple(warning) do
    warning
    |> Tuple.to_list()
    |> Enum.map(fn
      value when is_binary(value) and byte_size(value) > 120 -> {:bytes, byte_size(value)}
      value -> value
    end)
    |> List.to_tuple()
  end

  def redact_warning(warning), do: warning

  # What the model accepts, and a warning when that could not be known:
  # the model is missing from the listing, or the listing was unreachable.
  # Under strict the unknown fails closed instead of falling back to the
  # adapter's static option set.
  defp capabilities(endpoint, model_id, strict) do
    case ImageModels.lookup(endpoint, model_id) do
      {:ok, model} ->
        {:ok, model, []}

      {:error, :not_supported} ->
        {:ok, nil, []}

      {:error, :not_listed} when strict ->
        {:error, {:model_not_listed, model_id}}

      {:error, :not_listed} ->
        {:ok, nil, [{:model_not_listed, model_id}]}

      {:error, {:unavailable, reason}} when strict ->
        {:error, {:capabilities_unavailable, reason}}

      {:error, {:unavailable, reason}} ->
        {:ok, nil, [{:capabilities_unavailable, reason}]}
    end
  end

  # A transparent background needs a format with alpha; a JPEG request
  # alongside it is corrected rather than sent.
  defp resolve_conflicts(%{background: "transparent", output_format: format} = options)
       when format in ["jpeg", "jpg"] do
    {Map.put(options, :output_format, "png"), [{:adjusted_option, :output_format, format, "png"}]}
  end

  defp resolve_conflicts(options), do: {options, []}

  @doc """
  Downloads output images a provider returned as URLs (xAI, OpenAI's
  `response_format: "url"`) so callers always get bytes, and adds
  `width` / `height` to every image whose header can be read. A URL that
  cannot be fetched stays a URL, with an `{:output_not_fetched, url,
  reason}` warning. `fetch_outputs: false` skips the download.
  """
  @spec fetch_outputs(map(), keyword()) :: {:ok, map()}
  def fetch_outputs(%{images: images} = result, opts) when is_list(images) do
    fetch? = Keyword.get(opts, :fetch_outputs, true)

    {images, warnings} =
      Enum.map_reduce(images, [], fn image, warnings ->
        case image do
          %{data: nil, url: url} when is_binary(url) and fetch? ->
            fetch_output(image, url, warnings)

          _ ->
            {with_dimensions(image), warnings}
        end
      end)

    {:ok,
     result |> Map.put(:images, images) |> Map.update(:warnings, warnings, &(&1 ++ warnings))}
  end

  def fetch_outputs(result, _opts), do: {:ok, result}

  defp fetch_output(image, url, warnings) do
    case HTTP.fetch_image(url) do
      {:ok, bytes, type} ->
        {with_dimensions(%{image | data: bytes, content_type: image[:content_type] || type}),
         warnings}

      {:error, reason} ->
        {image, warnings ++ [{:output_not_fetched, url, reason}]}
    end
  end

  defp with_dimensions(%{data: data} = image) when is_binary(data) do
    case dimensions(data) do
      {:ok, {w, h}} -> Map.merge(image, %{width: w, height: h})
      :error -> image
    end
  end

  defp with_dimensions(image), do: image

  @doc "Pixel dimensions from a PNG, JPEG, WebP or GIF header, without decoding."
  @spec dimensions(binary()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def dimensions(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary-size(8), w::32, h::32, _::binary>>),
    do: {:ok, {w, h}}

  def dimensions(<<"GIF8", _::binary-size(2), w::little-16, h::little-16, _::binary>>),
    do: {:ok, {w, h}}

  def dimensions(
        <<"RIFF", _::binary-size(4), "WEBPVP8 ", _::binary-size(10), w::little-16, h::little-16,
          _::binary>>
      ),
      do: {:ok, {w &&& 0x3FFF, h &&& 0x3FFF}}

  def dimensions(
        <<"RIFF", _::binary-size(4), "WEBPVP8L", _::binary-size(5), b0, b1, b2, b3, _::binary>>
      ) do
    bits = b0 ||| b1 <<< 8 ||| b2 <<< 16 ||| b3 <<< 24
    {:ok, {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}}
  end

  def dimensions(
        <<"RIFF", _::binary-size(4), "WEBPVP8X", _::binary-size(8), w::little-24, h::little-24,
          _::binary>>
      ),
      do: {:ok, {w + 1, h + 1}}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dimensions(rest)
  def dimensions(_other), do: :error

  # Walk JPEG segments to the first SOF marker.
  defp jpeg_dimensions(<<0xFF, marker, len::16, rest::binary>>)
       when marker in [0xC0, 0xC1, 0xC2] do
    case rest do
      <<_precision, h::16, w::16, _::binary>> when len >= 7 -> {:ok, {w, h}}
      _ -> :error
    end
  end

  defp jpeg_dimensions(<<0xFF, 0xD9, _::binary>>), do: :error
  defp jpeg_dimensions(<<0xFF, 0xFF, rest::binary>>), do: jpeg_dimensions(<<0xFF, rest::binary>>)

  defp jpeg_dimensions(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    case rest do
      <<_::binary-size(len - 2), next::binary>> -> jpeg_dimensions(next)
      _ -> :error
    end
  end

  defp jpeg_dimensions(_), do: :error

  defp check_references(pairs, refs) do
    if Operations.references_required?(pairs) and length(refs) < 2,
      do: {:error, :reference_image_required},
      else: :ok
  end

  # A published maximum is a hard limit: the provider would reject the
  # request anyway, so it is refused here regardless of strict mode.
  defp check_reference_count(%ImageModel{} = model, refs) do
    case ImageModel.max_references(model) do
      max when is_integer(max) and length(refs) > max ->
        {:error, {:too_many_images, length(refs), max}}

      _ ->
        :ok
    end
  end

  defp check_reference_count(_model, _refs), do: :ok

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
  @spec describe(Endpoint.t(), [input()], keyword()) :: {:ok, map()} | {:error, error()}
  def describe(endpoint, images, opts \\ []) do
    endpoint = if opts[:model], do: %{endpoint | model: opts[:model]}, else: endpoint
    opts = Keyword.put_new(opts, :prompt, opts[:question] || default_question())

    with {:ok, refs} <- normalize_inputs(images, opts) do
      {suffix, response_format} = StructuredOutput.request(opts)
      question = if suffix, do: opts[:prompt] <> "\n\n" <> suffix, else: opts[:prompt]

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

      vision_opts =
        opts
        |> Keyword.take([:temperature, :max_tokens, :top_p, :seed])
        |> Map.new()
        |> Map.put(:response_format, response_format)

      with {:ok, response} <- vision(endpoint, messages, vision_opts),
           text = content_text(response),
           {:ok, json} <- StructuredOutput.parse(text, StructuredOutput.requested?(opts)) do
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

  # The adapter's own vision when it has one; chat completions otherwise.
  defp vision(endpoint, messages, options) do
    adapter = Provider.for_endpoint(endpoint)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :vision, 3),
      do: adapter.vision(endpoint, messages, options),
      else: OpenAICompatible.vision(endpoint, messages, options)
  end

  defp content_text(response) do
    case Completion.extract_content(response) do
      {:ok, text} when is_binary(text) -> text
      _ -> nil
    end
  end

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
  @spec compare(Endpoint.t(), input(), input(), keyword()) :: {:ok, map()} | {:error, error()}
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
