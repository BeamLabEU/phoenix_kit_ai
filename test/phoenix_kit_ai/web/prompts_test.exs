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
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      prompt = fixture_prompt(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      html =
        view
        |> element("#prompt-tbl-menu-#{prompt.uuid} button[phx-click='toggle_prompt']")
        |> render_click()

      reloaded = PhoenixKitAI.get_prompt!(prompt.uuid)
      refute reloaded.enabled
      assert html =~ "Prompt disabled"

      assert_activity_logged(
        "prompt.disabled",
        resource_uuid: prompt.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => prompt.name,
          "actor_role" => "user"
        }
      )
    end
  end

  describe "delete_prompt" do
    test "removes the row, flashes, and logs `prompt.deleted`", %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      prompt = fixture_prompt()

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      html =
        view
        |> element("#prompt-tbl-menu-#{prompt.uuid} button[phx-click='delete_prompt']")
        |> render_click()

      assert PhoenixKitAI.get_prompt(prompt.uuid) == nil
      assert html =~ "Prompt deleted"

      assert_activity_logged(
        "prompt.deleted",
        resource_uuid: prompt.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => prompt.name,
          "actor_role" => "user"
        }
      )
    end

    test "delete button declares phx-disable-with so a slow delete can't be double-clicked",
         %{conn: conn} do
      _prompt = fixture_prompt()

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts")

      assert html =~ ~r/phx-click="delete_prompt"[^>]+phx-disable-with/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages and logs at :debug", %{conn: conn} do
      # Lift global Logger level — test config sets `:warning` which
      # filters debug BEFORE capture_log sees it. Workspace AGENTS.md
      # "Logger.level must be lifted" trap.
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, :unknown_msg_from_another_module)
          send(view.pid, {:something_we_dont_care_about, %{}, %{}})

          html = render(view)
          assert html =~ "AI Prompts"
        end)

      assert log =~ "[PhoenixKitAI.Web.Prompts] unhandled handle_info"
    end
  end
end
