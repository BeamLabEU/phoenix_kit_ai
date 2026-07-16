defmodule PhoenixKitAI.TtsPricingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.TtsPricing

  describe "cost_nanodollars/3 — character-billed providers (exact)" do
    test "mistral: input_chars * $16/1M" do
      assert TtsPricing.cost_nanodollars("mistral", 1000, 999_999) == 16_000
    end

    test "xai: input_chars * $15/1M" do
      assert TtsPricing.cost_nanodollars("xai", 1000, 999_999) == 15_000
    end

    test "a named integration connection (xai:personal) still resolves via base_provider" do
      assert TtsPricing.cost_nanodollars("xai:personal", 1000, 999_999) ==
               TtsPricing.cost_nanodollars("xai", 1000, 999_999)
    end

    test "audio_bytes is ignored for character-billed providers" do
      assert TtsPricing.cost_nanodollars("mistral", 1000, 1) ==
               TtsPricing.cost_nanodollars("mistral", 1000, 999_999_999)
    end

    test "zero characters costs zero" do
      assert TtsPricing.cost_nanodollars("mistral", 0, 50_000) == 0
      assert TtsPricing.cost_nanodollars("xai", 0, 50_000) == 0
    end
  end

  describe "cost_nanodollars/3 — OpenAI (estimated from audio duration)" do
    test "one minute of audio at the assumed 128kbps costs ~$0.015" do
      one_minute_bytes = 128_000 * 60 / 8
      assert TtsPricing.cost_nanodollars("openai", 0, round(one_minute_bytes)) == 15_000
    end

    test "input_chars is ignored — the blended rate already covers both legs" do
      assert TtsPricing.cost_nanodollars("openai", 0, 100_000) ==
               TtsPricing.cost_nanodollars("openai", 10_000, 100_000)
    end

    test "zero-byte audio costs zero" do
      assert TtsPricing.cost_nanodollars("openai", 500, 0) == 0
    end
  end

  describe "cost_nanodollars/3 — unpriced providers" do
    test "a provider outside the rate table returns nil, not a crash" do
      assert TtsPricing.cost_nanodollars("openrouter", 1000, 50_000) == nil
    end

    test "an unrecognized provider string returns nil" do
      assert TtsPricing.cost_nanodollars("some-future-provider", 1000, 50_000) == nil
    end
  end
end
