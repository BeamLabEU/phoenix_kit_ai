defmodule PhoenixKitAI.TtsPricing do
  @moduledoc """
  Estimated per-request cost for a completed TTS request, in nanodollars
  (1/1,000,000 of a dollar — the same unit `Request.cost_cents` already uses for
  chat/embeddings, despite the field's legacy name).

  No TTS provider self-reports cost the way OpenRouter's chat completions do (there's
  no `usage` object at all in an `/audio/speech` or xAI `/tts` response) — so unlike
  `Completion.extract_usage/1`, this can't extract a real figure from the response. It
  has to come from a hand-maintained rate table instead.

  **Rates as of 2026-07-16 — verify against each provider's current pricing page
  before trusting for billing-critical use.** These will drift; this table needs
  periodic manual updates, same as any other hardcoded rate table. Sources:

  - Mistral (`voxtral-mini-tts-2603`): $16 / 1M characters — https://mistral.ai/pricing/api/
  - xAI (Grok TTS — one flat rate regardless of model, since xAI TTS has no
    per-model pricing tiers): $4.20 / 1M characters — https://docs.x.ai/developers/pricing
  - OpenAI (`gpt-4o-mini-tts`): $0.60 / 1M input text tokens + $12 / 1M audio output
    tokens — https://developers.openai.com/api/docs/models/gpt-4o-mini-tts

  Mistral and xAI bill per character, and `input_chars` is exact (`String.length/1`
  on the request text), so their cost is exact given the rate is current. OpenAI bills
  per token on both legs, but `/audio/speech` returns no token counts to read back —
  estimating a token count from characters (further split into an input-text leg and
  an audio-output leg) would compound two guesses, so this uses the commonly-cited
  blended rate (~$0.015/minute of generated audio) applied to a duration estimated
  from `audio_bytes` at the assumed bitrate instead — one estimate, not two. Treat it
  as approximate wherever it's displayed.
  """

  alias PhoenixKitAI.Endpoint

  # nanodollars/char = (dollars per 1M chars) since 1M chars * (rate/1M) dollars,
  # and nanodollars = dollars * 1_000_000 — the two 1,000,000s cancel.
  @per_char_nanodollars_by_provider %{
    "mistral" => 16,
    "xai" => 4.2
  }

  # Blended input+output estimate — see moduledoc. 1_000_000 nanodollars = $1, so
  # $0.015/min = 15_000 nanodollars/min.
  @openai_nanodollars_per_minute 15_000

  # This package's own TTS output is always MP3 (the only `response_format` any
  # caller currently requests) at 128kbps — used only to back out a duration
  # estimate from `audio_bytes` for the OpenAI leg above. Wrong for a caller
  # requesting a different format/bitrate; there's no exact source for duration
  # either, since /audio/speech returns none.
  @assumed_mp3_bitrate_bps 128_000

  @doc """
  Estimated cost in nanodollars for a completed TTS request, or `nil` if `provider`
  isn't in the rate table — same as no cost being available today, not a new failure
  mode. `input_chars` and `audio_bytes` are exactly what `PhoenixKitAI.speak/3` already
  records in the request's metadata.
  """
  @spec cost_nanodollars(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  def cost_nanodollars(provider, input_chars, audio_bytes)
      when is_binary(provider) and is_integer(input_chars) and is_integer(audio_bytes) do
    case Map.get(@per_char_nanodollars_by_provider, Endpoint.base_provider(provider)) do
      nil -> openai_cost_nanodollars(provider, audio_bytes)
      rate -> round(input_chars * rate)
    end
  end

  def cost_nanodollars(_provider, _input_chars, _audio_bytes), do: nil

  defp openai_cost_nanodollars(provider, audio_bytes) do
    if Endpoint.base_provider(provider) == "openai" do
      duration_minutes = audio_bytes * 8 / @assumed_mp3_bitrate_bps / 60
      round(duration_minutes * @openai_nanodollars_per_minute)
    end
  end
end
