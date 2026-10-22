defmodule PhoenixKitAI.GuardRightsTest do
  @moduledoc """
  The admission of `PhoenixKitAI.Guard.admit/4` (a token honoured only for its
  task and user, and only while it lasts; the model is still checked), and
  the `ai.manage` gate of every function that changes the guard: refused
  without it — also with only the base `ai` — allowed with it and for an
  Owner.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Guard, GuardEvent, GuardEvents, Request, TaskLimits}
  alias PhoenixKitAI.Test.FakeLimitTasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(PhoenixKitAI)
    :ok = ModuleRegistry.register(FakeLimitTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeLimitTasks)
      ModuleRegistry.unregister(PhoenixKitAI)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    owner = Fixtures.user_fixture()
    {:ok, owner: owner}
  end

  defp stub_chat(test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.01}
      })
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Rights-EP-#{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "vendor/model",
            api_key: "sk-test-key"
          },
          attrs
        )
      )

    endpoint
  end

  # A user with the Admin role holding exactly `keys`, as a fresh scope.
  defp admin_scope(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    Scope.for_user(user)
  end

  defp limit_requests(owner, amount) do
    {:ok, _} =
      TaskLimits.update_settings(Scope.for_user(owner), "test.limited", %{
        "limits" => %{"user" => %{"requests" => %{"day" => amount}}}
      })
  end

  describe "admission" do
    test "a call with the token skips the limits; another user's or task's is ignored",
         %{owner: owner} do
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid
      other = Fixtures.user_fixture().uuid
      limit_requests(owner, 1)

      assert {:ok, token} = Guard.admit("test.limited", user, "turn-1", 300)
      assert Guard.admitted?(token, "test.limited", user)

      opts = [task: "test.limited", user_uuid: user, guard_admission: token]
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "round 1", opts)
      # Past the limit now, but the admitted turn runs to its end.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "round 2", opts)

      refute Guard.admitted?(token, "test.limited", other)
      refute Guard.admitted?(token, "test.unlimited", user)
      refute Guard.admitted?("forged", "test.limited", user)

      # The same token for another user is checked as usual …
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "first", task: "test.limited", user_uuid: other)

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               PhoenixKitAI.ask(ep.uuid, "again",
                 task: "test.limited",
                 user_uuid: other,
                 guard_admission: token
               )

      # … and a new admission of the user is refused now.
      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               Guard.admit("test.limited", user, "turn-2", 300)
    end

    test "an expired token is ignored", %{owner: owner} do
      user = Fixtures.user_fixture().uuid
      assert {:ok, token} = Guard.admit("test.limited", user, "turn", 1)

      # Expire it without waiting: the same entry with a deadline in the past.
      table = PhoenixKitAI.RequestCache.flags_table()
      [{key, {task, ^user, ref, _expires}}] = :ets.lookup(table, {:guard_admission, token})
      :ets.insert(table, {key, {task, user, ref, System.monotonic_time(:millisecond) - 1}})

      refute Guard.admitted?(token, "test.limited", user)
      limit_requests(owner, 0)

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               PhoenixKitAI.ask(endpoint_fixture().uuid, "q",
                 task: "test.limited",
                 user_uuid: user,
                 guard_admission: token
               )
    end

    test "an admitted call is still checked for fitness" do
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid
      {:ok, token} = Guard.admit("test.vision", user, "turn", 300)

      # Nobody knows whether the model sees images; with only verified models
      # allowed that is a refusal, admission or not.
      {:ok, _} =
        PhoenixKit.Settings.update_boolean_setting_with_module(
          Guard.verified_only_setting(),
          true,
          "ai"
        )

      assert {:error, {:model_unverified, [:vision]}} =
               PhoenixKitAI.ask(ep.uuid, "q",
                 task: "test.vision",
                 user_uuid: user,
                 guard_admission: token
               )

      assert [%Request{metadata: %{"refused" => true}}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
    end
  end

  describe "ai.manage" do
    defp changes(scope, owner) do
      user = Fixtures.user_fixture().uuid

      [
        update_settings: fn ->
          TaskLimits.update_settings(scope, "test.limited", %{"limits" => %{}})
        end,
        put_user_limits: fn ->
          TaskLimits.put_user_limits(scope, "test.limited", user, %{"requests" => %{"day" => 1}})
        end,
        delete_user_limits: fn -> TaskLimits.delete_user_limits(scope, "test.limited", user) end,
        forgive: fn -> TaskLimits.forgive(scope, "test.limited", :task, :day, nil) end,
        set_watchers: fn -> GuardEvents.set_watchers(scope, [owner.uuid]) end,
        set_verified_only: fn -> Guard.set_verified_only(scope, false) end
      ]
    end

    test "without it every change is refused, also with only the base permission",
         %{owner: owner} do
      for scope <- [nil, admin_scope([]), admin_scope(["ai"])],
          {name, change} <- changes(scope, owner) do
        assert change.() == {:error, :forbidden}, "#{name} was not refused"
      end

      assert TestRepo.aggregate(GuardEvent, :count) == 0
      refute_activity_logged("guard.watchers_updated")
    end

    test "with it every change is made", %{owner: owner} do
      scope = admin_scope(["ai", "ai.manage"])
      assert Guard.may_manage?(scope)

      for {name, change} <- changes(scope, owner) do
        assert match?({:ok, _}, change.()), "#{name} was refused"
      end
    end

    test "an Owner may always", %{owner: owner} do
      scope = Scope.for_user(owner)
      assert Scope.owner?(scope)

      for {name, change} <- changes(scope, owner) do
        assert match?({:ok, _}, change.()), "#{name} was refused"
      end
    end

    test "the sub-permission is declared on the module" do
      assert %{sub_permissions: [%{key: "manage"}]} = PhoenixKitAI.permission_metadata()
      assert "ai.manage" in Permissions.sub_permission_keys()
    end

    test "changes are written to the Activity log with the actor, as their resource",
         %{owner: owner} do
      scope = Scope.for_user(owner)
      {:ok, setting} = TaskLimits.update_settings(scope, "test.limited", %{"limits" => %{}})

      assert_activity_logged("guard.limits_updated",
        actor_uuid: owner.uuid,
        resource_uuid: setting.uuid
      )

      {:ok, event} = TaskLimits.forgive(scope, "test.limited", :task, :day, nil)

      assert_activity_logged("guard.limit_forgiven",
        actor_uuid: owner.uuid,
        resource_uuid: event.uuid
      )

      {:ok, _} = Guard.set_verified_only(scope, true)
      assert Guard.verified_only?()
      assert_activity_logged("guard.verified_only_changed", actor_uuid: owner.uuid)
    end
  end
end
