defmodule PhoenixKitAI.TaskUserLimitsOffTest do
  @moduledoc """
  A task declared with `user_limits: false` (its module keeps its own
  per-user limits): `PhoenixKitAI.TaskLimits` never applies the user scope
  to it — no check, no warning, no refusal — ignores the declaration's
  user part and the stored user values (keeping them), and refuses to set
  user limits or forgive one. The task scope works as for any task.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Guard, GuardEvent, Request, TaskLimits, Tasks, TaskSetting, TaskSpec}
  alias PhoenixKitAI.TaskUserLimit
  alias PhoenixKitAI.Test.FakeOwnUserLimitsTasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @key "test.own_user_limits"

  setup do
    {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "3")
    :ok = ModuleRegistry.register(FakeOwnUserLimitsTasks)
    on_exit(fn -> ModuleRegistry.unregister(FakeOwnUserLimitsTasks) end)

    # The first user registered is the Owner; the people of a test come after.
    owner = Fixtures.user_fixture()
    user = Fixtures.user_fixture().uuid
    {:ok, owner: owner, scope: Scope.for_user(owner), user: user}
  end

  defp spec, do: Tasks.get(@key)

  defp endpoint_fixture do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "UserLimitsOff-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/model",
        api_key: "sk-test-key"
      })

    endpoint
  end

  # A successful journal row of the task, now.
  defp row(endpoint, user_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Request{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: "success",
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 10,
      cost_cents: 1_000,
      latency_ms: 1,
      user_uuid: user_uuid,
      metadata: %{"task" => @key},
      inserted_at: now,
      updated_at: now
    }
    |> TestRepo.insert!()
  end

  # User values stored before the task's module took its users' limits over.
  defp stored_user_values!(user) do
    TestRepo.insert!(%TaskSetting{
      task_key: @key,
      limits: %{"user" => %{"requests" => %{"day" => 0}}, "task" => %{}}
    })

    TestRepo.insert!(%TaskUserLimit{
      task_key: @key,
      user_uuid: user,
      limits: %{"requests" => %{"day" => 0}}
    })

    TaskLimits.reset_cache()
  end

  defp guard_events, do: TestRepo.all(from(e in GuardEvent, order_by: e.inserted_at))

  test "a declaration applies the user scope unless it says otherwise" do
    assert %TaskSpec{key: "x"}.user_limits == true
    assert spec().user_limits == false
  end

  test "a flag that is not false is read as true" do
    assert Tasks.get("test.user_limits_nil").user_limits == true
    assert Tasks.get("test.user_limits_other").user_limits == true
  end

  describe "the limits in force" do
    test "only the task's: the declared and stored user values are ignored", %{user: user} do
      stored_user_values!(user)

      assert TaskLimits.effective(spec(), user) == %{task: %{requests: %{day: 3}}, user: %{}}

      layers = TaskLimits.layers(spec())
      assert layers.declared == %{task: %{requests: %{day: 3}}, user: %{}}
      assert layers.stored == %{task: %{}, user: %{}}
      assert layers.defaults == %{task: %{requests: %{day: 3}}, user: %{}}
    end

    test "the stored user values stay in the database", %{user: user} do
      stored_user_values!(user)
      _ = TaskLimits.effective(spec(), user)

      assert %TaskSetting{limits: %{"user" => %{"requests" => %{"day" => 0}}}} =
               TestRepo.get_by(TaskSetting, task_key: @key)

      assert %TaskUserLimit{} = TestRepo.get_by(TaskUserLimit, task_key: @key, user_uuid: user)
    end
  end

  describe "the call-time check" do
    test "a user past every user value is neither warned nor refused", %{user: user} do
      stored_user_values!(user)
      endpoint = endpoint_fixture()
      row(endpoint, user)
      row(endpoint, user)

      assert TaskLimits.statuses(spec(), user) |> Enum.map(& &1.scope) |> Enum.uniq() == [:task]
      assert :ok = TaskLimits.check(spec(), user_uuid: user)
      assert guard_events() == []
    end

    test "the task's limit still refuses, as the task's", %{user: user} do
      endpoint = endpoint_fixture()
      for _ <- 1..3, do: row(endpoint, user)

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec(), user_uuid: user)

      assert [%GuardEvent{kind: "limit_reached", user_uuid: nil}] = guard_events()
    end
  end

  describe "the admission of a piece of work" do
    test "the user values do not stop it; the task's limit does", %{user: user} do
      stored_user_values!(user)
      endpoint = endpoint_fixture()
      row(endpoint, user)

      assert {:ok, token} = Guard.admit(@key, user, "turn-1", 300)
      assert Guard.admitted?(token, @key, user)

      row(endpoint, user)
      row(endpoint, user)

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               Guard.admit(@key, user, "turn-2", 300)
    end
  end

  describe "changes" do
    test "user cells in the task's settings are refused; nothing is written",
         %{scope: scope} do
      assert {:error, :user_limits_off} =
               TaskLimits.update_settings(scope, @key, %{
                 "limits" => %{"user" => %{"requests" => %{"day" => "2"}}}
               })

      assert TestRepo.get_by(TaskSetting, task_key: @key) == nil
    end

    test "the task's cells save and keep the stored user values", %{scope: scope, user: user} do
      stored_user_values!(user)

      assert {:ok, %TaskSetting{limits: limits}} =
               TaskLimits.update_settings(scope, @key, %{
                 "limits" => %{
                   "task" => %{"requests" => %{"day" => "7"}},
                   "user" => %{"requests" => %{"day" => ""}}
                 }
               })

      assert limits["task"] == %{"requests" => %{"day" => 7}}
      assert limits["user"] == %{"requests" => %{"day" => 0}}
      assert TaskLimits.effective(spec(), user) == %{task: %{requests: %{day: 7}}, user: %{}}
    end

    test "personal limits are refused, also an empty set that would remove them",
         %{scope: scope, user: user} do
      stored_user_values!(user)

      for limits <- [%{"requests" => %{"day" => "2"}}, %{}] do
        assert {:error, :user_limits_off} =
                 TaskLimits.put_user_limits(scope, @key, user, limits)
      end

      assert %TaskUserLimit{limits: %{"requests" => %{"day" => 0}}} =
               TestRepo.get_by(TaskUserLimit, task_key: @key, user_uuid: user)
    end

    test "a user's limit is not forgiven; the task's is", %{scope: scope, user: user} do
      for limit_scope <- [:user, "user"] do
        assert {:error, :user_limits_off} =
                 TaskLimits.forgive(scope, @key, limit_scope, :day, user)
      end

      assert guard_events() == []

      assert {:ok, %GuardEvent{kind: "limit_forgiven"}} =
               TaskLimits.forgive(scope, @key, :task, :day, nil)
    end
  end
end
