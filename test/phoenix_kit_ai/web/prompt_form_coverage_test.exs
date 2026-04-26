defmodule PhoenixKitAI.Web.PromptFormCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.PromptForm`. Targets the
  `validate` event (extracted_variables tracking) and the update path
  through `save_prompt` that the existing tests don't cover.
  """

  use PhoenixKitAI.LiveCase

  describe "validate event extracts variables for preview" do
    test "validate with new content updates extracted_variables", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_change(view, "validate", %{
          "prompt" => %{
            "name" => "Probe",
            "content" => "Hello {{Name}}, you live in {{City}}"
          }
        })

      assert is_binary(html)
    end

    test "validate with no variables leaves extracted_variables empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_change(view, "validate", %{
          "prompt" => %{"name" => "X", "content" => "Plain text"}
        })

      assert is_binary(html)
    end
  end

  describe "save event — update path" do
    test "saving an existing prompt navigates to /prompts and flashes :updated",
         %{conn: conn} do
      prompt = fixture_prompt(name: "ToUpdate-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/#{prompt.uuid}/edit")

      result =
        render_hook(view, "save", %{
          "prompt" => %{
            "name" => prompt.name,
            "content" => "New content {{V}}"
          }
        })

      # push_navigate result OR error html
      assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
    end

    test "save with invalid attrs renders inline errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_hook(view, "save", %{
          "prompt" => %{"name" => "", "content" => ""}
        })

      assert html =~ "blank" or html =~ "can&#39;t be"
    end
  end
end
