defmodule PhoenixKitAI.TtsPricingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.TtsPricing

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  describe "cost/3 — character-billed providers (exact)" do
    test "mistral: input_chars * $16/1M" do
      assert dollars?(TtsPricing.cost("mistral", 1000, 999_999), "0.016")
    end

    test "xai: input_chars * $15/1M" do
      assert dollars?(TtsPricing.cost("xai", 1000, 999_999), "0.015")
    end

    test "one character is not $0" do
      assert dollars?(TtsPricing.cost("xai", 1, 0), "0.000015")
    end

    test "a named integration connection (xai:personal) still resolves via base_provider" do
      assert dollars?(TtsPricing.cost("xai:personal", 1000, 999_999), "0.015")
    end

    test "audio_bytes is ignored for character-billed providers" do
      assert Decimal.equal?(
               TtsPricing.cost("mistral", 1000, 1),
               TtsPricing.cost("mistral", 1000, 999_999_999)
             )
    end

    test "zero characters costs zero" do
      assert dollars?(TtsPricing.cost("mistral", 0, 50_000), "0")
      assert dollars?(TtsPricing.cost("xai", 0, 50_000), "0")
    end
  end

  describe "cost/3 — OpenAI (estimated from audio duration)" do
    test "one minute of audio at the assumed 128kbps costs $0.015" do
      one_minute_bytes = div(128_000 * 60, 8)
      assert dollars?(TtsPricing.cost("openai", 0, one_minute_bytes), "0.015")
    end

    test "rounded once to the column's 10 places" do
      # 1 byte = 8 / 128 000 / 60 minutes × $0.015 = $0.000000015625 → 10 places
      assert dollars?(TtsPricing.cost("openai", 0, 1), "0.0000000156")
    end

    test "input_chars is ignored — the blended rate already covers both legs" do
      assert Decimal.equal?(
               TtsPricing.cost("openai", 0, 100_000),
               TtsPricing.cost("openai", 10_000, 100_000)
             )
    end

    test "zero-byte audio costs zero" do
      assert dollars?(TtsPricing.cost("openai", 500, 0), "0")
    end
  end

  describe "cost/3 — unpriced providers" do
    test "a provider outside the rate table returns nil, not a crash" do
      assert TtsPricing.cost("openrouter", 1000, 50_000) == nil
    end

    test "an unrecognized provider string returns nil" do
      assert TtsPricing.cost("some-future-provider", 1000, 50_000) == nil
    end
  end
end
