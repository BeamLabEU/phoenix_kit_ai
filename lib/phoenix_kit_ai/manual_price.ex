defmodule PhoenixKitAI.ManualPrice do
  @moduledoc """
  A price entered by hand on an endpoint whose provider gives none (Z.ai,
  say): `provider_settings["pricing"]` — `%{"input" => µ$, "output" => µ$}`,
  whole micro-dollars per 1M input and output tokens (`$0.60` per 1M is
  `600_000`), either one optional.

  A call whose provider reports no `usage.cost` gets its `cost_cents` — in
  micro-dollars too — from it (`for_call/4`), and its usage row says
  `cost_source: "manual"`; a reported cost is always taken instead. Money
  limits and the daily budget then count the call like any other.
  """

  alias PhoenixKitAI.Endpoint

  @type t :: %{optional(String.t()) => non_neg_integer()}

  @doc "The endpoint's manual price, or nil when it has none."
  @spec get(Endpoint.t() | map() | nil) :: t() | nil
  def get(%{provider_settings: %{"pricing" => %{} = pricing}}) do
    pricing = Map.take(pricing, ["input", "output"])
    if pricing == %{}, do: nil, else: pricing
  end

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
  A call's `cost_cents` and what to add to its row's metadata: the
  provider's reported cost as it is, else the manual price's cost with
  `%{cost_source: "manual"}`, else nil.
  """
  @spec for_call(Endpoint.t() | map(), integer() | nil, integer() | nil, integer() | nil) ::
          {non_neg_integer() | nil, map()}
  def for_call(_endpoint, reported, _input_tokens, _output_tokens) when is_integer(reported),
    do: {reported, %{}}

  def for_call(endpoint, nil, input_tokens, output_tokens) do
    case cost(get(endpoint), input_tokens || 0, output_tokens || 0) do
      nil -> {nil, %{}}
      cost -> {cost, %{cost_source: "manual"}}
    end
  end

  @doc "Whether a usage row's cost was computed from a manual price."
  @spec manual_cost?(map()) :: boolean()
  def manual_cost?(%{metadata: %{"cost_source" => "manual"}}), do: true
  def manual_cost?(%{metadata: %{cost_source: "manual"}}), do: true
  def manual_cost?(_request), do: false

  @doc """
  Checks a stored price: a map of `"input"` / `"output"` to whole
  non-negative micro-dollars. `:ok` or `:error`.
  """
  @spec validate(term()) :: :ok | :error
  def validate(%{} = pricing) do
    if Enum.all?(pricing, fn {key, value} ->
         key in ["input", "output"] and is_integer(value) and value >= 0
       end),
       do: :ok,
       else: :error
  end

  def validate(_pricing), do: :error
end
