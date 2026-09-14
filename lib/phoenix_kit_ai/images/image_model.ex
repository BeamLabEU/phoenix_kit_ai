defmodule PhoenixKitAI.Images.ImageModel do
  @moduledoc """
  What one image model accepts, in provider-neutral terms.

  Built from a provider's capability listing (OpenRouter publishes one at
  `/images/models`; other providers get a static list from their adapter)
  and used by `PhoenixKitAI.Images` to keep a request inside what the
  model can do: an option the model does not list is dropped with a
  warning, or refused when the caller asked for `strict: true`.

  `params` maps an option name to its constraint:

    * `{:enum, values}` — one of `values` (strings)
    * `{:range, min, max}` — an integer within the range
    * `:boolean` — accepted, any value
    * `:any` — accepted, unconstrained

  The option names are the ones `PhoenixKitAI.Images` uses everywhere:
  `:aspect_ratio`, `:resolution`, `:size`, `:quality`, `:background`,
  `:output_format`, `:output_compression`, `:n`, `:seed`,
  `:input_references`.
  """

  @enforce_keys [:id]
  defstruct id: nil,
            name: nil,
            provider: nil,
            description: nil,
            params: %{},
            pricing: %{},
            raw: %{}

  @type constraint ::
          {:enum, [String.t()]} | {:range, integer(), integer()} | :boolean | :any

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          provider: String.t() | nil,
          description: String.t() | nil,
          params: %{optional(atom()) => constraint()},
          pricing: map(),
          raw: map()
        }

  @doc "Whether the model lists `option` at all."
  @spec supports?(t() | nil, atom()) :: boolean()
  def supports?(%__MODULE__{params: params}, option) when is_atom(option),
    do: Map.has_key?(params, option)

  def supports?(_model, _option), do: false

  @doc """
  Whether `value` is acceptable for `option` on this model. Unknown
  options are not; values are compared as strings for enums.
  """
  @spec allows?(t() | nil, atom(), term()) :: boolean()
  def allows?(%__MODULE__{params: params}, option, value) when is_atom(option) do
    case Map.fetch(params, option) do
      {:ok, {:enum, values}} -> to_string(value) in values
      {:ok, {:range, min, max}} -> is_integer(value) and value >= min and value <= max
      {:ok, :boolean} -> true
      {:ok, :any} -> true
      :error -> false
    end
  end

  def allows?(_model, _option, _value), do: false

  @doc "The values an enum option accepts, or `[]`."
  @spec values(t() | nil, atom()) :: [String.t()]
  def values(%__MODULE__{params: params}, option) when is_atom(option) do
    case Map.get(params, option) do
      {:enum, values} -> values
      _ -> []
    end
  end

  def values(_model, _option), do: []

  @doc "How many reference images the model takes for an edit (nil = unknown)."
  @spec max_references(t() | nil) :: non_neg_integer() | nil
  def max_references(%__MODULE__{params: %{input_references: {:range, _min, max}}}), do: max
  def max_references(_model), do: nil

  @doc """
  Builds a model from one entry of OpenRouter's `/api/v1/images/models`
  listing. `supported_parameters` there is typed per field
  (`%{"type" => "enum", "values" => [...]}` /
  `%{"type" => "range", "min" => m, "max" => n}` /
  `%{"type" => "boolean"}`).
  """
  @spec from_openrouter(map()) :: t()
  def from_openrouter(%{"id" => id} = entry) do
    params =
      entry
      |> Map.get("supported_parameters", %{})
      |> Enum.reduce(%{}, fn {key, spec}, acc ->
        case {option_key(key), constraint(spec)} do
          {nil, _} -> acc
          {_, nil} -> acc
          {option, constraint} -> Map.put(acc, option, constraint)
        end
      end)

    %__MODULE__{
      id: id,
      name: entry["name"],
      provider: id |> String.split("/", parts: 2) |> List.first(),
      description: entry["description"],
      params: params,
      pricing: pricing(entry),
      raw: entry
    }
  end

  @known_options ~w(aspect_ratio resolution size quality background output_format output_compression n seed input_references)

  defp option_key(key) when key in @known_options, do: String.to_atom(key)
  defp option_key(_key), do: nil

  defp constraint(%{"type" => "enum", "values" => values}) when is_list(values),
    do: {:enum, Enum.map(values, &to_string/1)}

  defp constraint(%{"type" => "range", "min" => min, "max" => max})
       when is_integer(min) and is_integer(max),
       do: {:range, min, max}

  defp constraint(%{"type" => "boolean"}), do: :boolean
  defp constraint(%{"type" => _other}), do: :any
  defp constraint(_spec), do: nil

  # Per-endpoint pricing when OpenRouter includes it; kept as given.
  defp pricing(%{"endpoints" => [%{"pricing" => pricing} | _]}) when is_map(pricing), do: pricing
  defp pricing(%{"pricing" => pricing}) when is_map(pricing), do: pricing
  defp pricing(_entry), do: %{}
end
