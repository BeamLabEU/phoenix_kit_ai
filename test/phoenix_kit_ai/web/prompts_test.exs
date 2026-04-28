defmodule PhoenixKitAI.Web.PromptsTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the prompts list with the seeded prompt", %{conn: conn} do
      fixture_prompt(name: "Visible Prompt")

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")
      assert html =~ "Visible Prompt"
    end

    test "renders the empty/setup state with no prompts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")
      assert html =~ ~r/No prompts|setup|prompt/i
    end
  end

  describe "toggle_prompt" do
    test "flipping enabled persists, flashes, and emits an activity row",
         %{conn: conn} do
      prompt = fixture_prompt(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      html =
        view
        |> element("button[phx-click='toggle_prompt'][phx-value-uuid='#{prompt.uuid}']")
        |> render_click()

      reloaded = PhoenixKitAI.get_prompt!(prompt.uuid)
      refute reloaded.enabled
      assert html =~ "Prompt disabled"

      assert_activity_logged("prompt.disabled", resource_uuid: prompt.uuid)
    end
  end

  describe "delete_prompt" do
    test "removes the row, flashes, and logs `prompt.deleted`", %{conn: conn} do
      prompt = fixture_prompt()

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      html =
        view
        |> element("button[phx-click='delete_prompt'][phx-value-uuid='#{prompt.uuid}']")
        |> render_click()

      assert PhoenixKitAI.get_prompt(prompt.uuid) == nil
      assert html =~ "Prompt deleted"

      assert_activity_logged("prompt.deleted", resource_uuid: prompt.uuid)
    end

    test "delete button declares phx-disable-with so a slow delete can't be double-clicked",
         %{conn: conn} do
      _prompt = fixture_prompt()

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")

      assert html =~ ~r/phx-click="delete_prompt"[^>]+phx-disable-with/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      assert is_binary(render(view))
    end
  end
end
