defmodule PhoenixKitAI.Web.PromptsTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the prompts list", %{conn: conn} do
      fixture_prompt(name: "Visible Prompt")

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")
      assert html =~ "Visible Prompt"
    end

    test "renders without crashing when there are no prompts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")
      assert is_binary(html)
    end
  end

  describe "toggle_prompt" do
    test "flipping enabled persists to the DB", %{conn: conn} do
      prompt = fixture_prompt(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      view
      |> element("button[phx-click='toggle_prompt'][phx-value-uuid='#{prompt.uuid}']")
      |> render_click()

      reloaded = PhoenixKitAI.get_prompt!(prompt.uuid)
      refute reloaded.enabled
    end
  end

  describe "delete_prompt" do
    test "removes the prompt from the DB", %{conn: conn} do
      prompt = fixture_prompt()

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      view
      |> element("button[phx-click='delete_prompt'][phx-value-uuid='#{prompt.uuid}']")
      |> render_click()

      assert PhoenixKitAI.get_prompt(prompt.uuid) == nil
    end
  end
end
