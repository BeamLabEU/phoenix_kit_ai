defmodule PhoenixKitAI.TranslationGlossaryPromptTest do
  @moduledoc """
  Pins the wiring between the glossary variable the engine binds
  (`PhoenixKitAI.Translation.build_variables/4`) and the slot the shipped
  shared prompt carries. Each half can be individually correct while the
  glossary reaches no model at all, so the seam gets its own test.

  Database-free on purpose: it reads the template, it does not provision it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Translation
  alias PhoenixKitAI.Translations

  describe "shared translation prompt carries the {{Glossary}} slot" do
    test "the template has exactly one {{Glossary}} slot" do
      content = Translations.default_prompt_content()

      assert length(Regex.scan(~r/\{\{Glossary\}\}/, content)) == 1
    end

    test "the slot's name matches the variable the engine binds" do
      # The two sides are written independently; a rename on either side
      # silently disables the feature. Derive the assertion from the engine's
      # own output rather than repeating the string.
      bound =
        Translation.build_variables(%{"title" => "W"}, "en", "de", "term = Begriff")
        |> Map.keys()
        |> Enum.filter(&(&1 == "Glossary"))

      assert bound == ["Glossary"]
      assert Translations.default_prompt_content() =~ "{{#{hd(bound)}}}"
    end

    test "the slot sits in the instruction area, before the SOURCE block" do
      # A glossary rendered after the source text reads as part of the content
      # to translate rather than as an instruction about it.
      content = Translations.default_prompt_content()

      [{glossary_at, _}] = Regex.run(~r/\{\{Glossary\}\}/, content, return: :index)
      [{source_at, _}] = Regex.run(~r/=== SOURCE ===/, content, return: :index)

      assert glossary_at < source_at
    end
  end
end
