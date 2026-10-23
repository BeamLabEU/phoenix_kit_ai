defmodule PhoenixKitAI.ManualPrice do
  @moduledoc """
  A price entered by hand on an endpoint whose provider gives none (Z.ai,
  say): `provider_settings["pricing"]` — `%{"model" => id, "input" => "0.60",
  "output" => "2.2"}`, US dollars per 1M input and output tokens as decimal
  strings (a JSON number would read back as a float), both required, for the
  model it names. The
  endpoint's changeset stamps the model when none is given and drops the
  price when the endpoint's model changes (like a capability declaration).

  A call whose provider reports no `usage.cost` and whose model no catalogue
  prices gets its `cost` from it (`cost/3`), and its
  usage row says `cost_source: "manual"` (`PhoenixKitAI.CallCost` keeps the
  order of the sources). Money limits and the daily budget then count the
  call like any other. That is chat, embeddings and the vision verbs
  (`describe_image/3`, `extract_text/3`, `compare_images/4`), for a call
  sent to the price's model. Making or editing images (`generate_image/3`,
  `edit_image/4`, `process_image/4`) is priced per image or per call, not
  per token, so a manual price does not apply there: those calls keep only
  the provider's own cost.

  A price whose halves are integers is in the shape the released versions
  stored (millionths of a dollar); `legacy?/1` says so, the module's migration
  chain converts it, and a call on such an endpoint is refused until it has.
  """

  alias PhoenixKitAI.{Endpoint, Money}

  @type t :: %{optional(String.t()) => Decimal.t()}

  # The highest price per 1M tokens a person may enter.
  @max Decimal.new(10_000)

  @doc "The highest price per 1M tokens, in dollars ($10 000)."
  @spec max() :: Decimal.t()
  def max, do: @max

  @doc """
  The endpoint's manual price for its own model, `%{"input" => dollars,
  "output" => dollars}` per 1M tokens as `Decimal`s, or nil — when it has none,
  the stored price names another model, lacks a half, or is in the legacy shape
  (`legacy?/1`).
  """
  @spec get(Endpoint.t() | map() | nil) :: t() | nil
  def get(%{
        model: model,
        provider_settings: %{
          "pricing" => %{"model" => model, "input" => input, "output" => output}
        }
      })
      when is_binary(input) and is_binary(output) do
    with {:ok, input} <- Money.to_decimal(input),
         {:ok, output} <- Money.to_decimal(output) do
      %{"input" => input, "output" => output}
    else
      _ -> nil
    end
  end

  def get(_endpoint), do: nil

  @doc """
  Whether the endpoint's stored price is in the released versions' shape:
  integer millionths of a dollar per 1M tokens.
  """
  @spec legacy?(Endpoint.t() | map() | nil) :: boolean()
  def legacy?(%{provider_settings: %{"pricing" => %{} = pricing}}),
    do: is_integer(pricing["input"]) or is_integer(pricing["output"])

  def legacy?(_endpoint), do: false

  @doc """
  What a call costs at a price per 1M tokens, in dollars, not rounded:
  `(input_tokens × input + output_tokens × output) / 1_000_000`. nil when a
  price the tokens need is missing (no price at all, or an output price for a
  call with output).
  """
  @spec cost(t() | nil, non_neg_integer(), non_neg_integer()) :: Decimal.t() | nil
  def cost(nil, _input_tokens, _output_tokens), do: nil

  def cost(pricing, input_tokens, output_tokens) do
    with {:ok, input} <- part(pricing["input"], input_tokens),
         {:ok, output} <- part(pricing["output"], output_tokens) do
      input |> Decimal.add(output) |> Decimal.div(1_000_000)
    else
      :missing -> nil
    end
  end

  defp part(_price, 0), do: {:ok, Decimal.new(0)}

  defp part(%Decimal{} = price, tokens) when is_integer(tokens),
    do: {:ok, Decimal.mult(price, tokens)}

  defp part(_price, _tokens), do: :missing

  @doc """
  Checks a stored price: `"input"` and `"output"` both, dollar strings from 0
  to `max/0`, and an optional `"model"` (the model it prices). `:ok` or
  `:error`.
  """
  @spec validate(term()) :: :ok | :error
  def validate(%{"input" => input, "output" => output} = pricing) do
    allowed? = Enum.all?(Map.keys(pricing), &(&1 in ["model", "input", "output"]))

    model? =
      not Map.has_key?(pricing, "model") or
        (is_binary(pricing["model"]) and pricing["model"] != "")

    if allowed? and model? and amount?(input) and amount?(output), do: :ok, else: :error
  end

  def validate(_pricing), do: :error

  defp amount?(value) when is_binary(value) do
    case Money.to_decimal(value) do
      {:ok, decimal} -> not Decimal.negative?(decimal) and not Decimal.gt?(decimal, @max)
      :error -> false
    end
  end

  defp amount?(_value), do: false
end
