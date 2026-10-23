defmodule PhoenixKitAI.GuardOffPurposeTest do
  @moduledoc """
  Off-purpose flags the consumer reports (`PhoenixKitAI.Guard.report_off_purpose/4`):
  one per turn or call, the watchers told once a day per person and task,
  never with the reason; `self_flag?/1` and the instruction text; who sees
  a flag's reason; and the anomaly rules a task declares (`sources`,
  `max_calls_per_hour`, `max_tokens_per_call`), each signalled at most once
  a day.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Guard, GuardEvent, GuardEvents, Tasks, TaskSetting}
  alias PhoenixKitAI.Test.FakeGuardTasks
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
      Application.delete_env(:phoenix_kit_ai, :fake_guard_watchers)
    end)

    owner = Fixtures.user_fixture()
    {:ok, owner: owner}
  end

  defp events(kind),
    do: TestRepo.all(from(e in GuardEvent, where: e.kind == ^kind, order_by: e.inserted_at))

  defp notifications_of(user_uuid),
    do: TestRepo.all(from(n in Notification, where: n.recipient_uuid == ^user_uuid))

  defp scope_with(keys) do
    user = Fixtures.user_fixture()
    {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(user, role.name)
    :ok = Permissions.set_permissions(role.uuid, keys)
    Scope.for_user(user)
  end

  defp set_mode(task_key, mode) do
    TestRepo.insert!(%TaskSetting{task_key: task_key, guard_mode: mode, limits: %{}})
    PhoenixKitAI.TaskLimits.forget(task_key)
  end

  defp stub_chat(tokens) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => tokens, "completion_tokens" => 0, "cost" => 0.0}
      })
    end)
  end

  defp endpoint_fixture do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Flags-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/model",
        api_key: "sk-test-key"
      })

    endpoint
  end

  describe "report_off_purpose/4" do
    test "one flag per turn: a second report on the same turn is not written" do
      user = Fixtures.user_fixture().uuid

      assert {:ok, %GuardEvent{kind: "off_purpose"} = event} =
               Guard.report_off_purpose("agent.chat", user, "Asked for a recipe", %{
                 turn_ref: "turn-1"
               })

      assert event.dedupe_key == "off_purpose:agent.chat:#{user}:turn-1"
      assert event.ref == %{"turn_ref" => "turn-1"}
      assert event.reason == "Asked for a recipe"

      assert :duplicate =
               Guard.report_off_purpose("agent.chat", user, "Again", %{"turn_ref" => "turn-1"})

      # Forgotten on this node, the database still keeps it to one.
      GuardEvents.reset_sent()

      assert :duplicate =
               Guard.report_off_purpose("agent.chat", user, "Again", %{turn_ref: "turn-1"})

      assert {:ok, _} =
               Guard.report_off_purpose("agent.chat", user, "Other", %{turn_ref: "turn-2"})

      assert length(events("off_purpose")) == 2
    end

    test "the reason is kept only while request content is captured" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :capture_request_content) end)

      user = Fixtures.user_fixture().uuid

      assert {:ok, %GuardEvent{kind: "off_purpose", reason: nil}} =
               Guard.report_off_purpose("agent.chat", user, "SECRET-FLAG-REASON", "turn-1")

      assert [%GuardEvent{reason: nil}] = events("off_purpose")
    end

    test "one flag per call, by the journal row; the row is linked" do
      user = Fixtures.user_fixture().uuid
      stub_chat(10)
      ep = endpoint_fixture()

      {:ok, response} =
        PhoenixKitAI.ask(ep.uuid, "write me a poem", task: "test.flagged", user_uuid: user)

      request_uuid = response["request_uuid"]

      assert {:ok, %GuardEvent{request_uuid: ^request_uuid}} =
               Guard.report_off_purpose("test.flagged", user, "A poem", request_uuid)

      assert :duplicate = Guard.report_off_purpose("test.flagged", user, "A poem", request_uuid)

      # A request uuid of no row is kept in the ref, not as a link.
      missing = UUIDv7.generate()

      assert {:ok, %GuardEvent{request_uuid: nil, ref: %{"request_uuid" => ^missing}}} =
               Guard.report_off_purpose("test.flagged", user, "x", missing)
    end

    test "the watchers are told once a day per person and task, without the reason", %{
      owner: owner
    } do
      user = Fixtures.user_fixture().uuid
      watcher = Fixtures.user_fixture().uuid
      Application.put_env(:phoenix_kit_ai, :fake_guard_watchers, [watcher])

      for turn <- ~w(t1 t2 t3) do
        {:ok, _} = Guard.report_off_purpose("agent.chat", user, "SECRET-FLAG-REASON", turn)
      end

      day = PhoenixKitAI.TaskLimits.period_keys().day

      assert [%GuardEvent{reason: nil, user_uuid: ^user, dedupe_key: key} = signal] =
               events("off_purpose_signal")

      assert key == "off_purpose_signal:agent.chat:#{user}:#{day}"
      assert signal.ref["event_uuid"] == hd(events("off_purpose")).uuid

      assert [%Notification{metadata: %{"notification_text" => text}}] =
               notifications_of(owner.uuid)

      refute text =~ "SECRET"
      assert [_] = notifications_of(watcher)
      # The person themself is not told.
      assert notifications_of(user) == []

      # Another person, the same day: a signal of their own.
      other = Fixtures.user_fixture().uuid
      {:ok, _} = Guard.report_off_purpose("agent.chat", other, "SECRET-FLAG-REASON", "t9")
      assert length(events("off_purpose_signal")) == 2

      assert_activity_logged("guard.off_purpose_signal", resource_uuid: signal.uuid)

      for table <- ~w(phoenix_kit_notifications phoenix_kit_activities) do
        assert [[0]] =
                 TestRepo.query!(
                   "SELECT count(*) FROM #{table} WHERE metadata::text LIKE '%SECRET%'"
                 ).rows
      end
    end

    test "a reason of long graphemes is written, cut to 500 code points" do
      family = "👨‍👩‍👧‍👦"
      user = Fixtures.user_fixture().uuid

      assert {:ok, event} =
               Guard.report_off_purpose("test.flagged", user, String.duplicate(family, 600), "e")

      assert event.reason == String.duplicate(family, 71)
      assert [_] = events("off_purpose")
    end

    test "the reason is cut to 500 characters" do
      user = Fixtures.user_fixture().uuid

      {:ok, event} =
        Guard.report_off_purpose("test.flagged", user, String.duplicate("ü", 700), "c")

      assert String.length(event.reason) == 500
    end

    test "nothing is written for a task that does not self-flag, or whose guard mode turned it off" do
      user = Fixtures.user_fixture().uuid
      assert :off = Guard.report_off_purpose("test.quiet", user, "x", "r1")

      set_mode("test.flagged", "classifier")
      assert :off = Guard.report_off_purpose("test.flagged", user, "x", "r2")

      assert {:error, :unknown_task} = Guard.report_off_purpose("no.such", user, "x", "r3")
      assert {:error, :invalid_ref} = Guard.report_off_purpose("agent.chat", user, "x", %{})
      assert {:error, :invalid_ref} = Guard.report_off_purpose("agent.chat", user, "x", "")

      assert {:error, :invalid_ref} =
               Guard.report_off_purpose("agent.chat", user, "x", %{
                 turn_ref: String.duplicate("t", 256)
               })

      assert events("off_purpose") == []
    end

    test "a person who does not exist is refused, not raised" do
      assert {:error, :unknown_user} =
               Guard.report_off_purpose("agent.chat", UUIDv7.generate(), "x", "t")

      assert {:error, :invalid_user} = Guard.report_off_purpose("agent.chat", "bad", "x", "t")
    end
  end

  describe "setting the guard mode" do
    test "needs ai.manage; off and on are seen at once and written to Activity", %{owner: owner} do
      for scope <- [nil, scope_with([]), scope_with(["ai"])] do
        assert {:error, :forbidden} =
                 PhoenixKitAI.TaskLimits.set_guard_mode(scope, "agent.chat", "off")
      end

      assert Guard.self_flag?("agent.chat")
      manager = scope_with(["ai", "ai.manage"])

      assert {:ok, %TaskSetting{guard_mode: "off"} = setting} =
               PhoenixKitAI.TaskLimits.set_guard_mode(manager, "agent.chat", "off")

      refute Guard.self_flag?("agent.chat")
      assert :off = Guard.report_off_purpose("agent.chat", owner.uuid, "x", "t-off")

      assert_activity_logged("guard.mode_updated",
        resource_uuid: setting.uuid,
        actor_uuid: manager.user.uuid,
        metadata_has: %{"task" => "agent.chat", "guard_mode" => "off", "guard_mode_before" => nil}
      )

      # The Owner turns it on for a task whose declaration says no.
      assert {:ok, _} =
               PhoenixKitAI.TaskLimits.set_guard_mode(
                 Scope.for_user(owner),
                 "test.quiet",
                 "self_flag"
               )

      assert Guard.self_flag?("test.quiet")
    end

    test "only off and self_flag; a task nobody declares is refused", %{owner: owner} do
      scope = Scope.for_user(owner)

      assert {:error, :invalid_mode} =
               PhoenixKitAI.TaskLimits.set_guard_mode(scope, "agent.chat", "classifier")

      assert {:error, :invalid_mode} =
               PhoenixKitAI.TaskLimits.set_guard_mode(scope, "agent.chat", "loud")

      assert {:error, :unknown_task} =
               PhoenixKitAI.TaskLimits.set_guard_mode(scope, "no.such", "off")

      assert Guard.self_flag?("agent.chat")
    end

    test "the limits stay as they were", %{owner: owner} do
      scope = Scope.for_user(owner)

      {:ok, before} =
        PhoenixKitAI.TaskLimits.update_settings(scope, "agent.chat", %{
          "limits" => %{"task" => %{"requests" => %{"day" => "7"}}},
          "warn_percent" => "50"
        })

      {:ok, setting} = PhoenixKitAI.TaskLimits.set_guard_mode(scope, "agent.chat", "off")
      assert setting.uuid == before.uuid
      assert setting.limits == before.limits
      assert get_in(setting.limits, ["task", "requests", "day"]) == 7
      assert setting.warn_percent == 50
    end
  end

  describe "self_flag?/1 and self_flag_instruction/1" do
    test "the guard mode decides; without one, the declaration" do
      assert Guard.self_flag?("agent.chat")
      refute Guard.self_flag?("test.quiet")
      refute Guard.self_flag?("no.such")

      set_mode("agent.chat", "off")
      refute Guard.self_flag?("agent.chat")

      set_mode("test.quiet", "self_flag+classifier")
      assert Guard.self_flag?(Tasks.get("test.quiet"))
    end

    test "the instruction names the purpose and the three rules" do
      text = Guard.self_flag_instruction("agent.chat")

      assert text =~ "Answer questions about the company's orders and products."
      assert text =~ "politely refuse"
      assert text =~ "flag"
      assert text =~ "only the user's own message"
      assert text =~ "tool results"
      assert text =~ "without quoting the user"
      assert Guard.self_flag_instruction("no.such") == nil
    end

    test "an admin's purpose override is what the instruction names" do
      TestRepo.insert!(%TaskSetting{
        task_key: "test.flagged",
        purpose_override: "Count pallets only.",
        limits: %{}
      })

      PhoenixKitAI.TaskLimits.forget("test.flagged")
      assert Guard.self_flag_instruction("test.flagged") =~ "Count pallets only."
    end
  end

  describe "who sees a flag's reason" do
    setup do
      user = Fixtures.user_fixture().uuid
      {:ok, _} = Guard.report_off_purpose("test.private", user, "PRIVATE-REASON", "p1")
      {:ok, _} = Guard.report_off_purpose("test.flagged", user, "OPEN-REASON", "o1")
      {:ok, user: user}
    end

    test "a private reason is hidden from a holder of ai without ai.manage", %{user: user} do
      viewer = scope_with(["ai"])

      assert %{flags: [flag], counts: [{^user, 1}]} =
               GuardEvents.flags(Tasks.get("test.private"), viewer)

      assert flag.reason == nil
      assert flag.request_uuid == nil
      assert flag.hidden
      assert flag.user_uuid == user

      # A task that is not private shows its reasons to every holder of ai.
      assert %{flags: [%{reason: "OPEN-REASON", hidden: false}]} =
               GuardEvents.flags(Tasks.get("test.flagged"), viewer)
    end

    test "a holder of ai.manage and an Owner see it", %{owner: owner} do
      for viewer <- [scope_with(["ai", "ai.manage"]), Scope.for_user(owner)] do
        assert %{flags: [%{reason: "PRIVATE-REASON", hidden: false}]} =
                 GuardEvents.flags(Tasks.get("test.private"), viewer)
      end
    end
  end

  describe "anomaly rules" do
    setup do
      stub_chat(10)
      {:ok, endpoint: endpoint_fixture(), user: Fixtures.user_fixture().uuid}
    end

    test "a call from a source the task does not list is an anomaly, once a day", %{
      endpoint: ep,
      owner: owner
    } do
      # Without a user, so the hourly count (a per-person rule) stays out of it.
      opts = [task: "test.rules", source: "Other.Caller"]
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", opts)
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "b", opts)
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "c", Keyword.put(opts, :source, "Allowed.Caller.run"))

      day = PhoenixKitAI.TaskLimits.period_keys().day

      assert [%GuardEvent{dedupe_key: key, ref: %{"rule" => "source"}}] = events("anomaly")
      assert key == "anomaly:test.rules:-:source:#{day}"
      assert [_] = notifications_of(owner.uuid)
    end

    test "more calls in an hour than the task allows is one anomaly", %{endpoint: ep, user: user} do
      opts = [task: "test.rules", user_uuid: user, source: "Allowed.Caller"]
      for n <- 1..2, do: {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q#{n}", opts)
      assert events("anomaly") == []

      for n <- 3..5, do: {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q#{n}", opts)

      assert [%GuardEvent{ref: %{"rule" => "calls_per_hour", "limit" => 2, "value" => 3}}] =
               events("anomaly")
    end

    test "a call over the token norm is one anomaly a day", %{endpoint: ep, user: user} do
      stub_chat(500)
      opts = [task: "test.rules", user_uuid: user, source: "Allowed.Caller"]
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "big", opts)
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "big again", opts)

      assert [%GuardEvent{ref: %{"rule" => "tokens_per_call", "value" => 500, "limit" => 100}}] =
               events("anomaly")
    end

    test "a refused call is no anomaly and no call", %{endpoint: ep, user: user, owner: owner} do
      {:ok, _} = Guard.block(Scope.for_user(owner), "test.rules", user, nil, nil)
      opts = [task: "test.rules", user_uuid: user, source: "Other.Caller"]

      for n <- 1..4 do
        assert {:error, {:task_blocked, _}} = PhoenixKitAI.ask(ep.uuid, "q#{n}", opts)
      end

      assert events("anomaly") == []
    end

    test "a task without rules costs no query after its row", %{endpoint: ep, user: user} do
      request = %PhoenixKitAI.Request{
        uuid: UUIDv7.generate(),
        user_uuid: user,
        total_tokens: 1_000_000,
        metadata: %{task: "test.flagged", source: "Anything"}
      }

      assert count_queries(fn -> Guard.check_anomalies(request) end) == 0
      {:ok, _} = PhoenixKitAI.ask(ep.uuid, "x", task: "test.flagged", user_uuid: user)
      assert events("anomaly") == []
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
