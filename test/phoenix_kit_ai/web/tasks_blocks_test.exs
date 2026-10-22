defmodule PhoenixKitAI.Web.TasksBlocksTest do
  @moduledoc """
  Flags and blocks on the «AI → Tasks» page: the recent off-purpose flags of
  a task (counts per person, the latest with their reasons for those who
  may see them), blocking from a flag or a person, and the active blocks
  with lifting. Without `ai.manage` it is read-only, and every event that
  changes something is refused — also for a session whose permission was
  taken away while the page was open.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Guard, GuardBlock}
  alias PhoenixKitAI.Test.FakeGuardTasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @private "[data-task-key='test.private']"
  @open "[data-task-key='test.flagged']"

  setup do
    :ok = ModuleRegistry.register(PhoenixKitAI)
    :ok = ModuleRegistry.register(FakeGuardTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeGuardTasks)
      ModuleRegistry.unregister(PhoenixKitAI)
    end)

    owner = Fixtures.user_fixture()
    person = Fixtures.user_fixture()
    {:ok, flag} = Guard.report_off_purpose("test.private", person.uuid, "PRIVATE-REASON", "t1")
    {:ok, _} = Guard.report_off_purpose("test.private", person.uuid, "PRIVATE-REASON-2", "t2")
    {:ok, _} = Guard.report_off_purpose("test.flagged", person.uuid, "OPEN-REASON", "t3")
    {:ok, owner: owner, person: person, flag: flag}
  end

  defp role_with(keys) do
    user = Fixtures.user_fixture()
    {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(user, role.name)
    :ok = Permissions.set_permissions(role.uuid, keys)
    {user, role.uuid}
  end

  defp open(conn, user) do
    {:ok, view, _html} =
      conn |> put_test_scope(Scope.for_user(user)) |> live("/en/admin/ai/tasks")

    view
  end

  defp changes(person, flag, block_uuid) do
    [
      {"block_open", %{"task" => "test.private", "user" => person.uuid, "event" => flag.uuid}},
      {"block_cancel", %{}},
      {"block_user",
       %{
         "task" => "test.private",
         "user" => person.uuid,
         "event" => flag.uuid,
         "reason" => "x"
       }},
      {"lift_open", %{"block" => block_uuid}},
      {"lift_cancel", %{}},
      {"lift_block", %{"block" => block_uuid, "note" => "x"}},
      {"toggle_self_flag", %{"task" => "test.flagged"}}
    ]
  end

  describe "the flags" do
    test "counts per person and the latest flags; a private reason is hidden without ai.manage",
         %{conn: conn, person: person} do
      {user, _role} = role_with(["ai"])
      view = open(conn, user)

      assert has_element?(view, "#{@private} [data-flag-count='#{person.uuid}']", "2")
      assert has_element?(view, "#{@private} [data-flag][data-flag-hidden]")
      refute render(view) =~ "PRIVATE-REASON"
      refute has_element?(view, "#{@private} [data-flag-request]")

      # Not private: every holder of ai sees the reason.
      assert has_element?(view, "#{@open} [data-flag]", "OPEN-REASON")

      # Read-only: no buttons.
      refute has_element?(view, "[data-block-user]")
      refute has_element?(view, "[data-block-flag]")
    end

    test "a holder of ai.manage sees the private reason and the row", %{conn: conn} do
      {user, _role} = role_with(["ai", "ai.manage"])
      view = open(conn, user)

      assert has_element?(view, "#{@private} [data-flag]", "PRIVATE-REASON")
      refute has_element?(view, "#{@private} [data-flag][data-flag-hidden]")
    end

    test "a flag without a user is listed, with nobody to block", %{conn: conn, owner: owner} do
      {:ok, nobody} = Guard.report_off_purpose("test.flagged", nil, "NO-USER-REASON", "t0")
      view = open(conn, owner)

      assert has_element?(view, "#{@open} [data-flag='#{nobody.uuid}']", "NO-USER-REASON")
      refute has_element?(view, "[data-block-flag='#{nobody.uuid}']")
    end

    test "the tables scroll inside the card", %{conn: conn, owner: owner} do
      view = open(conn, owner)
      assert has_element?(view, "#{@private} [data-guard-flags] .overflow-x-auto table")
    end
  end

  describe "blocking and lifting" do
    test "from a flag: the block is set with its reason and shown; then lifted with a note",
         %{conn: conn, person: person, flag: flag} do
      {user, _role} = role_with(["ai", "ai.manage"])
      view = open(conn, user)

      view |> element("#{@private} [data-block-flag='#{flag.uuid}']") |> render_click()
      assert has_element?(view, "#{@private} [data-block-form]")
      assert has_element?(view, "#{@private} [data-block-person]", person.email)

      view
      |> form("#{@private} [data-block-form]", %{"reason" => "Not for work"})
      |> render_submit()

      assert [%GuardBlock{block_group: "test.private", reason: "Not for work"} = block] =
               TestRepo.all(GuardBlock)

      assert block.origin_event_uuid == flag.uuid
      assert block.blocked_by_uuid == user.uuid

      assert has_element?(
               view,
               "#{@private} [data-active-block='#{person.uuid}']",
               "Not for work"
             )

      # Blocked already: no block button for the person.
      refute has_element?(view, "#{@private} [data-block-user='#{person.uuid}']")

      view |> element("#{@private} [data-lift='#{block.uuid}']") |> render_click()

      view
      |> form("#{@private} [data-lift-form]", %{"note" => "Talked it over"})
      |> render_submit()

      assert %GuardBlock{lift_note: "Talked it over", lifted_at: %DateTime{}} =
               TestRepo.get(GuardBlock, block.uuid)

      refute has_element?(view, "#{@private} [data-active-block]")
    end

    test "from a person's row", %{conn: conn, person: person, owner: owner} do
      view = open(conn, owner)

      view |> element("#{@open} [data-block-user='#{person.uuid}']") |> render_click()
      view |> form("#{@open} [data-block-form]", %{"reason" => ""}) |> render_submit()

      assert Guard.blocked?("test.flagged", person.uuid)
      assert [%GuardBlock{origin_event_uuid: nil, reason: nil}] = TestRepo.all(GuardBlock)
    end

    test "a private block's reason is hidden from a holder of ai without ai.manage",
         %{conn: conn, person: person, owner: owner} do
      {:ok, _} =
        Guard.block(Scope.for_user(owner), "test.private", person.uuid, "BLOCK-REASON", nil)

      {user, _role} = role_with(["ai"])
      view = open(conn, user)

      assert has_element?(view, "#{@private} [data-active-block='#{person.uuid}']")
      refute render(view) =~ "BLOCK-REASON"
      refute has_element?(view, "[data-lift]")
    end

    test "your own block has no lift button, and lifting it is refused", %{
      conn: conn,
      owner: owner
    } do
      {user, _role} = role_with(["ai", "ai.manage"])
      {:ok, block} = Guard.block(Scope.for_user(owner), "test.flagged", user.uuid, nil, nil)
      view = open(conn, user)

      assert has_element?(view, "#{@open} [data-active-block='#{user.uuid}']")
      refute has_element?(view, "[data-lift='#{block.uuid}']")

      html = render_hook(view, "lift_block", %{"block" => block.uuid, "note" => "me"})
      assert html =~ "Nobody but an Owner lifts their own block"
      assert Guard.blocked?("test.flagged", user.uuid)
    end

    test "an Owner shows no block button to an Admin", %{conn: conn, owner: owner} do
      {:ok, _} = Guard.report_off_purpose("test.flagged", owner.uuid, "x", "t-owner")
      {user, _role} = role_with(["ai", "ai.manage"])
      view = open(conn, user)

      refute has_element?(view, "#{@open} [data-block-user='#{owner.uuid}']")

      html =
        render_hook(view, "block_user", %{
          "task" => "test.flagged",
          "user" => owner.uuid,
          "reason" => ""
        })

      assert html =~ "Only an Owner blocks an Owner or lifts their block"
      refute Guard.blocked?("test.flagged", owner.uuid)
    end
  end

  describe "the self-flag switch" do
    test "turns self-flagging off and on again; shown only where the task self-flags",
         %{conn: conn} do
      {user, _role} = role_with(["ai", "ai.manage"])
      view = open(conn, user)

      assert has_element?(view, "#{@open} [data-self-flag]:not([disabled])[checked]")
      refute has_element?(view, "[data-task-key='test.quiet'] [data-self-flag]")

      view |> element("#{@open} [data-self-flag]") |> render_click()
      refute Guard.self_flag?("test.flagged")
      assert has_element?(view, "#{@open} [data-self-flag]:not([checked])")

      view |> element("#{@open} [data-self-flag]") |> render_click()
      assert Guard.self_flag?("test.flagged")
      assert has_element?(view, "#{@open} [data-self-flag][checked]")
    end

    test "read-only without ai.manage, and the event is refused", %{conn: conn} do
      {user, _role} = role_with(["ai"])
      view = open(conn, user)

      assert has_element?(view, "#{@open} [data-self-flag][disabled]")
      html = render_hook(view, "toggle_self_flag", %{"task" => "test.flagged"})
      assert html =~ "You may not change the AI task guard"
      assert Guard.self_flag?("test.flagged")
    end
  end

  describe "without ai.manage" do
    test "every change is refused, also with only the base permission",
         %{conn: conn, person: person, flag: flag, owner: owner} do
      {:ok, block} =
        Guard.block(Scope.for_user(owner), "test.flagged", person.uuid, "kept", nil)

      for keys <- [[], ["ai"]] do
        {user, _role} = role_with(keys)
        view = open(conn, user)

        for {event, params} <- changes(person, flag, block.uuid) do
          html = render_hook(view, event, params)
          assert html =~ "You may not change the AI task guard", "#{event} was not refused"
        end
      end

      assert [%GuardBlock{lifted_at: nil}] = TestRepo.all(GuardBlock)
    end

    test "a permission taken away while the page is open is refused at the next event",
         %{conn: conn, person: person, flag: flag} do
      {user, role_uuid} = role_with(["ai", "ai.manage"])
      view = open(conn, user)
      assert has_element?(view, "[data-block-flag='#{flag.uuid}']")

      :ok = Permissions.set_permissions(role_uuid, ["ai"])

      html =
        render_hook(view, "block_user", %{
          "task" => "test.private",
          "user" => person.uuid,
          "event" => flag.uuid,
          "reason" => "late"
        })

      assert html =~ "You may not change the AI task guard"
      assert TestRepo.all(GuardBlock) == []
    end
  end
end
