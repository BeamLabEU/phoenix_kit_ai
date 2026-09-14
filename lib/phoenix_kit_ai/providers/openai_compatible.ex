defmodule PhoenixKitAI.Providers.OpenAICompatible do
  @moduledoc """
  The default `PhoenixKitAI.Provider` adapter: what any OpenAI-shaped API
  offers with no provider-specific knowledge.

    * **Editing** goes through `POST <base_url>/chat/completions` with the
      prompt and the images as `image_url` content parts — the way
      gateways serve image-capable chat models (Gemini's image models,
      for one). The output arrives on `choices[0].message.images[]` or as
      an image content part. An `aspect_ratio` option travels as Gemini's
      `image_config`.
    * **Generation** goes through `POST <base_url>/images/generations`.
    * No model capability listing.

  The other adapters reuse its pieces (`chat_edit/5`, `post_images/4`,
  the decoders) and override only the transport that differs.
  """

  @behaviour PhoenixKitAI.Provider

  alias PhoenixKitAI.{Completion, OpenRouterClient}
  alias PhoenixKitAI.Providers.HTTP

  @generation_options ~w(n response_format size quality style background output_format aspect_ratio resolution seed)a

  @impl true
  def image_edit(endpoint, prompt, refs, options),
    do: chat_edit(endpoint, prompt, refs, options, %{})

  @impl true
  def image_generate(endpoint, prompt, options) do
    body =
      %{"model" => model(endpoint, options), "prompt" => prompt}
      |> put_options(options, @generation_options)
      |> merge_provider_options(options)

    post_images(endpoint, "/images/generations", body, options)
  end

  @impl true
  def image_models(_endpoint), do: {:error, :not_supported}

  @doc """
  Vision through chat completions: `messages` already carry the image
  parts; `options` may hold `:response_format` and the sampling keys.
  Not every model behind a chat endpoint takes `response_format`
  (image-output models answer 400), so a 4xx on a JSON request is retried
  once without the field — the prompt asks for JSON anyway.
  """
  @impl true
  def vision(endpoint, messages, options) do
    chat_opts =
      options
      |> Map.take([:temperature, :max_tokens, :top_p, :seed, :response_format])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    json? = is_map(options[:response_format])

    case Completion.chat_completion(endpoint, messages, chat_opts) do
      {:error, {:api_error, status}} when status in [400, 422] and json? ->
        Completion.chat_completion(
          endpoint,
          messages,
          Keyword.delete(chat_opts, :response_format)
        )

      other ->
        other
    end
  end

  @impl true
  def image_options(_endpoint), do: @generation_options

  # ── Shared transports ──────────────────────────────────────────────────

  @doc false
  # Chat-completions image editing. `extra` is merged into the body for
  # gateways with request extensions (OpenRouter's `modalities`).
  def chat_edit(endpoint, prompt, refs, options, extra) when is_map(extra) do
    url = Completion.url(endpoint, "/chat/completions")
    used_model = model(endpoint, options)

    content = [
      %{"type" => "text", "text" => prompt}
      | Enum.map(refs, &%{"type" => "image_url", "image_url" => %{"url" => &1}})
    ]

    body =
      %{"model" => used_model, "messages" => [%{"role" => "user", "content" => content}]}
      |> maybe_put("image_config", image_config(options))
      |> Map.merge(extra)
      |> merge_provider_options(options)

    started = System.monotonic_time(:millisecond)

    case HTTP.post_json(url, headers(endpoint), body) do
      {:ok, %{status: 200, body: response}} -> decode_chat_images(response, started, used_model)
      {:ok, %{status: status, body: response}} -> HTTP.error(status, response)
      {:error, _} = error -> error
    end
  end

  @doc false
  # POSTs an images-API body and decodes a `data[]` response.
  def post_images(endpoint, path, body, _options) do
    url = Completion.url(endpoint, path)
    started = System.monotonic_time(:millisecond)

    case HTTP.post_json(url, headers(endpoint), body) do
      {:ok, %{status: 200, body: response}} ->
        decode_data_images(response, started, body["model"])

      {:ok, %{status: status, body: response}} ->
        HTTP.error(status, response)

      {:error, _} = error ->
        error
    end
  end

  # ── Decoders ───────────────────────────────────────────────────────────

  @doc false
  # `{"data": [{"b64_json": …, "media_type": …} | {"url": …}], "usage": …}`
  def decode_data_images(response, started, model) do
    latency_ms = System.monotonic_time(:millisecond) - started

    with {:ok, map} <- HTTP.body_map(response),
         {:ok, entries} <- data_entries(map),
         {:ok, images} <- usable(Enum.map(entries, &decode_data_entry/1)) do
      {:ok,
       %{
         images: images,
         text: nil,
         usage: Completion.extract_usage(map),
         latency_ms: latency_ms,
         model: map["model"] || model
       }}
    end
  end

  # An entry with neither bytes nor a URL (undecodable base64, an empty
  # object) is dropped; a response with none left is not a success.
  defp usable(images) do
    case Enum.filter(images, &(is_binary(&1.data) or is_binary(&1.url))) do
      [] -> {:error, :invalid_response_format}
      images -> {:ok, images}
    end
  end

  defp data_entries(%{"data" => entries}) when is_list(entries) and entries != [],
    do: {:ok, entries}

  defp data_entries(_map), do: {:error, :invalid_response_format}

  defp decode_data_entry(%{"b64_json" => b64} = entry) when is_binary(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, bytes} ->
        %{data: bytes, url: nil, content_type: entry["media_type"] || sniff(bytes)}

      :error ->
        %{data: nil, url: nil, content_type: nil}
    end
  end

  defp decode_data_entry(%{"url" => url}) when is_binary(url),
    do: %{data: nil, url: url, content_type: nil}

  defp decode_data_entry(_entry), do: %{data: nil, url: nil, content_type: nil}

  @doc false
  # A chat completion whose message carries images (OpenRouter puts them
  # on `message.images`; some gateways use content parts).
  def decode_chat_images(response, started, model) do
    latency_ms = System.monotonic_time(:millisecond) - started

    case HTTP.body_map(response) do
      {:ok, %{"choices" => [%{"message" => message} | _]} = map} when is_map(message) ->
        chat_images(message, map, latency_ms, model)

      {:ok, %{"choices" => []}} ->
        {:error, :no_choices_in_response}

      {:ok, _} ->
        {:error, :invalid_response_format}

      {:error, _} = error ->
        error
    end
  end

  defp chat_images(message, map, latency_ms, model) do
    text = message_text(message)

    with urls when urls != [] <- message_image_urls(message),
         {:ok, images} <- usable(Enum.map(urls, &Completion.decode_image_url/1)) do
      {:ok,
       %{
         images: images,
         text: text,
         usage: Completion.extract_usage(map),
         latency_ms: latency_ms,
         model: map["model"] || model
       }}
    else
      [] -> {:error, {:no_image_in_response, text}}
      {:error, _} = error -> error
    end
  end

  defp message_image_urls(message) do
    from_images =
      for %{"image_url" => %{"url" => url}} <- List.wrap(message["images"]),
          is_binary(url),
          do: url

    from_content =
      case message["content"] do
        parts when is_list(parts) ->
          for %{"type" => type, "image_url" => %{"url" => url}} <- parts,
              type in ["image_url", "output_image"],
              is_binary(url),
              do: url

        _ ->
          []
      end

    from_images ++ from_content
  end

  defp message_text(%{"content" => text}) when is_binary(text) and text != "", do: text

  defp message_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp message_text(_message), do: nil

  # ── Small helpers shared by the adapters ───────────────────────────────

  @doc false
  def model(endpoint, options), do: options[:model] || endpoint.model

  @doc false
  def headers(endpoint), do: OpenRouterClient.build_headers_from_endpoint(endpoint)

  @doc false
  # Copies the listed option keys onto the body under their string names,
  # skipping nils.
  def put_options(body, options, keys) do
    Enum.reduce(keys, body, fn key, acc -> maybe_put(acc, Atom.to_string(key), options[key]) end)
  end

  @doc false
  def merge_provider_options(body, %{provider_options: extra}) when is_map(extra),
    do: Map.merge(body, Map.new(extra, fn {k, v} -> {to_string(k), v} end))

  def merge_provider_options(body, _options), do: body

  @doc false
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  # Gemini-through-a-gateway aspect ratio; a caller's own `image_config`
  # map still wins key by key.
  defp image_config(options) do
    base = if options[:aspect_ratio], do: %{"aspect_ratio" => options[:aspect_ratio]}, else: %{}

    case options[:image_config] do
      config when is_map(config) and map_size(config) > 0 ->
        Map.merge(base, Map.new(config, fn {k, v} -> {to_string(k), v} end))

      _ when map_size(base) == 0 ->
        nil

      _ ->
        base
    end
  end

  @doc false
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(<<"GIF8", _::binary>>), do: "image/gif"
  def sniff(_bytes), do: nil
end
