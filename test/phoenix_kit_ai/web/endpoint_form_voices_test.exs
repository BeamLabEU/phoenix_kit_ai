defmodule PhoenixKitAI.Web.EndpointFormVoicesTest do
  @moduledoc """
  Pure-function coverage for the TTS voice cascade helpers on
  `EndpointForm` (no DB / LiveView needed).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Web.EndpointForm

  defp voice(slug, name, language),
    do: %{slug: slug, name: name, language: language, gender: "male", tags: []}

  describe "voice_speakers/1" do
    test "groups the flat catalogue into speakers with their moods" do
      voices = [
        voice("en_paul_happy", "Paul - Happy", "en_us"),
        voice("en_paul_neutral", "Paul - Neutral", "en_us"),
        voice("gb_jane_sarcasm", "Jane - Sarcasm", "en_gb"),
        voice("fr_marie_neutral", "Marie - Neutral", "fr_fr")
      ]

      speakers = EndpointForm.voice_speakers(voices)

      # Sorted by label; speaker labels humanize the language.
      assert [
               %{key: "en_gb:Jane", label: "Jane — English (UK)"},
               %{key: "fr_fr:Marie", label: "Marie — French"},
               %{key: "en_us:Paul", label: "Paul — English (US)"}
             ] = speakers

      paul = Enum.find(speakers, &(&1.key == "en_us:Paul"))
      # Moods sorted; each carries its full slug.
      assert [
               %{mood: "Happy", slug: "en_paul_happy"},
               %{mood: "Neutral", slug: "en_paul_neutral"}
             ] =
               paul.voices
    end

    test "a name without a mood suffix falls back to the name as both" do
      assert [%{speaker: "Solo", voices: [%{mood: "Solo", slug: "solo"}]}] =
               EndpointForm.voice_speakers([voice("solo", "Solo", "en_us")])
    end
  end

  describe "speaker_for_voice/2" do
    test "finds the speaker key that owns a slug" do
      speakers =
        EndpointForm.voice_speakers([
          voice("en_paul_happy", "Paul - Happy", "en_us"),
          voice("gb_jane_sarcasm", "Jane - Sarcasm", "en_gb")
        ])

      assert EndpointForm.speaker_for_voice(speakers, "gb_jane_sarcasm") == "en_gb:Jane"
      assert EndpointForm.speaker_for_voice(speakers, "unknown") == nil
      assert EndpointForm.speaker_for_voice(speakers, "") == nil
      assert EndpointForm.speaker_for_voice(speakers, nil) == nil
    end
  end

  describe "humanize_language/1" do
    test "maps known codes, passes through unknown, nil-safe" do
      assert EndpointForm.humanize_language("en_us") == "English (US)"
      assert EndpointForm.humanize_language("fr_fr") == "French"
      assert EndpointForm.humanize_language("zz_zz") == "zz_zz"
      assert EndpointForm.humanize_language(nil) == nil
    end
  end
end
