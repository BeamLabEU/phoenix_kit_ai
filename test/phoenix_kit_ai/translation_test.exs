defmodule PhoenixKitAI.TranslationTest do
  @moduledoc """
  Unit coverage for `PhoenixKitAI.Translation` — focuses on
  the pieces that don't need a live `PhoenixKitAI` plugin: argument
  validation, marker uniqueness, structured-response parsing, error
  normalisation.

  End-to-end coverage (the actual `ask_with_prompt/4` round-trip) lives
  in each consumer's worker test (`phoenix_kit_publishing`'s
  `translate_post_worker_test`, etc.) since the orchestration needs a
  configured endpoint + prompt that only those repos seed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Translation

  describe "translate_fields/6 — argument validation runs before plugin check" do
    # Validation order is `endpoint → prompt → non-empty → unique-markers → plugin-available`.
    # Tests below assume PhoenixKitAI is NOT loaded in core's CI; the
    # input-validation errors must still surface so callers can unit-test
    # them without a configured plugin.

    test "empty endpoint_uuid → :no_endpoint" do
      assert {:error, :no_endpoint} =
               Translation.translate_fields("", "p-uuid", "en", "es", %{"a" => "b"})
    end

    test "whitespace-only endpoint_uuid → :no_endpoint" do
      assert {:error, :no_endpoint} =
               Translation.translate_fields("   ", "p-uuid", "en", "es", %{"a" => "b"})
    end

    test "nil endpoint_uuid → :no_endpoint" do
      assert {:error, :no_endpoint} =
               Translation.translate_fields(nil, "p-uuid", "en", "es", %{"a" => "b"})
    end

    test "empty prompt_uuid → :missing_prompt" do
      assert {:error, :missing_prompt} =
               Translation.translate_fields("ep", "", "en", "es", %{"a" => "b"})
    end

    test "whitespace-only prompt_uuid → :missing_prompt" do
      assert {:error, :missing_prompt} =
               Translation.translate_fields("ep", "  ", "en", "es", %{"a" => "b"})
    end

    test "empty fields map → :no_markers (rejected before plugin call)" do
      # Empty `fields` would render a prompt with no field variables,
      # spend tokens on a `PhoenixKitAI.ask_with_prompt/4` call, and
      # only fail downstream in `parse_response/2`. Reject up front so
      # a caller bug doesn't burn a request. Sentinel matches the
      # `parse_response/2` shape (`{:parse_error, :no_markers}`) so
      # callers can branch on a single class.
      assert {:error, {:parse_error, :no_markers}} =
               Translation.translate_fields("ep", "p", "en", "es", %{})
    end

    test "two fields that normalise to the same marker → duplicate_markers error" do
      # `foo-bar` and `foo_bar` both upcase + non-alnum-collapse to `FOO_BAR`.
      # Without this rejection, the parser would silently overwrite one
      # field's translation with the other's.
      assert {:error, {:parse_error, {:duplicate_markers, dupes}}} =
               Translation.translate_fields(
                 "ep",
                 "p",
                 "en",
                 "es",
                 %{"foo-bar" => "a", "foo_bar" => "b"}
               )

      assert "FOO_BAR" in dupes
    end

    test "handle_ai_response/2 unwraps OpenAI-shaped response map" do
      # Drives the actual code path that was broken pre-fix:
      # `ask_with_prompt/4` returns the full OpenAI response map,
      # not a raw string. The helper must reach into
      # `choices[0].message.content` inline before passing through
      # to `parse_response/2`. The previous test asserted only on
      # `parse_response/2` directly and would have passed against
      # the broken implementation.
      response_map = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "---TITLE---\nHola\n---BODY---\nMundo"
            }
          }
        ]
      }

      assert {:ok, %{"title" => "Hola", "body" => "Mundo"}} =
               Translation.handle_ai_response(response_map, %{
                 "title" => "Hello",
                 "body" => "World"
               })
    end

    test "handle_ai_response/2 also accepts raw binary (test stub / legacy)" do
      assert {:ok, %{"title" => "Hola"}} =
               Translation.handle_ai_response("---TITLE---\nHola", %{"title" => "Hello"})
    end

    test "handle_ai_response/2 returns :ai_error for malformed shape" do
      # Atom — wholly wrong type
      assert {:error, {:ai_error, {:unexpected_response, _}}} =
               Translation.handle_ai_response(:not_a_response, %{"a" => "b"})

      # Empty choices list — valid OpenAI envelope but no completion
      assert {:error, {:ai_error, {:unexpected_response, _}}} =
               Translation.handle_ai_response(%{"choices" => []}, %{"a" => "b"})

      # Choice present but non-binary content (e.g. structured-parts
      # API or refusal/tool_call response — falls back to the same
      # unexpected_response shape rather than crashing)
      assert {:error, {:ai_error, {:unexpected_response, _}}} =
               Translation.handle_ai_response(
                 %{"choices" => [%{"message" => %{"content" => nil}}]},
                 %{"a" => "b"}
               )

      # Missing `message` entirely
      assert {:error, {:ai_error, {:unexpected_response, _}}} =
               Translation.handle_ai_response(%{"choices" => [%{}]}, %{"a" => "b"})
    end

    # NOTE: the old "valid inputs + missing plugin → :ai_not_installed" case was
    # removed in the move into phoenix_kit_ai. That guard only fired when the
    # PhoenixKitAI plugin module wasn't loaded — impossible now that this code
    # lives *inside* the plugin, so the scenario is unreachable.

    test "validation order: endpoint > prompt > non-empty > unique-markers" do
      # Pin the documented validation order. Each test below stacks
      # multiple input violations and asserts which one wins — if a
      # future refactor accidentally reorders the validation chain
      # (e.g. moves `validate_non_empty` before `validate_uuid`),
      # these regressions catch it.

      # Empty endpoint wins over empty fields + missing plugin.
      assert {:error, :no_endpoint} =
               Translation.translate_fields("", "", "en", "es", %{})

      # Endpoint present, empty prompt wins over empty fields.
      assert {:error, :missing_prompt} =
               Translation.translate_fields("ep", "", "en", "es", %{})

      # Endpoint + prompt present, empty fields wins before
      # validate_unique_markers gets to iterate Map.keys over a
      # zero-element map for nothing.
      assert {:error, {:parse_error, :no_markers}} =
               Translation.translate_fields("ep", "p", "en", "es", %{})

      # Endpoint + prompt + non-empty fields, dup markers reject.
      assert {:error, {:parse_error, {:duplicate_markers, _}}} =
               Translation.translate_fields(
                 "ep",
                 "p",
                 "en",
                 "es",
                 %{"foo-bar" => "a", "foo_bar" => "b"}
               )

      # Whitespace-only endpoint behaves like empty endpoint — the
      # validator trims before checking. Pins the contract so a
      # future "strict equality" refactor (`endpoint == ""`) breaks
      # loudly instead of silently accepting `"   "`.
      assert {:error, :no_endpoint} =
               Translation.translate_fields("   ", "p", "en", "es", %{"a" => "b"})

      # Whitespace-only prompt — same trim-then-check contract.
      assert {:error, :missing_prompt} =
               Translation.translate_fields("ep", "   ", "en", "es", %{"a" => "b"})
    end
  end

  describe "parse_response/2 — structured `---FIELD---` markers" do
    test "parses two fields back into a map keyed by the input names" do
      response = """
      ---TITLE---
      Hola Mundo
      ---BODY---
      Bienvenido a la app.
      """

      assert {:ok, %{"title" => "Hola Mundo", "body" => "Bienvenido a la app."}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "preserves the caller's input casing in the result keys" do
      response = "---FOO_BAR---\nvalue\n"

      assert {:ok, %{"Foo_Bar" => "value"}} =
               Translation.parse_response(response, ["Foo_Bar"])
    end

    test "handles three fields with arbitrary names" do
      response = """
      ---TITLE---
      Greeting
      ---SLUG---
      hello-world
      ---CONTENT---
      Body text spans
      multiple lines.
      """

      assert {:ok, parsed} =
               Translation.parse_response(response, ["title", "slug", "content"])

      assert parsed["title"] == "Greeting"
      assert parsed["slug"] == "hello-world"
      assert parsed["content"] == "Body text spans\nmultiple lines."
    end

    test "trims whitespace from each section" do
      response = "---TITLE---\n   spaced   \n---BODY---\n\ntext\n\n"

      assert {:ok, %{"title" => "spaced", "body" => "text"}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "missing field returns :missing_fields error with the absent name" do
      # Critical: pre-fix, the parser silently returned partial results.
      # Callers persisting that result would write half-translated rows.
      response = "---TITLE---\nonly title\n"

      assert {:error, {:parse_error, {:missing_fields, ["body"]}}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "multiple missing fields are all surfaced in the error" do
      response = "---TITLE---\nonly title\n"

      assert {:error, {:parse_error, {:missing_fields, missing}}} =
               Translation.parse_response(response, ["title", "body", "slug"])

      assert "body" in missing
      assert "slug" in missing
      refute "title" in missing
    end

    test "unrequested markers in the response don't leak into adjacent fields" do
      # A model that emits a marker the caller didn't ask for (e.g.
      # `---TITLE---` here, but the caller only requested `name` +
      # `description`) used to silently roll the unrequested block's
      # content into the preceding requested field. Surfaced on a
      # real deepseek-v3.2 translation where the prompt template
      # referenced `{{title}}` literally — the AI emitted a
      # `---TITLE---{{title}}` block and the parser appended it
      # to `---NAME---`'s capture.
      response = """
      ---NAME---
      Mitarbeiter-Onboarding
      ---TITLE---
      {{title}}
      ---DESCRIPTION---
      Standardablauf für den ersten Tag und die erste Woche.
      """

      assert {:ok, fields} = Translation.parse_response(response, ["name", "description"])
      assert fields["name"] == "Mitarbeiter-Onboarding"
      refute fields["name"] =~ "TITLE"
      refute fields["name"] =~ "title"
      assert fields["description"] =~ "Standardablauf"
    end

    test "literal `---WORD---` in field content doesn't prematurely terminate the capture" do
      # The boundary lookahead requires a newline before the marker
      # (`\n---WORD---`), so a literal `---WORD---` token that
      # appears MID-LINE in the translated content (technical docs,
      # API examples, code snippets describing the marker format)
      # is kept inside the capture instead of acting as a boundary.
      # Without the line-anchor, this content would prematurely
      # terminate at `---API_KEY---` and lose the trailing text.
      response = """
      ---TITLE---
      Translated title text containing literal ---API_KEY--- token and trailing text
      ---BODY---
      Body content with another ---WEIRD--- inline token here too.
      """

      assert {:ok, fields} = Translation.parse_response(response, ["title", "body"])
      assert fields["title"] =~ "containing literal ---API_KEY--- token"
      assert fields["title"] =~ "trailing text"
      assert fields["body"] =~ "another ---WEIRD--- inline token"
    end

    test "empty section between two markers returns empty string, not next field's content" do
      # When a model emits a marker with no content followed
      # immediately by the next marker (`---TITLE---\n---BODY---\n...`),
      # the underlying regex would otherwise consume the inter-marker
      # newline and capture `---BODY---\nBody...` as TITLE's content
      # — leaking the next section into the current one. Empty-section
      # guard in `extract_section/3` detects the leak by checking
      # whether the captured value starts with a marker-shaped token
      # and returns `""` instead.
      response = """
      ---TITLE---
      ---BODY---
      Body content here
      """

      assert {:ok, fields} = Translation.parse_response(response, ["title", "body"])
      assert fields["title"] == ""
      assert fields["body"] == "Body content here"
    end

    test "present-but-empty trailing marker resolves to empty string, not missing_fields" do
      # A trailing marker with no content (`...\n---BODY---` at EOS)
      # used to fail the `(.+?)` floor → no regex match → reported in
      # `missing_fields`, even though the model DID emit the marker.
      # That diverged from how an empty MIDDLE section resolves (`""`).
      # `(.*?)` lets the trailing capture match empty at `\z` so both
      # positions agree: a present-but-empty field is `""`, an absent
      # marker is still `missing_fields`.
      response = """
      ---TITLE---
      Hello
      ---BODY---
      """

      assert {:ok, fields} = Translation.parse_response(response, ["title", "body"])
      assert fields["title"] == "Hello"
      assert fields["body"] == ""
    end

    test "genuinely absent trailing marker is still reported as missing" do
      # Guards the other half of the contract changed above: dropping
      # the `(.+?)` floor must NOT turn a forgotten marker into `""`.
      response = """
      ---TITLE---
      Hello
      """

      assert {:error, {:parse_error, {:missing_fields, ["body"]}}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "returns :no_markers when nothing matches at all" do
      response = "just some markdown\n\n# header"

      assert {:error, {:parse_error, :no_markers}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "normalises punctuation in field names to underscores in the marker" do
      response = "---FIELD_NAME_WITH_SPACES---\nvalue\n"

      assert {:ok, %{"field-name with spaces" => "value"}} =
               Translation.parse_response(response, ["field-name with spaces"])
    end

    test "single-field response works without a closing boundary" do
      response = "---DESCRIPTION---\nA short description without trailing markers"

      assert {:ok, %{"description" => "A short description without trailing markers"}} =
               Translation.parse_response(response, ["description"])
    end
  end

  describe "parse_response/2 — reasoning-model hardening" do
    test "strips a <think> block whose prose mentions the markers inline" do
      # Real-world failure: a reasoning endpoint narrated the markers in its
      # chain-of-thought ("…so skip ---TITLE---…"). The blob landed in the
      # title field and overflowed the column on persist. The <think> strip +
      # line anchor must yield the real answer that follows.
      response = """
      <think>
      The user wants a translation. So skip ---TITLE--- if it's a placeholder.
      For ---CONTENT--- I should translate it. Let me produce the output now.
      </think>
      ---TITLE---
      Hola Mundo
      ---CONTENT---
      Bienvenido a la aplicación.
      """

      assert {:ok, fields} = Translation.parse_response(response, ["title", "content"])
      assert fields["title"] == "Hola Mundo"
      assert fields["content"] == "Bienvenido a la aplicación."
    end

    test "handles <thinking>/<reasoning>/<thought> tag variants too" do
      for tag <- ["thinking", "reasoning", "thought"] do
        response =
          "<#{tag}>noise ---TITLE--- noise</#{tag}>\n---TITLE---\nHola\n---BODY---\nMundo"

        assert {:ok, %{"title" => "Hola", "body" => "Mundo"}} =
                 Translation.parse_response(response, ["title", "body"]),
               "tag #{tag} should be stripped"
      end
    end

    test "a mid-sentence marker mention is not treated as a section opener" do
      # No think tags here — just bare reasoning before the real answer. The
      # mid-line `---TITLE---` ("skip ---TITLE--- now.") must not open a section;
      # only the line-start marker counts.
      response = "Reasoning: skip ---TITLE--- now.\n---TITLE---\nHola\n---BODY---\nMundo"

      assert {:ok, %{"title" => "Hola", "body" => "Mundo"}} =
               Translation.parse_response(response, ["title", "body"])
    end

    test "pure reasoning with no real markers fails cleanly as :no_markers" do
      # The production discard case: the model only ever talked about the
      # markers and never emitted real ones. Must be a clean parse error, NOT
      # a giant blob that overflows a field on persist.
      response = """
      <think>
      So for title: "Hello!" is a placeholder, so skip ---TITLE---. For content:
      {{content}} is a placeholder, so skip ---CONTENT---. My output would be empty.
      </think>
      """

      assert {:error, {:parse_error, :no_markers}} =
               Translation.parse_response(response, ["title", "content"])
    end

    test "an unclosed <think> block is left intact (no real markers → :no_markers)" do
      # Truncated reasoning: stripping to EOS could delete a real answer, so we
      # only remove balanced blocks. With no line-start markers surviving, the
      # parser still fails cleanly rather than misattributing content.
      response = "<think>\nrambling about ---TITLE--- with no closing tag and no answer"

      assert {:error, {:parse_error, :no_markers}} =
               Translation.parse_response(response, ["title", "body"])
    end
  end
end
