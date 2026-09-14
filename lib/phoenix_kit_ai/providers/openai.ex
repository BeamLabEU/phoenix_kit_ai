defmodule PhoenixKitAI.Providers.OpenAI do
  @moduledoc """
  `PhoenixKitAI.Provider` adapter for OpenAI's own Images API.

    * Editing: `POST <base_url>/images/edits` as multipart form data —
      the GPT Image models take the sources as `image[]` files, never as
      URLs, so data URLs are decoded to bytes and http(s) references are
      downloaded first.
    * Generation: `POST <base_url>/images/generations` (JSON).

  OpenAI sizes images with `size` (`1024x1024`, `1536x1024`, `1024x1536`,
  `auto`); a canonical `aspect_ratio` is mapped onto it when no `size`
  was given. `background: "transparent"` and `output_format` are
  supported on the GPT Image models.
  """

  @behaviour PhoenixKitAI.Provider

  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Providers.{HTTP, OpenAICompatible}

  @edit_options ~w(n size quality background output_format output_compression)a
  @generation_options ~w(n response_format size quality style background output_format)a

  @sizes %{"1:1" => "1024x1024", "3:2" => "1536x1024", "2:3" => "1024x1536", "auto" => "auto"}

  @impl true
  def image_edit(endpoint, prompt, refs, options) do
    options = put_size(options)

    with {:ok, files} <- files(refs) do
      form =
        [{"model", OpenAICompatible.model(endpoint, options)}, {"prompt", prompt}] ++
          Enum.map(files, fn {bytes, type} ->
            {"image[]", {bytes, filename: "image.#{extension(type)}", content_type: type}}
          end) ++
          option_fields(options, @edit_options)

      url = Completion.url(endpoint, "/images/edits")
      started = System.monotonic_time(:millisecond)

      case HTTP.post_multipart(url, OpenAICompatible.headers(endpoint), form) do
        {:ok, %{status: 200, body: response}} ->
          OpenAICompatible.decode_data_images(
            response,
            started,
            OpenAICompatible.model(endpoint, options)
          )

        {:ok, %{status: status, body: response}} ->
          HTTP.error(status, response)

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def image_generate(endpoint, prompt, options) do
    options = put_size(options)

    body =
      %{"model" => OpenAICompatible.model(endpoint, options), "prompt" => prompt}
      |> OpenAICompatible.put_options(options, @generation_options)
      |> OpenAICompatible.merge_provider_options(options)

    OpenAICompatible.post_images(endpoint, "/images/generations", body, options)
  end

  @impl true
  def image_models(_endpoint), do: {:error, :not_supported}

  @impl true
  def image_options(_endpoint), do: [:aspect_ratio | @edit_options]

  defp put_size(%{size: size} = options) when is_binary(size) and size != "", do: options

  defp put_size(%{aspect_ratio: ratio} = options) when is_binary(ratio) do
    case Map.fetch(@sizes, ratio) do
      {:ok, size} -> Map.put(options, :size, size)
      :error -> options
    end
  end

  defp put_size(options), do: options

  defp option_fields(options, keys) do
    for key <- keys,
        value = options[key],
        value not in [nil, ""],
        do: {Atom.to_string(key), to_string(value)}
  end

  # Multipart wants bytes: inline data URLs decode locally, http(s)
  # references are fetched (30 s, no redirects off-host trickery beyond Req's).
  defp files(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case file(ref) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp file("data:" <> _ = url) do
    case Completion.decode_image_url(url) do
      %{data: bytes, content_type: type} when is_binary(bytes) ->
        {:ok, {bytes, type || OpenAICompatible.sniff(bytes) || "image/png"}}

      _ ->
        {:error, :invalid_image_input}
    end
  end

  defp file(url) when is_binary(url) do
    case Req.get(url, receive_timeout: 30_000, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: bytes}} when is_binary(bytes) and bytes != "" ->
        {:ok, {bytes, OpenAICompatible.sniff(bytes) || "image/png"}}

      _ ->
        {:error, :invalid_image_input}
    end
  end

  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/webp"), do: "webp"
  defp extension("image/gif"), do: "gif"
  defp extension(_type), do: "png"
end
