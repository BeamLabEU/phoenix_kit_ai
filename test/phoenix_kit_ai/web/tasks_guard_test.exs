defmodule PhoenixKitAI.Web.TasksGuardTest do
  @moduledoc """
  The guard on the «AI → Tasks» page: limits, use, forgiving, personal
  limits, watchers and "only verified models". Every event that changes
  something is refused without `ai.manage` — also with only the base `ai`,
  and for a session whose permission was taken away while the page was open
  — and works with it and for an Owner.
  """

  use PhoenixKitAI.LiveCase

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Guard, GuardEvent, GuardEvents, Request, TaskLimits, TaskSetting}
  alias PhoenixKitAI.TaskUserLimit
  alias PhoenixKitAI.Test.FakeLimitTasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @card "[data-task-key='test.limited']"

  setup do
    :ok = ModuleRegistry.register(PhoenixKitAI)
    :ok = ModuleRegistry.register(FakeLimitTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeLimitTasks)
      ModuleRegistry.unregister(PhoenixKitAI)
      Application.delete_env(:phoenix_kit_ai, :fake_limit_endpoints)
    end)

    owner = Fixtures.user_fixture()
    {:ok, owner: owner}
  end

  defp admin(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    {user, role_uuid}
  end

  defp open(conn, user) do
    {:ok, view, _html} =
      conn |> put_test_scope(Scope.for_user(user)) |> live("/en/admin/ai/tasks")

    view
  end

  defp limits_params(day) do
    %{"task" => "test.limited", "limits" => %{"task" => %{"requests" => %{"day" => day}}}}
  end

  # Every event that changes something, with valid parameters.
  defp changes(target_uuid) do
    [
      {"save_limits", limits_params("3")},
      {"forgive", %{"task" => "test.limited", "scope" => "task", "period" => "day"}},
      {"limit_user_pick",
       %{"id" => "x-user-picker", "uuid" => target_uuid, "label" => "someone@example.com"}},
      {"save_user_limits",
       %{
         "task" => "test.limited",
         "user" => target_uuid,
         "limits" => %{"requests" => %{"day" => "1"}}
       }},
      {"delete_user_limits", %{"task" => "test.limited", "user" => target_uuid}},
      {"watcher_pick", %{"id" => "ai-guard-watcher-picker", "uuid" => target_uuid}},
      {"remove_watcher", %{"uuid" => target_uuid}},
      {"toggle_verified_only", %{}},
      {"limit_user_search", %{"q" => "user", "id" => "x"}},
      {"watcher_search", %{"q" => "user", "id" => "x"}}
    ]
  end

  defp nothing_changed! do
    assert TestRepo.aggregate(TaskSetting, :count) == 0
    assert TestRepo.aggregate(TaskUserLimit, :count) == 0
    assert TestRepo.aggregate(GuardEvent, :count) == 0
    assert GuardEvents.configured_watchers() == []
    refute Guard.verified_only?()
  end

  describe "without ai.manage" do
    test "the page shows the values and no controls", %{conn: conn} do
      {user, _role} = admin(["ai"])
      view = open(conn, user)

      assert has_element?(view, "#ai-guard-read-only")
      assert has_element?(view, "#ai-guard-verified-only[disabled]")
      refute has_element?(view, "#ai-guard-watcher-picker")
      assert has_element?(view, "#{@card} [data-limits]")
      refute has_element?(view, "#{@card} button[type=submit]")
      refute has_element?(view, "#{@card} input[name^='limits']")
      # The declared default shows as the value in force.
      assert has_element?(view, "#{@card} [data-limit='user-requests-day']", "5")
    end

    test "every change is refused, also with only the base permission", %{conn: conn} do
      target = Fixtures.user_fixture().uuid

      for keys <- [[], ["ai"]] do
        {user, _role} = admin(keys)
        view = open(conn, user)

        for {event, params} <- changes(target) do
          html = render_hook(view, event, params)
          assert html =~ "You may not change the AI task guard", "#{event} was not refused"
        end

        refute_push_event(view, "watcher_results", _)
        refute_push_event(view, "limit_user_results", _)
        nothing_changed!()
      end
    end

    test "a permission taken away while the page is open is refused at the next event",
         %{conn: conn} do
      {user, role_uuid} = admin(["ai", "ai.manage"])
      view = open(conn, user)
      assert has_element?(view, "#{@card} button[type=submit]")

      :ok = Permissions.set_permissions(role_uuid, ["ai"])

      assert render_hook(view, "save_limits", limits_params("3")) =~
               "You may not change the AI task guard"

      # A search changes nothing and has no context check of its own: only
      # the page's check of the scope as it is now holds it back.
      render_hook(view, "watcher_search", %{"q" => user.email, "id" => "ai-guard-watcher-picker"})
      refute_push_event(view, "watcher_results", _)

      nothing_changed!()
    end
  end

  describe "with ai.manage" do
    test "the limits are saved, in dollars for money, and written to the Activity log",
         %{conn: conn} do
      {user, _role} = admin(["ai", "ai.manage"])
      view = open(conn, user)

      view
      |> form("#{@card} form[phx-submit=save_limits]", %{
        "limits" => %{
          "task" => %{"money" => %{"day" => "1.5"}, "requests" => %{"month" => "100"}},
          "user" => %{"tokens" => %{"day" => "2000"}}
        },
        "warn_percent" => "90"
      })
      |> render_submit()

      assert %TaskSetting{limits: limits, warn_percent: 90, updated_by_uuid: by} =
               TestRepo.get_by(TaskSetting, task_key: "test.limited")

      assert by == user.uuid

      assert limits == %{
               "task" => %{"money" => %{"day" => 1_500_000}, "requests" => %{"month" => 100}},
               "user" => %{"tokens" => %{"day" => 2000}}
             }

      assert has_element?(view, "#{@card} input[name='limits[task][money][day]'][value='1.50']")
      assert_activity_logged("guard.limits_updated", actor_uuid: user.uuid)
    end

    test "an amount that is not a number is refused", %{conn: conn} do
      {user, _role} = admin(["ai", "ai.manage"])
      view = open(conn, user)

      assert render_hook(view, "save_limits", limits_params("lots")) =~
               "A limit must be a whole number"

      assert TestRepo.aggregate(TaskSetting, :count) == 0
    end

    test "money that is not a finite amount, is negative, too large or rounds to nothing is a form error",
         %{conn: conn} do
      {user, _role} = admin(["ai", "ai.manage"])
      view = open(conn, user)

      for value <- ["NaN", "nan", "inf", "-Infinity", "1e400", "1000000001", "-1", "0.0000001"] do
        params = %{
          "task" => "test.limited",
          "limits" => %{"task" => %{"money" => %{"day" => value}}}
        }

        assert render_hook(view, "save_limits", params) =~ "A limit must be a whole number",
               "#{value} was accepted"

        assert Process.alive?(view.pid)
      end

      assert TestRepo.aggregate(TaskSetting, :count) == 0

      # A blank field is no limit, not an error; a small real amount is kept.
      render_hook(view, "save_limits", %{
        "task" => "test.limited",
        "limits" => %{"task" => %{"money" => %{"day" => "", "month" => "0.000001"}}}
      })

      assert %TaskSetting{limits: %{"task" => %{"money" => %{"month" => 1}}}} =
               TestRepo.get_by(TaskSetting, task_key: "test.limited")
    end

    test "use is shown, a reached task limit can be forgiven", %{conn: conn, owner: owner} do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Mistral EP",
          provider: "mistral",
          base_url: "https://api.mistral.ai/v1",
          model: "mistral-small",
          api_key: "k"
        })

      Application.put_env(:phoenix_kit_ai, :fake_limit_endpoints, [endpoint.uuid])

      {:ok, _} =
        TaskLimits.update_settings(Scope.for_user(owner), "test.limited", %{
          "limits" => %{"task" => %{"requests" => %{"day" => 1}}}
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)

      TestRepo.insert!(%Request{
        endpoint_uuid: endpoint.uuid,
        model: "mistral-small",
        request_type: "chat",
        status: "success",
        total_tokens: 42,
        cost_cents: 0,
        metadata: %{"task" => "test.limited"},
        inserted_at: now,
        updated_at: now
      })

      {user, _role} = admin(["ai", "ai.manage"])
      view = open(conn, user)

      assert has_element?(view, "#{@card} tr[data-unit=tokens] [data-used=day]", "42")
      assert has_element?(view, "#{@card} tr[data-unit=requests] [data-used=month]", "1")
      assert has_element?(view, "#{@card} [data-money-uncounted]", "Mistral EP")

      view |> element("#{@card} [data-forgive='task-day']") |> render_click()

      refute has_element?(view, "#{@card} [data-forgive='task-day']")
      assert [%GuardEvent{kind: "limit_forgiven", actor_uuid: actor}] = TestRepo.all(GuardEvent)
      assert actor == user.uuid
    end

    test "a person at a limit is listed until forgiven", %{conn: conn, owner: owner} do
      person = Fixtures.user_fixture()

      {:ok, _} =
        TaskLimits.update_settings(Scope.for_user(owner), "test.limited", %{
          "limits" => %{"user" => %{"requests" => %{"day" => 1}}}
        })

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Reached EP",
          provider: "openrouter",
          model: "a/b",
          api_key: "k"
        })

      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)

      TestRepo.insert!(%Request{
        endpoint_uuid: endpoint.uuid,
        model: "a/b",
        request_type: "chat",
        status: "success",
        user_uuid: person.uuid,
        metadata: %{"task" => "test.limited"},
        inserted_at: at,
        updated_at: at
      })

      assert {:error, _} =
               TaskLimits.check(PhoenixKitAI.Tasks.get("test.limited"), user_uuid: person.uuid)

      {user, _role} = admin(["ai", "ai.manage"])
      view = open(conn, user)
      row = "#{@card} [data-reached-user='#{person.uuid}']"
      assert has_element?(view, row, person.email)

      view |> element("#{row} [data-forgive='user-day']") |> render_click()
      refute has_element?(view, row)

      assert [%GuardEvent{user_uuid: forgiven}] =
               TestRepo.all(from(e in GuardEvent, where: e.kind == "limit_forgiven"))

      assert forgiven == person.uuid
    end

    test "personal limits: pick a person, save, remove", %{conn: conn} do
      {user, _role} = admin(["ai", "ai.manage"])
      person = Fixtures.user_fixture()
      view = open(conn, user)
      picker = view |> element("#{@card} input[phx-hook=SearchPicker]") |> render()
      [_, picker_id] = Regex.run(~r/id="([^"]+-user-picker)"/, picker)

      render_hook(view, "limit_user_search", %{"q" => person.email, "id" => picker_id})
      assert_push_event(view, "limit_user_results", %{results: [%{uuid: uuid}]})
      assert uuid == person.uuid

      render_hook(view, "limit_user_pick", %{
        "id" => picker_id,
        "uuid" => person.uuid,
        "label" => person.email
      })

      view
      |> form("#{@card} form[phx-submit=save_user_limits]", %{
        "limits" => %{"requests" => %{"day" => "2"}}
      })
      |> render_submit()

      assert %TaskUserLimit{limits: %{"requests" => %{"day" => 2}}} =
               TestRepo.get_by(TaskUserLimit, task_key: "test.limited", user_uuid: person.uuid)

      assert has_element?(view, "#{@card} [data-personal-user='#{person.uuid}']", person.email)

      view |> element("#{@card} [data-remove-personal='#{person.uuid}']") |> render_click()
      assert TestRepo.aggregate(TaskUserLimit, :count) == 0
    end

    test "watchers are added and removed, and each change is in the Activity log",
         %{conn: conn} do
      {user, _role} = admin(["ai", "ai.manage"])
      watcher = Fixtures.user_fixture()
      view = open(conn, user)
      assert has_element?(view, "[data-watchers-owners]")

      render_hook(view, "watcher_pick", %{
        "id" => "ai-guard-watcher-picker",
        "uuid" => watcher.uuid
      })

      assert GuardEvents.configured_watchers() == [watcher.uuid]
      assert has_element?(view, "[data-watcher='#{watcher.uuid}']", watcher.email)

      view |> element("[data-watcher='#{watcher.uuid}'] button") |> render_click()
      assert GuardEvents.configured_watchers() == []

      assert [_, _] =
               TestRepo.all(
                 from(a in "phoenix_kit_activities",
                   where: a.action == "guard.watchers_updated",
                   select: a.action
                 )
               )
    end
  end

  test "an Owner may change everything", %{conn: conn, owner: owner} do
    view = open(conn, owner)
    refute has_element?(view, "#ai-guard-read-only")

    render_click(view, "toggle_verified_only", %{})
    assert Guard.verified_only?()

    render_hook(view, "save_limits", limits_params("7"))

    assert %TaskSetting{limits: %{"task" => %{"requests" => %{"day" => 7}}}} =
             TestRepo.get_by(TaskSetting, task_key: "test.limited")
  end
end
