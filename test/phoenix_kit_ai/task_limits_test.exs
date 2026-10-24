defmodule PhoenixKitAI.TaskLimitsTest do
  @moduledoc """
  The task limits (`PhoenixKitAI.TaskLimits`): calendar windows in the site
  time zone, which limit is in force, what is counted from the journal, the
  refusal before HTTP with its row, forgiving, and the signals with their
  dedupe (`PhoenixKitAI.GuardEvents`). Provider calls are `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{GuardEvent, GuardEvents, Request, TaskLimits, Tasks}
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

    {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "3")
    PhoenixKit.Notifications.enable_system()

    :ok = ModuleRegistry.register(FakeLimitTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeLimitTasks)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :fake_limit_watchers)
      Application.delete_env(:phoenix_kit_ai, :fake_limit_watchers_pid)
    end)

    # The first user registered is the Owner; the people of a test come after.
    owner = Fixtures.user_fixture()

    {:ok, owner: owner, endpoint: endpoint_fixture()}
  end

  defp endpoint_fixture do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Limits-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/model",
        api_key: "sk-test-key"
      })

    endpoint
  end

  defp stub_chat(test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.5}
      })
    end)
  end

  defp spec(key \\ "test.limited"), do: Tasks.get(key)

  defp owner_scope(owner), do: Scope.for_user(owner)

  # A journal row of a task, at a given time.
  defp row(endpoint, at, attrs \\ %{}) do
    attrs = Map.new(attrs)
    task = Map.get(attrs, :task, "test.limited")

    metadata =
      %{"task" => task}
      |> Map.merge(Map.get(attrs, :metadata, %{}))

    %Request{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: Map.get(attrs, :status, "success"),
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: Map.get(attrs, :tokens, 10),
      # `:cost` is dollars (a string), the unit of the journal and of a limit
      cost: attrs |> Map.get(:cost, "0.001") |> Decimal.new(),
      latency_ms: 1,
      user_uuid: Map.get(attrs, :user_uuid),
      metadata: metadata,
      inserted_at: at,
      updated_at: at
    }
    |> TestRepo.insert!()
  end

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  defp set_limits(owner, limits, extra \\ %{}) do
    {:ok, _} =
      TaskLimits.update_settings(
        owner_scope(owner),
        "test.limited",
        Map.merge(%{"limits" => limits}, extra)
      )
  end

  defp events(kind) do
    TestRepo.all(from(e in GuardEvent, where: e.kind == ^kind, order_by: e.inserted_at))
  end

  # The SQL the test repo runs inside `fun`.
  defp queries(fun) do
    test_pid = self()
    handler = "limits-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_ai, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config -> send(test_pid, {:sql, query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_sql([])
  end

  defp collect_sql(acc) do
    receive do
      {:sql, query} -> collect_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event_inserts(sql),
    do: Enum.filter(sql, &(&1 =~ ~s(INSERT INTO "phoenix_kit_ai_guard_events")))

  # Simulate another writer inserting after this call's SELECT returned no row.
  defp insert_after_read(row, fun) do
    handler = "limits-race-#{System.unique_integer([:positive])}"
    table = row.__struct__.__schema__(:source)
    caller = self()

    :telemetry.attach(
      handler,
      [:phoenix_kit_ai, :test, :repo, :query],
      fn
        _event, _measurements, %{query: query}, _config ->
          if self() == caller and String.starts_with?(query, "SELECT") and
               String.contains?(query, ~s(FROM "#{table}")) do
            :telemetry.detach(handler)
            TestRepo.insert!(row)
          end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end
  end

  defp activities(action) do
    TestRepo.all(
      from(a in "phoenix_kit_activities",
        where: a.action == ^action,
        order_by: [asc: a.inserted_at, asc: a.uuid],
        select: a.metadata
      )
    )
  end

  defp notifications_of(user_uuid) do
    TestRepo.all(from(n in Notification, where: n.recipient_uuid == ^user_uuid))
  end

  describe "calendar windows in the site time zone" do
    test "the day turns at local midnight, not at UTC midnight", %{endpoint: ep} do
      # Site zone UTC+3: 21:30Z on the 21st is 00:30 on the 22nd.
      now = ~U[2026-10-21 21:30:00Z]

      assert %{day: {~U[2026-10-21 21:00:00Z], ~U[2026-10-22 21:00:00Z]}} =
               TaskLimits.windows(now)

      assert TaskLimits.period_keys(now) == %{day: "2026-10-22", month: "2026-10"}

      row(ep, ~U[2026-10-21 20:59:59Z])
      row(ep, ~U[2026-10-21 21:00:00Z])

      usage = TaskLimits.usage("test.limited", nil, now)
      assert usage.task.requests == %{day: 1, month: 2}
    end

    test "the month turns at local midnight of the first", %{endpoint: ep} do
      # 21:30Z on October 31 is 00:30 on November 1 in UTC+3.
      now = ~U[2026-10-31 21:30:00Z]

      assert %{month: {~U[2026-10-31 21:00:00Z], ~U[2026-11-30 21:00:00Z]}} =
               TaskLimits.windows(now)

      assert TaskLimits.period_keys(now) == %{day: "2026-11-01", month: "2026-11"}

      row(ep, ~U[2026-10-31 20:00:00Z], cost: "7", tokens: 3)
      row(ep, ~U[2026-10-31 21:10:00Z], cost: "11", tokens: 5)

      usage = TaskLimits.usage("test.limited", nil, now)
      assert dollars?(usage.task.money.day, "11") and dollars?(usage.task.money.month, "11")
      assert usage.task.tokens == %{day: 5, month: 5}
    end

    test "money is the dollar sum, never rounded, so calls under a micro-dollar count",
         %{endpoint: ep} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      for _ <- 1..3, do: row(ep, now, cost: "0.0000006")

      # 3 × $0.0000006 = $0.0000018, which whole micro-dollars would make 2 µ$.
      assert dollars?(TaskLimits.usage("test.limited", nil, now).task.money.day, "0.0000018")
    end
  end

  describe "a day with a clock change" do
    test "the local day of a DST switch is 25 hours long" do
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "Europe/Tallinn")
      # Clocks go back from 04:00 EEST to 03:00 EET on 2026-10-25.
      %{day: {from, to}} = TaskLimits.windows(~U[2026-10-25 12:00:00Z])

      assert from == ~U[2026-10-24 21:00:00Z]
      assert to == ~U[2026-10-25 22:00:00Z]
      assert DateTime.diff(to, from, :hour) == 25
    end
  end

  describe "which limit is in force" do
    test "personal > the task's default for users > the declaration", %{owner: owner} do
      alice = Fixtures.user_fixture().uuid
      bob = Fixtures.user_fixture().uuid

      # Only the declaration: users 5 requests a day, the task 1M tokens a month.
      assert %{task: %{tokens: %{month: 1_000_000}}, user: %{requests: %{day: 5}}} =
               TaskLimits.effective(spec(), alice)

      set_limits(owner, %{"user" => %{"requests" => %{"day" => "3"}}})
      assert %{user: %{requests: %{day: 3}}} = TaskLimits.effective(spec(), bob)

      {:ok, _} =
        TaskLimits.put_user_limits(owner_scope(owner), "test.limited", alice, %{
          "requests" => %{"day" => "1"},
          "tokens" => %{"month" => "50"}
        })

      assert %{user: %{requests: %{day: 1}, tokens: %{month: 50}}} =
               TaskLimits.effective(spec(), alice)

      # A cell the exception leaves empty falls through to the default.
      {:ok, _} =
        TaskLimits.put_user_limits(owner_scope(owner), "test.limited", alice, %{
          "tokens" => %{"month" => "50"}
        })

      assert %{user: %{requests: %{day: 3}, tokens: %{month: 50}}} =
               TaskLimits.effective(spec(), alice)

      # The task's own limit keeps the declaration's cell it does not set.
      assert %{task: %{tokens: %{month: 1_000_000}}} = TaskLimits.effective(spec(), alice)
      # Without a user there is no user scope.
      assert %{user: %{}} = TaskLimits.effective(spec(), nil)
    end

    test "an empty limit is no limit", %{owner: owner} do
      set_limits(owner, %{"task" => %{"requests" => %{"day" => ""}}})
      assert TaskLimits.effective(spec("test.unlimited"), nil) == %{task: %{}, user: %{}}
      assert :ok = TaskLimits.check(spec("test.unlimited"), [])
    end
  end

  describe "the call-time check" do
    test "competing first saves return changeset errors instead of raising", %{owner: owner} do
      scope = owner_scope(owner)

      assert {:error, changeset} =
               insert_after_read(
                 %PhoenixKitAI.TaskSetting{task_key: "test.limited"},
                 fn -> TaskLimits.update_settings(scope, "test.limited", %{}) end
               )

      assert {"has already been taken", _} = changeset.errors[:task_key]

      user = Fixtures.user_fixture().uuid

      assert {:error, changeset} =
               insert_after_read(
                 %PhoenixKitAI.TaskUserLimit{task_key: "test.limited", user_uuid: user},
                 fn ->
                   TaskLimits.put_user_limits(scope, "test.limited", user, %{
                     "requests" => %{"day" => 2}
                   })
                 end
               )

      assert {"has already been taken", _} = changeset.errors[:task_key]
    end

    test "a limit of 0 refuses the first call, before HTTP, with a refusal row",
         %{owner: owner, endpoint: ep} do
      stub_chat(self())
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "0"}}})

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               PhoenixKitAI.ask(ep.uuid, "q", task: "test.limited")

      refute_received :provider_called

      assert [%Request{status: "error", metadata: %{"refused" => true, "task" => "test.limited"}}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
    end

    test "the limit lets calls through until it is reached", %{owner: owner, endpoint: ep} do
      stub_chat(self())
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"user" => %{"requests" => %{"day" => "2"}}})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1", task: "test.limited", user_uuid: user)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2", task: "test.limited", user_uuid: user)

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               PhoenixKitAI.ask(ep.uuid, "q3", task: "test.limited", user_uuid: user)

      # Another user of the task is not held back by it.
      other = Fixtures.user_fixture().uuid
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1", task: "test.limited", user_uuid: other)
    end

    test "a refused row and a failed call are never counted", %{endpoint: ep} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row(ep, now, status: "error", metadata: %{"refused" => true})
      row(ep, now, status: "error")

      assert %{task: %{requests: %{day: 0, month: 0}, money: %{day: money}}} =
               TaskLimits.usage("test.limited", nil, now)

      assert dollars?(money, "0")
    end

    test "a cache hit counts as one request and no money or tokens",
         %{owner: owner, endpoint: ep} do
      stub_chat(self())
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"user" => %{"requests" => %{"day" => "2"}}})
      opts = [task: "test.limited", user_uuid: user, cache: true]

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", opts)
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", opts)
      refute_received :provider_called

      usage = TaskLimits.usage("test.limited", user, DateTime.utc_now())
      assert usage.user.requests.day == 2
      assert dollars?(usage.user.money.day, "0.5")
      assert usage.user.tokens.day == 12

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               PhoenixKitAI.ask(ep.uuid, "same", opts)
    end

    test "an id that is no PhoenixKit user does not switch the task's limits off",
         %{owner: owner, endpoint: ep} do
      # `user_uuid:` may carry a visitor's own id; the journal can only hold
      # a user's uuid, so such a call is held to the task's limits alone.
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "1"}}})
      row(ep, DateTime.utc_now() |> DateTime.truncate(:second))

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec(), user_uuid: "visitor-42")

      assert %{task: %{requests: %{day: 1}}, user: nil} =
               TaskLimits.usage("test.limited", "visitor-42")

      assert [%{scope: :task} | _] = TaskLimits.statuses(spec(), "visitor-42")
    end

    test "a dry run of process_image is not checked against the limits" do
      # The dry run is the one verb that skips the caps; the limits follow it.
      assert TaskLimits.check(nil, []) == :ok
    end
  end

  describe "money limits in dollars" do
    test "a dollar limit is stored as a dollar string and holds against the cost sum",
         %{owner: owner, endpoint: ep} do
      set_limits(owner, %{"task" => %{"money" => %{"day" => "0.001", "month" => "1.5"}}})

      assert %PhoenixKitAI.TaskSetting{
               limits: %{"task" => %{"money" => %{"day" => "0.001", "month" => "1.50"}}}
             } = TestRepo.get_by!(PhoenixKitAI.TaskSetting, task_key: "test.limited")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row(ep, now, cost: "0.0006")
      assert :ok = TaskLimits.check(spec(), [])

      row(ep, now, cost: "0.0006")

      assert {:error, {:task_limit_exceeded, :task, :money, :day}} =
               TaskLimits.check(spec(), [])

      assert [%{unit: :money, period: :day, used: used, limit: limit} | _] =
               spec() |> TaskLimits.statuses(nil) |> Enum.filter(&(&1.period == :day))

      assert dollars?(used, "0.0012") and dollars?(limit, "0.001")
    end

    test "a stored money cell in the released millionths refuses the task's calls",
         %{endpoint: ep} do
      stub_chat(self())

      for legacy <- [1_500_000, "1500000"] do
        TestRepo.delete_all(PhoenixKitAI.TaskSetting)

        TestRepo.insert!(%PhoenixKitAI.TaskSetting{
          task_key: "test.unlimited",
          limits: %{"task" => %{"money" => %{"day" => legacy}}}
        })

        TaskLimits.forget("test.unlimited")

        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:task_limit_unmigrated, "test.unlimited"}} =
                   TaskLimits.check(spec("test.unlimited"), [])

          assert {:error, {:task_limit_unmigrated, "test.unlimited"}} =
                   PhoenixKitAI.ask(ep.uuid, "q #{inspect(legacy)}", task: "test.unlimited")
        end)

        refute_received :provider_called
      end

      assert PhoenixKitAI.Errors.message({:task_limit_unmigrated, "test.unlimited"}) =~
               "update"
    end

    # The unit check comes before any query: `check/3` rescues a failing usage
    # read into `:ok`, which must not let a millionths limit through.
    test "a millionths limit refuses even when the usage read would fail" do
      TestRepo.delete_all(PhoenixKitAI.TaskSetting)

      TestRepo.insert!(%PhoenixKitAI.TaskSetting{
        task_key: "test.unlimited",
        limits: %{"task" => %{"money" => %{"day" => 1_500_000}}}
      })

      TaskLimits.forget("test.unlimited")
      TestRepo.query!("ALTER TABLE phoenix_kit_ai_requests RENAME COLUMN cost TO cost_hidden")

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:task_limit_unmigrated, "test.unlimited"}} =
                 TaskLimits.check(spec("test.unlimited"), [])
      end)
    end

    test "a declared money default in integer millionths refuses too" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:task_limit_unmigrated, "test.legacy_money"}} =
                   TaskLimits.check(spec("test.legacy_money"), [])
        end)

      assert log =~ "millionths"
    end

    test "zero dollars allows nothing, in either shape" do
      for zero <- [0, "0", "0.00"] do
        limits = TaskLimits.normalize(%{"money" => %{"day" => zero}})
        assert dollars?(limits.money.day, "0"), inspect(zero)
      end
    end
  end

  describe "what a call costs the database" do
    test "a task without limits makes no query once its settings are cached" do
      user = Fixtures.user_fixture().uuid
      assert :ok = TaskLimits.check(spec("test.unlimited"), user_uuid: user)

      assert queries(fn ->
               assert :ok = TaskLimits.check(spec("test.unlimited"), user_uuid: user)
               assert :ok = TaskLimits.check(spec("test.unlimited"), [])
             end) == []
    end

    test "a change through the context is seen at once", %{owner: owner} do
      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      {:ok, _} =
        TaskLimits.update_settings(owner_scope(owner), "test.unlimited", %{
          "limits" => %{"task" => %{"requests" => %{"day" => "0"}}}
        })

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec("test.unlimited"), [])

      user = Fixtures.user_fixture().uuid
      assert :ok = TaskLimits.check(spec("test.limited"), user_uuid: user)

      {:ok, _} =
        TaskLimits.put_user_limits(owner_scope(owner), "test.limited", user, %{
          "requests" => %{"day" => "0"}
        })

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               TaskLimits.check(spec("test.limited"), user_uuid: user)

      {:ok, :deleted} = TaskLimits.delete_user_limits(owner_scope(owner), "test.limited", user)
      assert :ok = TaskLimits.check(spec("test.limited"), user_uuid: user)
    end

    test "a change on another node reaches this one's cache through PubSub" do
      watch = start_supervised!(PhoenixKitAI.GuardWatch)
      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      # Written by another node: the row is there, only its broadcast arrives here.
      TestRepo.insert!(%PhoenixKitAI.TaskSetting{
        task_key: "test.unlimited",
        limits: %{"task" => %{"requests" => %{"day" => 0}}}
      })

      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      PubSub.broadcast(
        TaskLimits.topic(),
        {:task_limits_changed, "test.unlimited"}
      )

      _ = :sys.get_state(watch)

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec("test.unlimited"), [])
    end

    test "a cached entry older than its time to live is read again from the database" do
      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      # Written where no broadcast reaches this node.
      TestRepo.insert!(%PhoenixKitAI.TaskSetting{
        task_key: "test.unlimited",
        limits: %{"task" => %{"requests" => %{"day" => 0}}}
      })

      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      # Age the entry past the TTL without waiting.
      table = PhoenixKitAI.RequestCache.flags_table()
      key = {TaskLimits, :limits, "test.unlimited"}
      [{^key, {generation, loaded_at, entry}}] = :ets.lookup(table, key)
      :ets.insert(table, {key, {generation, loaded_at - TaskLimits.cache_ttl_ms() - 1, entry}})

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec("test.unlimited"), [])
    end

    test "a restarted watch starts this node's cache afresh (a broadcast may have been missed)" do
      assert :ok = TaskLimits.check(spec("test.unlimited"), [])

      TestRepo.insert!(%PhoenixKitAI.TaskSetting{
        task_key: "test.unlimited",
        limits: %{"task" => %{"requests" => %{"day" => 0}}}
      })

      assert :ok = TaskLimits.check(spec("test.unlimited"), [])
      watch = start_supervised!(PhoenixKitAI.GuardWatch)
      _ = :sys.get_state(watch)

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               TaskLimits.check(spec("test.unlimited"), [])
    end

    test "past the warn percent, only the first crossing writes an event", %{
      owner: owner,
      endpoint: ep
    } do
      set_limits(owner, %{"task" => %{"requests" => %{"month" => "10"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      for _ <- 1..9, do: row(ep, now)

      assert [_] =
               event_inserts(queries(fn -> assert :ok = TaskLimits.check(spec(), [], now) end))

      for _ <- 1..3 do
        assert event_inserts(queries(fn -> assert :ok = TaskLimits.check(spec(), [], now) end)) ==
                 []
      end

      assert [_] = events("limit_warning")
    end

    test "a limit reached again in its window writes no second event", %{
      owner: owner,
      endpoint: ep
    } do
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "1"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row(ep, now)

      assert [_] = event_inserts(queries(fn -> TaskLimits.check(spec(), [], now) end))
      assert event_inserts(queries(fn -> TaskLimits.check(spec(), [], now) end)) == []
    end
  end

  describe "forgiving a limit" do
    test "warning and reached signals are re-armed after forgiving", %{owner: owner, endpoint: ep} do
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"user" => %{"requests" => %{"day" => "5"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..4, do: row(ep, DateTime.add(now, -120), user_uuid: user)
      assert :ok = TaskLimits.check(spec(), [user_uuid: user], now)
      row(ep, DateTime.add(now, -120), user_uuid: user)
      assert {:error, _} = TaskLimits.check(spec(), [user_uuid: user], now)

      assert {:ok, _} =
               TaskLimits.forgive(
                 owner_scope(owner),
                 "test.limited",
                 :user,
                 :day,
                 user,
                 DateTime.add(now, -60)
               )

      for _ <- 1..4, do: row(ep, DateTime.add(now, -30), user_uuid: user)
      assert :ok = TaskLimits.check(spec(), [user_uuid: user], now)
      row(ep, DateTime.add(now, -30), user_uuid: user)
      assert {:error, _} = TaskLimits.check(spec(), [user_uuid: user], now)
      assert {:error, _} = TaskLimits.check(spec(), [user_uuid: user], now)

      assert length(events("limit_warning")) == 2
      assert length(events("limit_reached")) == 2
      assert length(GuardEvents.reached_users("test.limited", now)) == 2
      assert length(notifications_of(owner.uuid)) == 2
      # One in-app notice is updated, rather than duplicated, for the user.
      assert [_] = notifications_of(user)
    end

    test "counting starts again from the moment of forgiving, to the end of the window",
         %{owner: owner, endpoint: ep} do
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"user" => %{"requests" => %{"day" => "2"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      before = DateTime.add(now, -120)

      row(ep, before, user_uuid: user)
      row(ep, before, user_uuid: user)

      assert {:error, {:task_limit_exceeded, :user, :requests, :day}} =
               TaskLimits.check(spec(), [user_uuid: user], now)

      assert {:ok, %GuardEvent{kind: "limit_forgiven"}} =
               TaskLimits.forgive(
                 owner_scope(owner),
                 "test.limited",
                 :user,
                 :day,
                 user,
                 DateTime.add(now, -60)
               )

      assert :ok = TaskLimits.check(spec(), [user_uuid: user], now)
      assert TaskLimits.usage("test.limited", user, now).user.requests.day == 0

      # After the moment it counts again; the month is not forgiven.
      row(ep, DateTime.add(now, -30), user_uuid: user)
      usage = TaskLimits.usage("test.limited", user, now)
      assert usage.user.requests == %{day: 1, month: 3}

      # The forgiving is kept only as its event; the other user is not forgiven.
      assert [%GuardEvent{user_uuid: ^user, actor_uuid: actor}] = events("limit_forgiven")
      assert actor == owner.uuid
    end

    test "a forgiving of the window before does not count", %{owner: owner, endpoint: ep} do
      now = ~U[2026-10-22 12:00:00Z]

      {:ok, _} =
        TaskLimits.forgive(
          owner_scope(owner),
          "test.limited",
          :task,
          :day,
          nil,
          ~U[2026-10-21 12:00:00Z]
        )

      row(ep, ~U[2026-10-22 06:00:00Z])
      assert TaskLimits.usage("test.limited", nil, now).task.requests.day == 1
    end
  end

  describe "signals" do
    test "a limit reached twice in one window is signalled once, also with no user",
         %{owner: owner, endpoint: ep} do
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "1"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row(ep, now)

      for _ <- 1..2 do
        assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
                 TaskLimits.check(spec(), [], now)
      end

      assert [%GuardEvent{user_uuid: nil, dedupe_key: key, ref: ref}] = events("limit_reached")
      day = TaskLimits.period_keys(now).day
      assert key == "limit_reached:test.limited:-:requests:#{day}"

      assert ref == %{
               "scope" => "task",
               "unit" => "requests",
               "period" => "day",
               "used" => 1,
               "limit" => 1
             }

      # The watchers (none configured: the Owner) are told once.
      assert [%Notification{metadata: %{"notification_link" => link}}] =
               notifications_of(owner.uuid)

      assert link =~ "/admin/ai/tasks"

      assert_activity_logged("guard.limit_reached",
        resource_uuid: hd(events("limit_reached")).uuid
      )
    end

    test "a user's limit reached twice is one event and one notice to the user",
         %{owner: owner, endpoint: ep} do
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"user" => %{"requests" => %{"day" => "1"}}})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row(ep, now, user_uuid: user)

      for _ <- 1..2,
          do: assert({:error, _} = TaskLimits.check(spec(), [user_uuid: user], now))

      assert [%GuardEvent{user_uuid: ^user}] = events("limit_reached")
      assert [_] = notifications_of(user)
    end

    test "a user's warning goes to the user only; the task's to the watchers",
         %{owner: owner, endpoint: ep} do
      watcher = Fixtures.user_fixture().uuid
      user = Fixtures.user_fixture().uuid
      Application.put_env(:phoenix_kit_ai, :fake_limit_watchers, [watcher, user])

      set_limits(owner, %{
        "user" => %{"requests" => %{"day" => "5"}},
        "task" => %{"requests" => %{"month" => "10"}}
      })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      for _ <- 1..4, do: row(ep, now, user_uuid: user)

      assert :ok = TaskLimits.check(spec(), [user_uuid: user], now)

      # 4 of 5 for the user (80 %): only the user hears of it.
      assert [_] = notifications_of(user)
      assert notifications_of(watcher) == []
      assert notifications_of(owner.uuid) == []

      for _ <- 1..4, do: row(ep, now)
      # 8 of 10 for the task: the watchers, without the user who called.
      assert :ok = TaskLimits.check(spec(), [], now)
      assert [_] = notifications_of(watcher)
      assert [_] = notifications_of(owner.uuid)

      assert [_, _] = events("limit_warning")
    end

    test "the task's watchers callback is asked about the user, who is left out",
         %{owner: owner} do
      watcher = Fixtures.user_fixture().uuid
      user = Fixtures.user_fixture().uuid
      Application.put_env(:phoenix_kit_ai, :fake_limit_watchers, [watcher, user])
      Application.put_env(:phoenix_kit_ai, :fake_limit_watchers_pid, self())

      watchers = GuardEvents.watchers(spec(), user)
      assert_received {:watchers_asked, ^user}
      assert Enum.sort(watchers) == Enum.sort([owner.uuid, watcher])

      # A configured list replaces the Owners.
      {:ok, _} = GuardEvents.set_watchers(owner_scope(owner), [watcher])
      assert GuardEvents.watchers(spec("test.unlimited"), nil) == [watcher]
    end

    test "a user who does not exist is refused, not a database error", %{owner: owner} do
      ghost = Ecto.UUID.generate()
      scope = owner_scope(owner)

      assert {:error, :unknown_user} =
               TaskLimits.put_user_limits(scope, "test.limited", ghost, %{
                 "requests" => %{"day" => 1}
               })

      assert {:error, :unknown_user} =
               TaskLimits.forgive(scope, "test.limited", :user, :day, ghost)

      assert TestRepo.aggregate(PhoenixKitAI.TaskUserLimit, :count) == 0
      assert events("limit_forgiven") == []
    end

    test "watchers who do not exist are left out, with a warning", %{owner: owner} do
      watcher = Fixtures.user_fixture().uuid
      ghost = Ecto.UUID.generate()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [^watcher]} =
                   GuardEvents.set_watchers(owner_scope(owner), [ghost, watcher])
        end)

      assert log =~ "1 watcher"
      refute log =~ ghost
      assert GuardEvents.configured_watchers() == [watcher]
    end

    test "the watchers list must be user uuids and fit the setting", %{owner: owner} do
      assert {:error, :invalid_uuid} = GuardEvents.set_watchers(owner_scope(owner), ["nope"])

      many = for _ <- 1..30, do: Fixtures.user_fixture().uuid
      assert {:error, :too_long} = GuardEvents.set_watchers(owner_scope(owner), many)
    end

    test "a change of limits keeps what they were and what they are in the Activity log",
         %{owner: owner} do
      user = Fixtures.user_fixture().uuid
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "3"}}}, %{"warn_percent" => "70"})
      set_limits(owner, %{"task" => %{"requests" => %{"day" => "5"}}}, %{"warn_percent" => "90"})

      assert [_, second] = activities("guard.limits_updated")

      assert %{
               "limits_before" => %{"task" => %{"requests" => %{"day" => 3}}},
               "limits" => %{"task" => %{"requests" => %{"day" => 5}}},
               "warn_percent_before" => 70,
               "warn_percent" => 90
             } = second

      for amount <- ["1", "2"] do
        {:ok, _} =
          TaskLimits.put_user_limits(owner_scope(owner), "test.limited", user, %{
            "requests" => %{"day" => amount}
          })
      end

      assert [
               _,
               %{
                 "limits_before" => %{"requests" => %{"day" => 1}},
                 "limits" => %{"requests" => %{"day" => 2}}
               }
             ] =
               activities("guard.user_limits_updated")
    end

    test "editing the watchers is written to the Activity log", %{owner: owner} do
      watcher = Fixtures.user_fixture().uuid
      {:ok, _} = GuardEvents.set_watchers(owner_scope(owner), [watcher])
      assert GuardEvents.configured_watchers() == [watcher]

      setting = TestRepo.get_by!(PhoenixKit.Settings.Setting, key: "ai_guard_watchers")

      assert_activity_logged("guard.watchers_updated",
        actor_uuid: owner.uuid,
        resource_uuid: setting.uuid,
        metadata_has: %{"count" => 1}
      )
    end

    test "a Budget refusal is a limit_reached event once per local day", %{endpoint: ep} do
      stub_chat(self())
      user = Fixtures.user_fixture().uuid
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:user_calls, 1)
      on_exit(fn -> PhoenixKitAI.Budget.set_limit(:user_calls, 0) end)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1", user_uuid: user, task: "test.unlimited")

      for _ <- 1..2 do
        assert {:error, {:budget_exceeded, :user_calls}} =
                 PhoenixKitAI.ask(ep.uuid, "q2", user_uuid: user, task: "test.unlimited")
      end

      day = TaskLimits.period_keys(DateTime.utc_now()).day

      assert [
               %GuardEvent{
                 user_uuid: ^user,
                 task_key: "test.unlimited",
                 endpoint_uuid: endpoint_uuid,
                 ref: %{"scope" => "budget:user_calls"},
                 dedupe_key: key
               }
             ] = events("limit_reached")

      assert endpoint_uuid == ep.uuid
      assert key == "limit_reached:budget:user_calls:#{user}:#{day}"
    end
  end
end
