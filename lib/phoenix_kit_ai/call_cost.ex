defmodule PhoenixKitAI.CallCost do
  @moduledoc """
  What a call cost, in micro-dollars (millionths of a dollar — the unit of
  `Request.cost_cents`, which the module calls nanodollars), and where the
  figure came from. The first source that has a price wins:

    1. `"provider"` — the cost the provider reports in `usage.cost`
       (OpenRouter);
    2. `"catalogue"` — the price the operator's catalogue lists for the model
       (OpenRouter's `pricing`, through `PhoenixKitAI.Capabilities`);
    3. `"manual"` — the price entered on the endpoint
       (`PhoenixKitAI.ManualPrice`);
    4. `"table"` — Anthropic's built-in rates (`PhoenixKitAI.AnthropicPricing`,
       for an Anthropic endpoint), last, so a manual price corrects them.

  The model priced is the one the answer names; when no source prices it,
  the endpoint's model is tried — so an answer naming an unknown model is
  still counted when the endpoint's model has a price, and a money limit is
  not bypassed by it. The sum is in integers: tokens × micro-dollars per 1M,
  over a million, rounded.
  """

  alias PhoenixKitAI.{AnthropicPricing, Capabilities, Completion, Endpoint, ManualPrice}

  @sources ["catalogue", "manual", "table"]

  @type source :: String.t()

  @doc """
  A call's `cost_cents` and what its usage row's metadata gets: `reported`
  (the provider's cost, micro-dollars) with `cost_source: "provider"`, else
  the first priced source for `model` then for the endpoint's model, else
  `{nil, %{}}`.
  """
  @spec for_call(
          Endpoint.t() | map(),
          String.t() | nil,
          integer() | nil,
          integer() | nil,
          integer() | nil
        ) :: {non_neg_integer() | nil, map()}
  def for_call(_endpoint, _model, reported, _input_tokens, _output_tokens)
      when is_integer(reported),
      do: {reported, %{cost_source: "provider"}}

  def for_call(endpoint, model, nil, input_tokens, output_tokens) do
    input_tokens = input_tokens || 0
    output_tokens = output_tokens || 0

    [model, Map.get(endpoint, :model)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.find_value({nil, %{}}, &priced(endpoint, &1, input_tokens, output_tokens))
  end

  defp priced(endpoint, model, input_tokens, output_tokens) do
    Enum.find_value(@sources, fn source ->
      case ManualPrice.cost(
             price(source, endpoint, model, input_tokens),
             input_tokens,
             output_tokens
           ) do
        nil -> nil
        cost -> {cost, %{cost_source: source}}
      end
    end)
  end

  @doc """
  Whether some source prices calls on the endpoint's model: its provider
  reports what a call cost (OpenRouter), or a catalogue, a manual or the
  built-in price is there for it.
  """
  @spec reports_cost?(Endpoint.t() | map()) :: boolean()
  def reports_cost?(%{provider: provider, model: model} = endpoint) do
    (is_binary(provider) and Endpoint.base_provider(provider) == "openrouter") or
      Enum.any?(@sources, &(price(&1, endpoint, model, 0) != nil))
  end

  def reports_cost?(_endpoint), do: false

  @doc "Where a usage row's cost came from (`cost_source`), or nil."
  @spec source(map()) :: source() | nil
  def source(%{metadata: %{"cost_source" => source}}) when is_binary(source), do: source
  def source(%{metadata: %{cost_source: source}}) when is_binary(source), do: source
  def source(_request), do: nil

  # A source's price for the model, as whole micro-dollars per 1M tokens.
  defp price("catalogue", endpoint, model, _input_tokens) when is_binary(model) do
    case endpoint |> Capabilities.resolved_base_url() |> Capabilities.lookup(model) do
      %Capabilities{prompt_price: input, completion_price: output}
      when is_number(input) and is_number(output) ->
        %{"input" => round(input * 1.0e12), "output" => round(output * 1.0e12)}

      _ ->
        nil
    end
  end

  defp price("manual", endpoint, _model, _input_tokens), do: ManualPrice.get(endpoint)

  defp price("table", %{provider: provider} = endpoint, model, input_tokens)
       when is_binary(provider) do
    if Completion.anthropic?(endpoint),
      do: AnthropicPricing.micro_per_million(model, input_tokens)
  end

  defp price(_source, _endpoint, _model, _input_tokens), do: nil
end
