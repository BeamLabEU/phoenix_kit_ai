defmodule PhoenixKitAI.Web.PromptFormTest do
  use PhoenixKitAI.LiveCase

  describe "new" do
    test "renders the create prompt form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts/new")
      assert html =~ "Prompt" or html =~ "Create"
    end
  end

  describe "edit" do
    test "renders the edit form for an existing prompt", %{conn: conn} do
      prompt = fixture_prompt(name: "Editable Prompt")

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts/#{prompt.uuid}/edit")
      assert html =~ "Editable Prompt"
    end

    test "redirects with an error flash when the prompt doesn't exist", %{conn: conn} do
      missing_uuid = "01234567-89ab-7def-8000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/ai/prompts/#{missing_uuid}/edit")

      assert flash["error"] =~ "Prompt not found"
    end
  end
end
