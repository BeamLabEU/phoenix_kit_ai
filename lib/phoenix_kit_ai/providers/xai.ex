defmodule PhoenixKitAI.Providers.XAI do
  @moduledoc """
  `PhoenixKitAI.Provider` adapter for xAI's image endpoints.

    * Editing: `POST <base_url>/images/edits` as JSON — `image` is one
      `{url, type: "image_url"}` object or a list of them (xAI documents
      up to 5 sources); served by the Grok Imagine image models.
    * Generation: `POST <base_url>/images/generations`.

  xAI takes `aspect_ratio` / `resolution` / `n` /
  `response_format`, never OpenAI's `size`. It publishes no per-model
  option listing, so `image_options/1` is the static set.
  """

  @behaviour PhoenixKitAI.Provider

  alias PhoenixKitAI.Providers.OpenAICompatible

  @options ~w(n response_format aspect_ratio resolution)a

  @impl true
  def image_edit(endpoint, prompt, refs, options) do
    image =
      case Enum.map(refs, &%{"url" => &1, "type" => "image_url"}) do
        [single] -> single
        many -> many
      end

    body =
      %{
        "model" => OpenAICompatible.model(endpoint, options),
        "prompt" => prompt,
        "image" => image
      }
      |> OpenAICompatible.put_options(options, @options)
      |> OpenAICompatible.merge_provider_options(options)

    OpenAICompatible.post_images(endpoint, "/images/edits", body, options)
  end

  @impl true
  def image_generate(endpoint, prompt, options) do
    body =
      %{"model" => OpenAICompatible.model(endpoint, options), "prompt" => prompt}
      |> OpenAICompatible.put_options(options, @options)
      |> OpenAICompatible.merge_provider_options(options)

    OpenAICompatible.post_images(endpoint, "/images/generations", body, options)
  end

  @impl true
  def image_models(_endpoint), do: {:error, :not_supported}

  @impl true
  def image_options(_endpoint), do: @options
end
