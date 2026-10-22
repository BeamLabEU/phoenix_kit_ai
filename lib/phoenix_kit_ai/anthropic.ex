defmodule PhoenixKitAI.Anthropic do
  @moduledoc """
  What Anthropic's API needs beyond the OpenAI-compatible shape this module
  speaks. Chat goes through Anthropic's OpenAI SDK compatibility layer
  (`<base_url>/chat/completions`, `Authorization: Bearer`) like every other
  provider; three things differ:

    * `GET /v1/models` is Anthropic's native API: it refuses a request
      without `anthropic-version` (the header comes from the provider's
      `validation.extra_headers` in the core registry, see
      `PhoenixKitAI.Web.EndpointForm`).
    * Its model entries are Anthropic-shaped — `display_name`,
      `max_input_tokens`, `max_tokens`, `capabilities` — with no
      `supported_parameters`; `model_fields/1` maps them.
    * From Claude Opus 4.7 on, models refuse `temperature` and `top_p`
      (`400 "… is deprecated for this model"`); the earlier ones take either,
      but not both. The listing does not say so, so it is decided from the
      model id (`sampling?/1`), and `sampling_opts/2` drops what the model
      would refuse — an endpoint keeps its stored `temperature` (0.7 by
      default) whatever the model.
  """

  # The first model that refuses `temperature` / `top_p`.
  @no_sampling_since {4, 7}

  @doc "Whether the endpoint talks to Anthropic's API."
  @spec endpoint?(map()) :: boolean()
  def endpoint?(%{provider: "anthropic"}), do: true

  def endpoint?(%{base_url: url}) when is_binary(url),
    do: String.contains?(url, "api.anthropic.com")

  def endpoint?(_endpoint), do: false

  @doc "Whether a `/models` entry is Anthropic-shaped."
  @spec model?(map()) :: boolean()
  def model?(%{"type" => "model", "display_name" => name}) when is_binary(name), do: true
  def model?(_model), do: false

  @doc """
  The fields of an Anthropic `/models` entry the model card shows: name,
  context window, output limit and the generation parameters it takes.
  """
  @spec model_fields(map()) :: map()
  def model_fields(model) do
    %{
      "name" => model["display_name"],
      "context_length" => model["max_input_tokens"],
      "max_completion_tokens" => model["max_tokens"],
      "supported_parameters" => supported_parameters(model["id"])
    }
  end

  @doc """
  The generation parameters the model takes through the compatibility layer.
  """
  @spec supported_parameters(String.t() | nil) :: [String.t()]
  def supported_parameters(model_id) do
    base = ~w(max_tokens stop top_k)
    if sampling?(model_id), do: base ++ ~w(temperature top_p), else: base
  end

  @doc """
  Whether the model takes `temperature` / `top_p`: a model older than
  Claude Opus 4.7. An id this cannot read is taken for a newer model.
  """
  @spec sampling?(String.t() | nil) :: boolean()
  def sampling?(model_id) do
    case version(model_id) do
      nil -> false
      version -> version < @no_sampling_since
    end
  end

  # `claude-opus-4-5-20251101`, `claude-opus-5`, `claude-fable-5-1`, and the
  # older `claude-3-5-sonnet-20241022` naming.
  defp version(id) when is_binary(id) do
    id = id |> String.split("/") |> List.last()

    case Regex.run(~r/^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/, id) ||
           Regex.run(~r/^claude-(\d+)(?:-(\d{1,2}))?-[a-z]+/, id) do
      [_, major] -> {String.to_integer(major), 0}
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      nil -> nil
    end
  end

  defp version(_id), do: nil

  @doc """
  Request options without what the model would refuse: no `temperature`
  or `top_p` for a model that takes neither, and only `temperature` when
  both are set for one that takes either.
  """
  @spec sampling_opts(keyword(), String.t() | nil) :: keyword()
  def sampling_opts(opts, model_id) do
    cond do
      not sampling?(model_id) ->
        Keyword.drop(opts, [:temperature, :top_p])

      Keyword.get(opts, :temperature) != nil and Keyword.get(opts, :top_p) != nil ->
        Keyword.delete(opts, :top_p)

      true ->
        opts
    end
  end
end
