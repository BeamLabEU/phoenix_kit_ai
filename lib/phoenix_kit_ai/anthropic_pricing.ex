defmodule PhoenixKitAI.AnthropicPricing do
  @moduledoc """
  What a chat call to Anthropic cost, from its token counts and a rate table.

  Anthropic's OpenAI-compatible layer returns `prompt_tokens` and
  `completion_tokens` but no cost (OpenRouter puts `usage.cost` in its
  answer), and its `GET /v1/models` lists no prices. So the cost comes from
  the per-model rates of Anthropic's pricing page, in US dollars per million
  tokens. Thinking is billed as output and is already in `completion_tokens`.
  That layer does no prompt caching, so the cache rates do not apply.

  **Rates as of 2026-10-22, from
  https://platform.claude.com/docs/en/about-claude/pricing — they drift.**
  A host can add or correct rates without a release:

      config :phoenix_kit_ai, :anthropic_prices, %{
        "claude-sonnet-5-5" => {2.0, 10.0}
      }

  A model is looked up by its id without a trailing date
  (`claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`). A model that is in
  neither table has no price: its calls are logged without a cost, as before.

  The table is the last source of a call's cost (`PhoenixKitAI.CallCost`):
  after the provider's own cost, a catalogue price and the endpoint's manual
  price — so a manual price corrects a stale rate. It is never shown as a
  catalogue price. Ported from BeamLabEU/phoenix_kit_ai#47 (8e8c65e).
  Not covered: US-only inference (`inference_geo`, ×1.1), which this module
  never asks for, and the Batch API.
  """

  # {input, output} in US dollars per million tokens.
  @rates %{
    "claude-fable-5-1" => {10.0, 50.0},
    "claude-mythos-5-1" => {10.0, 50.0},
    "claude-fable-5" => {10.0, 50.0},
    "claude-mythos-5" => {10.0, 50.0},
    "claude-opus-5-5" => {4.0, 20.0},
    "claude-opus-5" => {5.0, 25.0},
    "claude-opus-4-8" => {5.0, 25.0},
    "claude-opus-4-7" => {5.0, 25.0},
    "claude-opus-4-6" => {5.0, 25.0},
    "claude-opus-4-5" => {5.0, 25.0},
    "claude-opus-4-1" => {15.0, 75.0},
    "claude-opus-4" => {15.0, 75.0},
    "claude-sonnet-5-5" => {2.0, 10.0},
    "claude-sonnet-5" => {2.0, 10.0},
    "claude-sonnet-4-6" => {3.0, 15.0},
    "claude-sonnet-4-5" => {3.0, 15.0},
    "claude-sonnet-4" => {3.0, 15.0},
    "claude-haiku-5-5" => {0.10, 0.50},
    "claude-haiku-4-5" => {1.0, 5.0},
    "claude-3-5-haiku" => {0.80, 4.0}
  }

  # Claude Haiku 5.5 is priced by the size of the prompt: past 100,000 input
  # tokens the whole call is billed at the higher rate.
  @tiers %{"claude-haiku-5-5" => {100_000, {0.50, 2.50}}}

  @doc """
  The rate of a model as `{input, output}` US dollars per token, or `nil` when
  the model has no price here — the shape `AIModel.pricing` and the
  capability cache keep. A tiered model gives its base rate.
  """
  @spec per_token(String.t() | nil) :: {float(), float()} | nil
  def per_token(model) do
    case rate(model) do
      {input, output} -> {input / 1_000_000, output / 1_000_000}
      nil -> nil
    end
  end

  @doc """
  The cost of a call in US dollars, or `nil` when the model has no price
  here or the token counts are not numbers.
  """
  @spec cost(String.t() | nil, term(), term()) :: float() | nil
  def cost(model, prompt_tokens, completion_tokens)
      when is_integer(prompt_tokens) and prompt_tokens >= 0 and
             is_integer(completion_tokens) and completion_tokens >= 0 do
    case rate(model, prompt_tokens) do
      {input, output} -> (prompt_tokens * input + completion_tokens * output) / 1_000_000
      nil -> nil
    end
  end

  def cost(_model, _prompt_tokens, _completion_tokens), do: nil

  @doc """
  The rate for a call of `prompt_tokens` input tokens in US dollars per 1M
  tokens (`%{"input" => Decimal, "output" => Decimal}`, the shape of a manual
  price), or `nil` when the model has no price here.
  """
  @spec per_million(String.t() | nil, non_neg_integer()) ::
          %{String.t() => Decimal.t()} | nil
  def per_million(model, prompt_tokens) do
    with {input, output} <- rate(model, prompt_tokens),
         {:ok, input} <- PhoenixKitAI.Money.to_decimal(input),
         {:ok, output} <- PhoenixKitAI.Money.to_decimal(output) do
      %{"input" => input, "output" => output}
    else
      _ -> nil
    end
  end

  defp rate(model, prompt_tokens \\ 0)

  defp rate(model, prompt_tokens) when is_binary(model) do
    id = Regex.replace(~r/-(\d{8}|latest)$/, model, "")

    case Map.get(rates(), id) do
      nil -> nil
      base -> tier(id, prompt_tokens) || base
    end
  end

  defp rate(_model, _prompt_tokens), do: nil

  defp tier(id, prompt_tokens) do
    case Map.get(@tiers, id) do
      {threshold, rate} when prompt_tokens > threshold -> rate
      _ -> nil
    end
  end

  # A configured rate wins over the table; a malformed one is left out, and so
  # is a setting that is neither a map nor a list (a call is never failed by it).
  defp rates do
    configured =
      :phoenix_kit_ai
      |> Application.get_env(:anthropic_prices, %{})
      |> configured_prices()
      |> Enum.filter(fn
        {id, {input, output}} ->
          is_binary(id) and is_number(input) and input >= 0 and is_number(output) and output >= 0

        _ ->
          false
      end)
      |> Map.new(fn {id, {input, output}} -> {id, {input * 1.0, output * 1.0}} end)

    Map.merge(@rates, configured)
  end

  defp configured_prices(prices) when is_map(prices) or is_list(prices), do: prices
  defp configured_prices(_prices), do: []
end
