defmodule PhoenixKitAI.ManualPrice do
  @moduledoc """
  A price entered by hand on an endpoint whose provider gives none (Z.ai,
  say): `provider_settings["pricing"]` — `%{"model" => id, "input" => µ$,
  "output" => µ$}`, whole micro-dollars per 1M input and output tokens
  (`$0.60` per 1M is `600_000`), both required, for the model it names. The
  endpoint's changeset stamps the model when none is given and drops the
  price when the endpoint's model changes (like a capability declaration).

  A call whose provider reports no `usage.cost` and whose model no catalogue
  prices gets its `cost_cents` — in micro-dollars too — from it, and its
  usage row says `cost_source: "manual"` (`PhoenixKitAI.CallCost` keeps the
  order of the sources). Money limits and the daily budget then count the
  call like any other.
  """

  alias PhoenixKitAI.Endpoint

  @type t :: %{optional(String.t()) => non_neg_integer()}

  # The highest price per 1M tokens a person may enter: $10 000.
  @max 10_000_000_000

  @doc "The highest price per 1M tokens, in micro-dollars ($10 000)."
  def max, do: @max

  @doc """
  The endpoint's manual price for its own model, `%{"input" => µ$, "output" =>
  µ$}`, or nil — when it has none, or the stored price names another model
  or lacks a half.
  """
  @spec get(Endpoint.t() | map() | nil) :: t() | nil
  def get(%{
        model: model,
        provider_settings: %{
          "pricing" => %{"model" => model, "input" => input, "output" => output}
        }
      })
      when is_integer(input) and is_integer(output),
      do: %{"input" => input, "output" => output}

  def get(_endpoint), do: nil

  @doc """
  The cost of a call in micro-dollars: `input_tokens × input + output_tokens
  × output`, over a million, rounded — in integers. nil when a price the
  tokens need is missing (no price at all, or an output price for a call
  with output).
  """
  @spec cost(t() | nil, non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def cost(nil, _input_tokens, _output_tokens), do: nil

  def cost(pricing, input_tokens, output_tokens) do
    with {:ok, input} <- part(pricing["input"], input_tokens),
         {:ok, output} <- part(pricing["output"], output_tokens) do
      div(input + output + 500_000, 1_000_000)
    else
      :missing -> nil
    end
  end

  defp part(_price, 0), do: {:ok, 0}

  defp part(price, tokens) when is_integer(price) and is_integer(tokens),
    do: {:ok, price * tokens}

  defp part(_price, _tokens), do: :missing

  @doc """
  Checks a stored price: `"input"` and `"output"` both, whole micro-dollars
  from 0 to `max/0`, and an optional `"model"` (the model it prices). `:ok`
  or `:error`.
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

  defp amount?(value), do: is_integer(value) and value >= 0 and value <= @max
end
