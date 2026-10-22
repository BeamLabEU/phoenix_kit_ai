defmodule PhoenixKitAI.GuardBlocksTest do
  @moduledoc """
  Blocks (`PhoenixKitAI.GuardBlocks`): a blocked person's call is refused
  before any HTTP with a refusal row and no usage sink; a block lands on the
  task's block group (`agent.chat` and `ai.playground` share `free_text`);
  a turn admitted before the block runs to its end; who may set and lift a
  block; the events, notices and Activity entries; the per-node cache (a
  call without a block costs no query, a block or a lift is seen at once).
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Guard, GuardBlock, GuardBlocks, GuardEvent, Request, TaskLimits}
  alias PhoenixKitAI.Test.{FakeGuardTasks, FakeUsageSink}
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
    PhoenixKit.Notifications.enable_system()
    :ok = ModuleRegistry.register(PhoenixKitAI)
    :ok = ModuleRegistry.register(FakeGuardTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeGuardTasks)
      ModuleRegistry.unregister(PhoenixKitAI)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    # The first user registered is the Owner.
    owner = Fixtures.user_fixture()
    {:ok, owner: owner, owner_scope: Scope.for_user(owner)}
  end

  defp stub_chat(test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.01}
      })
    end)
  end

  defp endpoint_fixture do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Blocks-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/model",
        api_key: "sk-test-key"
      })

    endpoint
  end

  # A person with a role of their own holding exactly `keys`, as a scope.
  defp scope_with(keys) do
    user = Fixtures.user_fixture()
    {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(user, role.name)
    :ok = Permissions.set_permissions(role.uuid, keys)
    Scope.for_user(user)
  end

  defp admin_scope do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, ["ai", "ai.manage"])
    Scope.for_user(user)
  end

  defp uuid(%Scope{user: user}), do: user.uuid

  defp refused_rows do
    TestRepo.all(from(r in Request, where: fragment("(?->>'refused') = 'true'", r.metadata)))
  end

  defp events(kind), do: TestRepo.all(from(e in GuardEvent, where: e.kind == ^kind))

  defp notifications_of(user_uuid),
    do: TestRepo.all(from(n in Notification, where: n.recipient_uuid == ^user_uuid))

  describe "a block refuses the calls" do
    test "equivalent UUID spellings cannot bypass a block", %{owner_scope: owner} do
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid
      {:ok, block} = Guard.block(owner, "agent.chat", user, "Private reason", nil)

      for identity <- [String.upcase(user), Ecto.UUID.dump!(user)] do
        assert Guard.blocked?("ai.playground", identity)

        assert %GuardBlock{uuid: block_uuid, reason: nil} =
                 GuardBlocks.active("ai.playground", identity)

        assert block_uuid == block.uuid

        assert {:error, {:task_blocked, "free_text"}} =
                 Guard.admit("agent.chat", identity, "turn", 300)
      end

      assert {:error, {:task_blocked, "free_text"}} =
               PhoenixKitAI.ask(ep.uuid, "hi", task: "agent.chat", user_uuid: String.upcase(user))

      refute_received :provider_called
      refute Guard.blocked?("agent.chat", "external-id")
      assert GuardBlocks.active("agent.chat", "external-id") == nil
    end

    test "before HTTP, with a refusal row naming the task and no usage sink", %{
      owner_scope: owner
    } do
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid
      Application.put_env(:phoenix_kit_ai, :fake_usage_sink_pid, self())
      :ok = ModuleRegistry.register(FakeUsageSink)

      on_exit(fn ->
        ModuleRegistry.unregister(FakeUsageSink)
        Application.delete_env(:phoenix_kit_ai, :fake_usage_sink_pid)
      end)

      assert {:ok, %GuardBlock{block_group: "test.flagged"}} =
               Guard.block(owner, "test.flagged", user, "Used it for homework", nil)

      assert Guard.blocked?("test.flagged", user)

      assert {:error, {:task_blocked, "test.flagged"}} =
               PhoenixKitAI.ask(ep.uuid, "hi", task: "test.flagged", user_uuid: user)

      refute_received :provider_called
      refute_received {:usage_sink, _}

      assert [%Request{status: "error", user_uuid: ^user, metadata: metadata} = row] =
               refused_rows()

      assert metadata["task"] == "test.flagged"
      # The refusal names no reason: every holder of `ai` reads the journal.
      refute row.error_message =~ "homework"
      refute metadata["error_reason"] =~ "homework"

      # Other people, other tasks and calls without a user are not blocked.
      other = Fixtures.user_fixture().uuid
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.flagged", user_uuid: other)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.quiet", user_uuid: user)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.flagged")
    end

    test "a block on agent.chat also refuses ai.playground: they share free_text", %{
      owner_scope: owner
    } do
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid

      assert {:ok, %GuardBlock{block_group: "free_text", origin_task_key: "agent.chat"} = block} =
               Guard.block(owner, "agent.chat", user, "Personal use", nil)

      # The group's strictest task is private.
      assert block.private

      assert Guard.blocked?("ai.playground", user)

      assert {:error, {:task_blocked, "free_text"}} =
               PhoenixKitAI.ask(ep.uuid, "hi", task: "ai.playground", user_uuid: user)

      refute_received :provider_called
    end

    test "a block set on the group itself names no origin task", %{owner_scope: owner} do
      user = Fixtures.user_fixture().uuid

      assert {:ok, %GuardBlock{block_group: "free_text", origin_task_key: nil, private: true}} =
               Guard.block(owner, "free_text", user, nil, nil)

      assert Guard.blocked?("agent.chat", user)
      assert {:error, :unknown_task} = Guard.block(owner, "no.such.task", user, nil, nil)
    end

    test "the block remembers the flag it came from", %{owner_scope: owner} do
      user = Fixtures.user_fixture().uuid
      {:ok, flag} = Guard.report_off_purpose("test.flagged", user, "Asked for a poem", "turn-1")

      assert {:ok, %GuardBlock{origin_event_uuid: event_uuid, origin_task_key: "test.flagged"}} =
               Guard.block(owner, "test.flagged", user, "Poems", %{event_uuid: flag.uuid})

      assert event_uuid == flag.uuid

      # A flag of somebody else is not taken as the origin.
      other = Fixtures.user_fixture().uuid

      assert {:ok, %GuardBlock{origin_event_uuid: nil}} =
               Guard.block(owner, "test.flagged", other, nil, %{event_uuid: flag.uuid})
    end

    test "a turn admitted before the block runs to its end; the next one is refused", %{
      owner_scope: owner
    } do
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid

      assert {:ok, token} = Guard.admit("agent.chat", user, "turn-1", 300)
      {:ok, _} = Guard.block(owner, "agent.chat", user, nil, nil)

      opts = [task: "agent.chat", user_uuid: user, guard_admission: token]
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "round 2", opts)
      assert_received :provider_called

      assert {:error, {:task_blocked, "free_text"}} =
               Guard.admit("agent.chat", user, "turn-2", 300)

      assert {:error, {:task_blocked, "free_text"}} =
               PhoenixKitAI.ask(ep.uuid, "next", task: "agent.chat", user_uuid: user)
    end

    test "a process_image dry run skips the block, as it skips the spend caps", %{
      owner_scope: owner
    } do
      # The image model list it reads answers anything; no image call is made.
      stub_chat(self())
      ep = endpoint_fixture()
      user = Fixtures.user_fixture().uuid
      {:ok, _} = Guard.block(owner, "test.flagged", user, nil, nil)

      result =
        PhoenixKitAI.process_image(ep.uuid, ["https://example.com/a.png"], [],
          dry_run: true,
          task: "test.flagged",
          user_uuid: user
        )

      refute match?({:error, {:task_blocked, _}}, result)
    end

    test "a second block of the same group and person is refused; after a lift it is allowed",
         %{owner_scope: owner} do
      user = Fixtures.user_fixture().uuid
      {:ok, block} = Guard.block(owner, "agent.chat", user, nil, nil)

      assert {:error, :already_blocked} = Guard.block(owner, "ai.playground", user, nil, nil)

      {:ok, _} = Guard.unblock(owner, block, "Talked to them")
      refute Guard.blocked?("agent.chat", user)
      assert {:ok, _} = Guard.block(owner, "ai.playground", user, nil, nil)
    end

    test "a reason of long graphemes is cut to 500 code points, whole graphemes only", %{
      owner_scope: owner
    } do
      # One family emoji is one grapheme of 7 code points; the database counts
      # code points.
      family = "👨‍👩‍👧‍👦"
      user = Fixtures.user_fixture().uuid

      assert {:ok, block} =
               Guard.block(owner, "test.flagged", user, String.duplicate(family, 600), nil)

      assert length(String.codepoints(block.reason)) <= 500
      assert block.reason == String.duplicate(family, 71)

      assert {:ok, lifted} = Guard.unblock(owner, block, String.duplicate(family, 600))
      assert lifted.lift_note == String.duplicate(family, 71)
    end

    test "the reason and the note are cut to 500 characters", %{owner_scope: owner} do
      user = Fixtures.user_fixture().uuid
      {:ok, block} = Guard.block(owner, "test.flagged", user, String.duplicate("é", 600), nil)
      assert String.length(block.reason) == 500

      {:ok, lifted} = Guard.unblock(owner, block, String.duplicate("n", 501))
      assert String.length(lifted.lift_note) == 500
    end
  end

  describe "active/2 and active/3" do
    test "active/2 carries no reason or note; active/3 only for whom may see it", %{
      owner_scope: owner
    } do
      user = Fixtures.user_fixture().uuid
      {:ok, _} = Guard.block(owner, "agent.chat", user, "PRIVATE-BLOCK", nil)
      {:ok, _} = Guard.block(owner, "test.flagged", user, "OPEN-BLOCK", nil)

      assert %GuardBlock{reason: nil, lift_note: nil, block_group: "free_text"} =
               GuardBlocks.active("ai.playground", user)

      assert %GuardBlock{reason: nil} = GuardBlocks.active("test.flagged", user)
      assert GuardBlocks.active("test.quiet", user) == nil

      ai_only = scope_with(["ai"])
      assert %GuardBlock{reason: nil} = GuardBlocks.active("agent.chat", user, ai_only)
      assert %GuardBlock{reason: "OPEN-BLOCK"} = GuardBlocks.active("test.flagged", user, ai_only)

      for viewer <- [owner, admin_scope()] do
        assert %GuardBlock{reason: "PRIVATE-BLOCK"} =
                 GuardBlocks.active("agent.chat", user, viewer)
      end
    end
  end

  describe "who may block" do
    test "without ai.manage every action is refused", %{owner_scope: owner} do
      target = Fixtures.user_fixture().uuid
      {:ok, block} = Guard.block(owner, "test.flagged", target, nil, nil)

      for scope <- [nil, scope_with([]), scope_with(["ai"])] do
        other = Fixtures.user_fixture().uuid
        assert {:error, :forbidden} = Guard.block(scope, "test.flagged", other, nil, nil)
        assert {:error, :forbidden} = Guard.unblock(scope, block, nil)
      end

      assert [_] = TestRepo.all(GuardBlock)
      assert Guard.blocked?("test.flagged", target)
    end

    test "a holder of ai.manage blocks and lifts another person's block" do
      admin = admin_scope()
      target = Fixtures.user_fixture().uuid

      assert {:ok, block} = Guard.block(admin, "test.flagged", target, "x", nil)
      assert block.blocked_by_uuid == uuid(admin)

      assert {:ok, lifted} = Guard.unblock(admin, block, "ok")
      assert lifted.lifted_by_uuid == uuid(admin)
      assert lifted.lift_note == "ok"
      refute Guard.blocked?("test.flagged", target)

      assert {:error, :not_blocked} = Guard.unblock(admin, lifted, nil)
    end

    test "an Admin may not block an Owner, nor lift an Owner's block; an Owner may", %{
      owner: first_owner,
      owner_scope: owner
    } do
      admin = admin_scope()

      assert {:error, :owner_only} =
               Guard.block(admin, "test.flagged", first_owner.uuid, nil, nil)

      refute Guard.blocked?("test.flagged", first_owner.uuid)

      # An Owner may block an Owner (here, themself), and lift it.
      assert {:ok, block} = Guard.block(owner, "test.flagged", first_owner.uuid, nil, nil)
      assert {:error, :owner_only} = Guard.unblock(admin, block, nil)
      assert {:ok, _} = Guard.unblock(owner, block, nil)
    end

    test "nobody lifts their own block but an Owner, who keeps a record", %{
      owner: owner_user,
      owner_scope: owner
    } do
      admin = admin_scope()
      {:ok, admin_block} = Guard.block(owner, "test.flagged", uuid(admin), nil, nil)
      assert {:error, :own_block} = Guard.unblock(admin, admin_block, nil)
      assert Guard.blocked?("test.flagged", uuid(admin))

      {:ok, owner_block} = Guard.block(owner, "test.flagged", owner_user.uuid, nil, nil)
      assert {:ok, lifted} = Guard.unblock(owner, owner_block, "My mistake")
      assert lifted.lifted_by_uuid == owner_user.uuid
      assert [%GuardEvent{actor_uuid: actor}] = events("unblocked")
      assert actor == owner_user.uuid
    end

    test "agent.manage lifts another person's free_text block, never its own, and nothing else",
         %{owner_scope: owner} do
      agent_manager = scope_with(["agent", "agent.manage"])
      assert Scope.can?(agent_manager, "agent.manage")
      target = Fixtures.user_fixture().uuid

      {:ok, free_text} = Guard.block(owner, "agent.chat", target, nil, nil)
      {:ok, other_group} = Guard.block(owner, "test.flagged", target, nil, nil)
      {:ok, own} = Guard.block(owner, "agent.chat", uuid(agent_manager), nil, nil)

      assert {:error, :forbidden} = Guard.block(agent_manager, "agent.chat", target, nil, nil)
      assert {:error, :forbidden} = Guard.unblock(agent_manager, other_group, nil)
      assert {:error, :own_block} = Guard.unblock(agent_manager, own, nil)
      assert {:ok, _} = Guard.unblock(agent_manager, free_text, "Back to work")
    end

    test "a block of nobody is refused", %{owner_scope: owner} do
      assert {:error, :unknown_user} =
               Guard.block(owner, "test.flagged", UUIDv7.generate(), nil, nil)

      assert {:error, :invalid_user} = Guard.block(owner, "test.flagged", "not-a-uuid", nil, nil)
    end
  end

  describe "what a block or a lift writes and tells" do
    test "an event, the watchers and the person told, Activity by resource — never the reason",
         %{owner: owner_user, owner_scope: owner} do
      admin = admin_scope()
      target = Fixtures.user_fixture().uuid
      watcher = Fixtures.user_fixture().uuid
      Application.put_env(:phoenix_kit_ai, :fake_guard_watchers, [watcher])
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :fake_guard_watchers) end)

      {:ok, block} = Guard.block(admin, "agent.chat", target, "SECRET-BLOCK-REASON", nil)
      {:ok, _} = Guard.unblock(owner, block, "SECRET-LIFT-NOTE")

      assert [%GuardEvent{user_uuid: ^target, task_key: "agent.chat", reason: nil} = blocked] =
               events("blocked")

      assert blocked.actor_uuid == uuid(admin)
      assert blocked.ref["block_uuid"] == block.uuid
      assert [%GuardEvent{reason: nil} = unblocked] = events("unblocked")
      assert unblocked.actor_uuid == owner_user.uuid

      # The Owner (no watchers configured) of the block only: the lift was
      # theirs. The task's watcher of both; the person once per notice key
      # (the lift replaces the block's notice).
      assert length(notifications_of(owner_user.uuid)) == 1
      assert notifications_of(uuid(admin)) == []
      assert length(notifications_of(watcher)) == 2
      assert [_] = notifications_of(target)

      assert_activity_logged("guard.blocked", resource_uuid: blocked.uuid)
      assert_activity_logged("guard.unblocked", resource_uuid: unblocked.uuid)

      for table <- ~w(phoenix_kit_notifications phoenix_kit_activities) do
        assert [[0]] =
                 TestRepo.query!(
                   "SELECT count(*) FROM #{table} WHERE metadata::text LIKE '%SECRET-%'"
                 ).rows,
               "a reason or note reached #{table}"
      end
    end
  end

  describe "the cache" do
    test "a call without a block costs no query; a block and a lift are seen at once", %{
      owner_scope: owner
    } do
      user = Fixtures.user_fixture().uuid
      spec = PhoenixKitAI.Tasks.get("test.flagged")

      assert :ok = GuardBlocks.check(spec, user)
      assert count_queries(fn -> assert :ok = GuardBlocks.check(spec, user) end) == 0
      assert count_queries(fn -> refute Guard.blocked?("test.flagged", user) end) == 0

      {:ok, block} = Guard.block(owner, "test.flagged", user, nil, nil)
      assert {:error, {:task_blocked, "test.flagged"}} = GuardBlocks.check(spec, user)

      {:ok, _} = Guard.unblock(owner, block, nil)
      assert :ok = GuardBlocks.check(spec, user)
    end

    test "a broadcast from another node drops the cache", %{owner: owner_user} do
      watch = start_supervised!(PhoenixKitAI.GuardWatch)
      user = Fixtures.user_fixture().uuid
      refute Guard.blocked?("test.flagged", user)

      # Written behind the cache's back, as another node would.
      TestRepo.insert!(%GuardBlock{
        block_group: "test.flagged",
        user_uuid: user,
        blocked_by_uuid: owner_user.uuid,
        blocked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      refute Guard.blocked?("test.flagged", user)

      PubSub.broadcast(TaskLimits.topic(), {:guard_blocks_changed, "test.flagged"})
      _ = :sys.get_state(watch)

      assert Guard.blocked?("test.flagged", user)
    end

    test "an entry older than its TTL is read again", %{owner: owner_user} do
      user = Fixtures.user_fixture().uuid
      refute Guard.blocked?("test.flagged", user)

      TestRepo.insert!(%GuardBlock{
        block_group: "test.flagged",
        user_uuid: user,
        blocked_by_uuid: owner_user.uuid,
        blocked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      # Age the entry without waiting.
      table = PhoenixKitAI.RequestCache.flags_table()
      [{key, {generation, loaded_at, entry}}] = :ets.lookup(table, {GuardBlocks, :active})
      aged = loaded_at - GuardBlocks.cache_ttl_ms() - 1
      :ets.insert(table, {key, {generation, aged, entry}})

      assert Guard.blocked?("test.flagged", user)
    end
  end

  defp count_queries(fun) do
    ref = make_ref()
    pid = self()
    handler = "count-queries-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_ai, :test, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(pid, {:query, ref}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count_messages(ref, 0)
  end

  defp count_messages(ref, count) do
    receive do
      {:query, ^ref} -> count_messages(ref, count + 1)
    after
      0 -> count
    end
  end
end
