defmodule PhoenixKitAI.Web.TasksUserLimitsOffTest do
  @moduledoc """
  «AI → Tasks» for a task declared with `user_limits: false`: no user
  limits, no people at a limit and no personal limits, one line saying the
  task's module sets them; the user changes are refused. Another task keeps
  its user limits.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{GuardEvent, TaskSetting, TaskUserLimit}
  alias PhoenixKitAI.Test.{FakeLimitTasks, FakeOwnUserLimitsTasks}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @off "[data-task-key='test.own_user_limits']"
  @on "[data-task-key='test.limited']"
  @line "Limits per user are set by the task's module"

  setup do
    :ok = ModuleRegistry.register(PhoenixKitAI)
    :ok = ModuleRegistry.register(FakeLimitTasks)
    :ok = ModuleRegistry.register(FakeOwnUserLimitsTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeOwnUserLimitsTasks)
      ModuleRegistry.unregister(FakeLimitTasks)
      ModuleRegistry.unregister(PhoenixKitAI)
    end)

    # The first user registered is the Owner.
    owner = Fixtures.user_fixture()
    {:ok, owner: owner}
  end

  defp open(conn, user) do
    {:ok, view, _html} =
      conn |> put_test_scope(Scope.for_user(user)) |> live("/en/admin/ai/tasks")

    view
  end

  test "the task shows its own limits and one line for the user ones",
       %{conn: conn, owner: owner} do
    view = open(conn, owner)

    assert has_element?(view, "#{@off} [data-user-limits-off]", @line)
    assert has_element?(view, "#{@off} [data-limit='task-requests-day']")
    refute has_element?(view, "#{@off} [data-limit^='user-']")
    refute has_element?(view, "#{@off} th", "Each user")
    refute has_element?(view, "#{@off} [data-personal-limits]")
    refute has_element?(view, "#{@off} [data-users-reached]")

    assert has_element?(view, "#{@on} [data-limit='user-requests-day']")
    assert has_element?(view, "#{@on} [data-personal-limits]")
    refute has_element?(view, "#{@on} [data-user-limits-off]")
  end

  test "the user changes are refused with that line", %{conn: conn, owner: owner} do
    target = Fixtures.user_fixture().uuid
    view = open(conn, owner)

    for {event, params} <- [
          {"save_user_limits",
           %{
             "task" => "test.own_user_limits",
             "user" => target,
             "limits" => %{"requests" => %{"day" => "1"}}
           }},
          {"save_limits",
           %{
             "task" => "test.own_user_limits",
             "limits" => %{"user" => %{"requests" => %{"day" => "1"}}}
           }},
          {"forgive",
           %{
             "task" => "test.own_user_limits",
             "scope" => "user",
             "period" => "day",
             "user" => target
           }}
        ] do
      render_hook(view, event, params)
      assert has_element?(view, "#flash-error", @line), "#{event} was not refused"
    end

    assert TestRepo.aggregate(TaskSetting, :count) == 0
    assert TestRepo.aggregate(TaskUserLimit, :count) == 0
    assert TestRepo.aggregate(GuardEvent, :count) == 0
  end

  test "the line is translated, not fuzzy" do
    for locale <- ["en", "et", "ru"] do
      path = Path.join(["priv/gettext", locale, "LC_MESSAGES/default.po"])

      entry =
        Enum.find(Expo.PO.parse_file!(path).messages, &(Enum.join(&1.msgid) == @line))

      assert entry, "#{locale}: no entry"
      refute Expo.Message.has_flag?(entry, "fuzzy"), "#{locale}: fuzzy"
      assert Enum.join(entry.msgstr) != "", "#{locale}: empty"
    end

    assert Gettext.with_locale(PhoenixKitAI.Gettext, "ru", fn ->
             Gettext.dgettext(PhoenixKitAI.Gettext, "default", @line)
           end) == "Лимиты на пользователя задаёт модуль задачи"
  end
end
