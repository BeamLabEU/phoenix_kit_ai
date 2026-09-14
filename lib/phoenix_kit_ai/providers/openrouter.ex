defmodule PhoenixKitAI.Providers.OpenRouter do
  @moduledoc """
  `PhoenixKitAI.Provider` adapter for OpenRouter's unified Images API.

  `POST <base_url>/images` serves both generation and editing: the prompt
  plus typed options (`aspect_ratio`, `resolution`, `size`, `quality`,
  `background`, `output_format`, `output_compression`, `n`, `seed`) and,
  for edits, the inputs as `input_references`. Every image model on the
  gateway — Gemini's, OpenAI's, Seedream, FLUX, Grok Imagine, Qwen and
  the rest — sits behind the same request, and `GET /images/models` says
  per model which options it accepts (see `PhoenixKitAI.Images.ImageModel`).

  `transport: :chat` keeps the older chat-completions path (image parts,
  `modalities: ["image","text"]`) for models that only answer there.

  `provider_options` becomes OpenRouter's `provider.options` object;
  `provider_routing` (`order`, `only`, `ignore`, `sort`,
  `allow_fallbacks`) is merged into the same `provider` object.
  """

  @behaviour PhoenixKitAI.Provider

  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Images.ImageModel
  alias PhoenixKitAI.Providers.{HTTP, OpenAICompatible}

  @typed_options ~w(n aspect_ratio resolution size quality background output_format output_compression seed)a
  @chat_extras %{"modalities" => ["image", "text"], "usage" => %{"include" => true}}

  @impl true
  def image_edit(endpoint, prompt, refs, %{transport: :chat} = options),
    do: OpenAICompatible.chat_edit(endpoint, prompt, refs, options, @chat_extras)

  def image_edit(endpoint, prompt, refs, options) do
    references = Enum.map(refs, &%{"type" => "image_url", "image_url" => %{"url" => &1}})

    endpoint
    |> body(prompt, options)
    |> Map.put("input_references", references)
    |> then(&OpenAICompatible.post_images(endpoint, "/images", &1, options))
  end

  @impl true
  def image_generate(endpoint, prompt, options),
    do:
      OpenAICompatible.post_images(endpoint, "/images", body(endpoint, prompt, options), options)

  @impl true
  def image_models(endpoint) do
    url = Completion.url(endpoint, "/images/models")

    with {:ok, %{status: 200, body: response}} <-
           HTTP.get_json(url, OpenAICompatible.headers(endpoint), timeout: 15_000),
         {:ok, %{"data" => entries}} when is_list(entries) <- HTTP.body_map(response) do
      {:ok, entries |> Enum.filter(&is_map/1) |> Enum.map(&ImageModel.from_openrouter/1)}
    else
      {:ok, %{status: status, body: response}} -> HTTP.error(status, response)
      {:ok, _other} -> {:error, :invalid_response_format}
      {:error, _} = error -> error
    end
  end

  @impl true
  def image_options(_endpoint), do: @typed_options

  defp body(endpoint, prompt, options) do
    %{"model" => OpenAICompatible.model(endpoint, options), "prompt" => prompt}
    |> OpenAICompatible.put_options(options, @typed_options)
    |> put_provider(options)
  end

  # `provider_options` → provider.options; `provider_routing` → the rest
  # of the provider object (order / only / ignore / sort / allow_fallbacks).
  defp put_provider(body, options) do
    routing =
      case options[:provider_routing] do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end

    provider =
      case options[:provider_options] do
        map when is_map(map) and map_size(map) > 0 ->
          Map.put(routing, "options", Map.new(map, fn {k, v} -> {to_string(k), v} end))

        _ ->
          routing
      end

    if map_size(provider) == 0, do: body, else: Map.put(body, "provider", provider)
  end
end
