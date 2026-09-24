defmodule PhoenixKitAI.TranslationMarkdownSectionsTest do
  @moduledoc """
  A response is either parsed into exactly the requested fields with their
  full content, or it is an error — never a silently shortened or polluted
  value.

  The fixtures under `test/fixtures/translation_responses/` are verbatim
  model answers (deepseek/deepseek-chat via OpenRouter, 2026-09-24 and
  2026-09-07) to a catalogue prompt asking for `name` + `description`
  (or, for the set prompt, `title` alone):

    * `heading_underscore_markers.de-DE.txt` — every `## Section` heading of
      the description came back as its own `---SECTION_NAME---` marker.
      The parser used to stop `description` at the first of them and return
      `{:ok, _}` with 135 of 1325 source characters.
    * `heading_spaced_markers.de-DE.txt` — the headings came back as
      `---SIZE AND USABLE SPACE---`. Spaces are not in the boundary
      pattern, so those lines stayed inside the returned description and
      would have rendered on the storefront.
    * `headings_kept.fr-FR.txt` — the same kind of source translated
      correctly: headings stayed `##`/`###` inside the description. The
      control that proves the guard does not reject Markdown.
    * `placeholder_commentary.de-DE.txt` — the prompt left `{{label}}`
      unbound; the model skipped it and then explained so in a trailing
      note, which used to be appended to `title`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitAI.Translation

  @fixtures Path.expand("../fixtures/translation_responses", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "captured responses" do
    test "headings turned into underscore markers are an error, not a truncated description" do
      response = fixture("heading_underscore_markers.de-DE.txt")

      assert {:error, {:parse_error, {:unexpected_markers, markers}}} =
               Translation.parse_response(response, ["name", "description"])

      assert markers == [
               "MINIATURE_DETAILS",
               "DIMENSIONS",
               "WHAT_IS_INCLUDED",
               "IMPORTANT_INFORMATION",
               "3D_PRINTED_FINISH",
               "PRODUCTION_AND_DELIVERY",
               "FAQ"
             ]
    end

    test "headings turned into spaced markers are an error, not marker lines left in the description" do
      response = fixture("heading_spaced_markers.de-DE.txt")

      assert {:error, {:parse_error, {:unexpected_markers, markers}}} =
               Translation.parse_response(response, ["name", "description"])

      assert markers == [
               "SIZE AND USABLE SPACE",
               "CHOOSE THE COLOR",
               "INSTALLATION AND CARE",
               "3D PRINTED FINISH",
               "WHAT IS INCLUDED",
               "PRODUCTION AND DELIVERY"
             ]
    end

    test "headings kept inside the field parse as the whole field" do
      response = fixture("headings_kept.fr-FR.txt")

      assert {:ok, %{"name" => name, "description" => description}} =
               Translation.parse_response(response, ["name", "description"])

      assert name =~ "Chariot de bibliothèque"
      assert description =~ ~r/^## Détails de la miniature$/m
      assert description =~ ~r/^### Les roues roulent-elles \?$/m
      assert description =~ "Il est conçu pour les environnements de maison de poupée"
      refute description =~ ~r/^---/m
    end

    test "a trailing note quoting an unbound placeholder is an error, not part of the value" do
      response = fixture("placeholder_commentary.de-DE.txt")

      assert {:error, {:parse_error, {:placeholder_echo, ["title"]}}} =
               Translation.handle_ai_response(response, %{"title" => "Yellow"})
    end
  end

  describe "marker lines" do
    test "a requested marker emitted twice is an error, not the first half of the field" do
      # A description with a `## Description` heading is the easy way to get
      # here: the heading comes back as a second `---DESCRIPTION---`.
      response = """
      ---NAME---
      Vase
      ---DESCRIPTION---
      Eine Vase.
      ---DESCRIPTION---
      Pflege: feucht abwischen.
      """

      assert {:error, {:parse_error, {:unexpected_markers, ["DESCRIPTION"]}}} =
               Translation.parse_response(response, ["name", "description"])
    end

    test "a marker-shaped line in any case or script is caught" do
      for line <- [
            "---Größe und Farbe---",
            "---größe_und_farbe---",
            "--- SIZE ---",
            "----SIZE----"
          ] do
        response = "---NAME---\nVase\n---DESCRIPTION---\nEine Vase.\n\n#{line}\n12 Zoll."

        assert {:error, {:parse_error, {:unexpected_markers, [_]}}} =
                 Translation.parse_response(response, ["name", "description"]),
               "not caught: #{line}"
      end
    end

    test "a marker opening a line with text after it is caught" do
      # `extract_section/2` stops a capture at such a line, so it cut the
      # description short exactly like a marker on a line of its own.
      response = "---NAME---\nVase\n---DESCRIPTION---\nEine Vase.\n---DETAILS--- Drei Regale."

      assert {:error, {:parse_error, {:unexpected_markers, ["DETAILS"]}}} =
               Translation.parse_response(response, ["name", "description"])
    end

    test "a requested marker with its value on the same line still parses" do
      assert {:ok, %{"name" => "Vase", "description" => "Eine Vase."}} =
               Translation.parse_response("---NAME--- Vase\n---DESCRIPTION---\nEine Vase.", [
                 "name",
                 "description"
               ])
    end

    test "Markdown rules, tables, decorative rules and mid-line dashes inside a value are content" do
      response = """
      ---NAME---
      Vase
      ---DESCRIPTION---
      ## Größe

      ---

      | Größe | Höhe |
      |---|---|
      | S | 12 cm |

      --- * ---

      Der Text enthält ---KEIN--- Marker mitten im Satz.
      """

      assert {:ok, %{"description" => description}} =
               Translation.parse_response(response, ["name", "description"])

      assert description =~ "| S | 12 cm |"
      assert description =~ "--- * ---"
      assert description =~ "---KEIN---"
    end

    test "an unrequested section holding only an unbound slot is still dropped" do
      # Same case as the older "unrequested markers don't leak" test: the
      # model echoed a slot the caller never bound. No requested field is
      # affected, so this stays a success.
      response = "---NAME---\nVase\n---SUMMARY---\n{{summary}}\n---DESCRIPTION---\nEine Vase."

      assert {:ok, %{"name" => "Vase", "description" => "Eine Vase."}} =
               Translation.parse_response(response, ["name", "description"])
    end

    test "an unrequested section with real content is an error even when it is last" do
      response = "---NAME---\nVase\n---DESCRIPTION---\nEine Vase.\n---SUMMARY---\nKurz."

      assert {:error, {:parse_error, {:unexpected_markers, ["SUMMARY"]}}} =
               Translation.parse_response(response, ["name", "description"])
    end
  end

  describe "marker-shaped lines the source carries" do
    @source %{"body" => "Hi Anna,\n\n----- Original Message -----\nFrom: Bob"}

    test "come back translated and parse as content" do
      response = "---BODY---\nHallo Anna,\n\n----- Ursprüngliche Nachricht -----\nVon: Bob"

      assert {:ok, %{"body" => body}} = Translation.handle_ai_response(response, @source)
      assert body =~ "----- Ursprüngliche Nachricht -----"
    end

    test "allow no more of them than the source has" do
      response =
        "---BODY---\nHallo Anna,\n\n--- GRUSS ---\n\n----- Ursprüngliche Nachricht -----\nVon: Bob"

      assert {:error, {:parse_error, {:unexpected_markers, ["Ursprüngliche Nachricht"]}}} =
               Translation.handle_ai_response(response, @source)
    end

    test "never cover a line the parser would cut the field at" do
      # `---NOTE---` stops `extract_section/2` whatever its origin, so the
      # value before it would be a fraction of the field.
      source = %{"body" => "Text\n---NOTE---\nmore"}
      response = "---BODY---\nText\n---NOTE---\nmehr"

      assert {:error, {:parse_error, {:unexpected_markers, ["NOTE"]}}} =
               Translation.handle_ai_response(response, source)
    end

    test "can be passed to parse_response/3 as a list" do
      assert {:ok, %{"body" => "Text\n--- ODER ---\nmehr"}} =
               Translation.parse_response("---BODY---\nText\n--- ODER ---\nmehr", ["body"],
                 sources: ["Text\n--- OR ---\nmore"]
               )
    end
  end

  describe "placeholder echo" do
    test "a placeholder the source itself contains is content, not an echo" do
      response = "---BODY---\nVerwenden Sie {{name}} im Betreff."

      assert {:ok, %{"body" => "Verwenden Sie {{name}} im Betreff."}} =
               Translation.handle_ai_response(response, %{
                 "body" => "Use {{name}} in the subject."
               })
    end

    test "is checked on the OpenAI-shaped response too" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => fixture("placeholder_commentary.de-DE.txt")}}
        ]
      }

      assert {:error, {:parse_error, {:placeholder_echo, ["title"]}}} =
               Translation.handle_ai_response(response, %{"title" => "Yellow"})
    end
  end

  describe "TranslateWorker" do
    # A fresh sample usually gets the format right, and a retry refreshes the
    # request cache, so these retry within max_attempts like missing_fields
    # rather than being discarded on the first bad answer. Either way the
    # job never reaches `put_translation`.
    test "retries both new parse errors" do
      assert TranslateWorker.retryable?({:parse_error, {:unexpected_markers, ["FAQ"]}})
      assert TranslateWorker.retryable?({:parse_error, {:placeholder_echo, ["title"]}})
    end

    test "classifies both for the activity log" do
      assert TranslateWorker.classify_reason({:parse_error, {:unexpected_markers, ["FAQ"]}}) ==
               {"parse_error", "unexpected_markers"}

      assert TranslateWorker.classify_reason({:parse_error, {:placeholder_echo, ["title"]}}) ==
               {"parse_error", "placeholder_echo"}
    end
  end
end
