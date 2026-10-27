defmodule PhoenixKitAI.AnthropicPricingTest do
  use ExUnit.Case, async: false

  alias PhoenixKitAI.AnthropicPricing

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :anthropic_prices) end)
  end

  test "a call costs its input and output tokens at the model's rate" do
    # Claude Opus 4.6: $5 and $25 per million tokens.
    assert_in_delta AnthropicPricing.cost("claude-opus-4-6", 2_000, 1_000), 0.035, 1.0e-12
    assert AnthropicPricing.cost("claude-opus-4-6", 0, 0) == 0.0
  end

  test "a dated id is priced as its model" do
    assert AnthropicPricing.cost("claude-sonnet-4-5-20250929", 1_000_000, 0) == 3.0
    assert AnthropicPricing.per_token("claude-haiku-4-5-20251001") == {1.0e-6, 5.0e-6}
  end

  test "Claude Haiku 5.5 past 100,000 input tokens is billed at the higher rate" do
    assert_in_delta AnthropicPricing.cost("claude-haiku-5-5", 100_000, 0), 0.01, 1.0e-12
    assert_in_delta AnthropicPricing.cost("claude-haiku-5-5", 100_001, 1_000), 0.0525005, 1.0e-12
  end

  test "an unknown model or tokens that are not counts have no price" do
    assert AnthropicPricing.cost("claude-unknown-9", 10, 10) == nil
    assert AnthropicPricing.per_token("claude-unknown-9") == nil
    assert AnthropicPricing.per_token(nil) == nil
    assert AnthropicPricing.cost("claude-opus-4-6", nil, 10) == nil
    assert AnthropicPricing.cost("claude-opus-4-6", -1, 10) == nil
  end

  test "a configured rate adds a model and wins over the table; a malformed one is left out" do
    Application.put_env(:phoenix_kit_ai, :anthropic_prices, %{
      "claude-new-1" => {1, 2},
      "claude-opus-4-6" => {6.0, 30.0},
      "claude-sonnet-4-6" => {-1, 2},
      "claude-haiku-4-5" => :free
    })

    assert AnthropicPricing.cost("claude-new-1", 1_000_000, 1_000_000) == 3.0
    assert AnthropicPricing.cost("claude-opus-4-6", 1_000_000, 0) == 6.0
    assert AnthropicPricing.cost("claude-sonnet-4-6", 1_000_000, 0) == 3.0
    assert AnthropicPricing.cost("claude-haiku-4-5", 1_000_000, 0) == 1.0
  end

  test "a configured rate also replaces a built-in tier for large prompts" do
    Application.put_env(:phoenix_kit_ai, :anthropic_prices, %{
      "claude-haiku-5-5" => {2, 8}
    })

    for tokens <- [100_000, 100_001, 1_000_000] do
      assert_in_delta AnthropicPricing.cost("claude-haiku-5-5", tokens, 1_000),
                      (tokens * 2 + 1_000 * 8) / 1_000_000,
                      1.0e-12

      assert %{"input" => input, "output" => output} =
               AnthropicPricing.per_million("claude-haiku-5-5-latest", tokens)

      assert Decimal.equal?(input, 2)
      assert Decimal.equal?(output, 8)
    end
  end

  test "a setting that is neither a map nor a list is ignored, not raised on" do
    for setting <- [nil, "claude-opus-4-6", 5] do
      Application.put_env(:phoenix_kit_ai, :anthropic_prices, setting)
      assert AnthropicPricing.cost("claude-opus-4-6", 1_000_000, 0) == 5.0
    end

    Application.put_env(:phoenix_kit_ai, :anthropic_prices, [{"claude-new-1", {1, 2}}])
    assert AnthropicPricing.cost("claude-new-1", 1_000_000, 1_000_000) == 3.0
  end

  test "the rate in dollars per 1M tokens, by the call's size" do
    assert %{"input" => input, "output" => output} =
             AnthropicPricing.per_million("claude-sonnet-5-5-20261001", 0)

    assert Decimal.equal?(input, 2) and Decimal.equal?(output, 10)

    assert %{"input" => input, "output" => output} =
             AnthropicPricing.per_million("claude-haiku-5-5", 100_001)

    assert Decimal.equal?(input, Decimal.new("0.5")) and
             Decimal.equal?(output, Decimal.new("2.5"))

    assert AnthropicPricing.per_million("claude-unknown-9", 0) == nil
  end
end
