defmodule PhoenixKitAI.TaskProvidersTest do
  @moduledoc """
  `config :phoenix_kit_ai, task_providers: [...]` — a host app's own
  modules declaring AI tasks without being kit modules: listed, always
  enabled, usable in a call with their limits; a key a kit module already
  declares stays the kit module's (warned, and shown on AI → Tasks); a bad
  config, a missing module, one without `ai_tasks/0` and a raising one are
  each warned about and never crash discovery; a change to the list
  rebuilds the registry.
  """

  use PhoenixKitAI.LiveCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Request, Tasks, TaskSpec}
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defmodule AppTasks do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    # A host module may define enabled?/0 for its own reasons; it must not
    # switch the provider's tasks off.
    def enabled?, do: false

    def ai_tasks do
      [
        %TaskSpec{
          key: "myapp.photo_fix",
          label: "Photo fix",
          default_limits: %{task: %{requests: %{day: 1}}}
        },
        # Collides with FakeAITasks' declaration: the kit module keeps it.
        %TaskSpec{key: "test.photo", label: "App photo"}
      ]
    end
  end

  defmodule OtherAppTasks do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    def ai_tasks,
      do: [%TaskSpec{key: "myapp.photo_fix", label: "Second"}, :not_a_spec]
  end

  defmodule RaisingProvider do
    @moduledoc false
    def ai_tasks, do: raise("boom")
  end

  defmodule NoTasksProvider do
    @moduledoc false
  end

  defmodule BlockingProvider do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    # Tells the test who is asking, then answers or raises on its word.
    def ai_tasks do
      send(Application.fetch_env!(:phoenix_kit_ai, :blocking_provider_test), {:called, self()})

      receive do
        {:go, :ok} -> [%TaskSpec{key: "myapp.slow", label: "Slow"}]
        {:go, :raise} -> raise "slow failure"
      end
    end
  end

  defmodule ReentrantProvider do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    # Calls back into the registry while it is being built.
    def ai_tasks do
      send(Application.fetch_env!(:phoenix_kit_ai, :blocking_provider_test), {:called, self()})
      _ = PhoenixKitAI.Tasks.list()
      [%TaskSpec{key: "myapp.reentrant", label: "Re-entrant"}]
    end
  end

  defmodule AsyncReentrantProvider do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    # Calls back into the registry from a child it awaits.
    def ai_tasks do
      send(Application.fetch_env!(:phoenix_kit_ai, :blocking_provider_test), {:called, self()})
      _ = fn -> PhoenixKitAI.Tasks.list() end |> Task.async() |> Task.await(2_000)
      [%TaskSpec{key: "myapp.async_reentrant", label: "Async re-entrant"}]
    end
  end

  defmodule CrashingChildProvider do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    # A linked child that dies takes the callback down with it.
    def ai_tasks do
      spawn_link(fn -> exit(:boom) end)
      Process.sleep(1_000)
      [%TaskSpec{key: "myapp.crashing", label: "Crashing"}]
    end
  end

  defmodule NotifyingHangingProvider do
    @moduledoc false
    def ai_tasks do
      send(Application.fetch_env!(:phoenix_kit_ai, :blocking_provider_test), {:called, self()})

      receive do
        :never -> []
      end
    end
  end

  defmodule QuickProvider do
    @moduledoc false
    alias PhoenixKitAI.TaskSpec

    def ai_tasks do
      Process.sleep(1)
      [%TaskSpec{key: "myapp.quick", label: "Quick"}]
    end
  end

  defmodule HangingProvider do
    @moduledoc false
    def ai_tasks do
      receive do
        :never -> []
      end
    end
  end

  setup do
    PhoenixKitAI.RequestCache.clear()
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      :persistent_term.erase({Tasks, :registry})
      ModuleRegistry.unregister(FakeAITasks)
      Application.delete_env(:phoenix_kit_ai, :task_providers)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  defp providers(list), do: Application.put_env(:phoenix_kit_ai, :task_providers, list)

  defp keys, do: Enum.map(Tasks.list(), & &1.key)

  describe "discovery" do
    test "a provider's task is listed, always enabled, and marked as the app's" do
      providers([AppTasks])

      assert %TaskSpec{module: AppTasks, enabled: true} = spec = Tasks.get("myapp.photo_fix")
      assert Tasks.provider?(spec)
      assert "myapp.photo_fix" in keys()
      assert TaskSpec.label(spec) == "Photo fix"
      refute Tasks.provider?(Tasks.get("test.photo"))
    end

    test "changing the provider list rebuilds the registry" do
      refute "myapp.photo_fix" in keys()

      providers([AppTasks])
      assert "myapp.photo_fix" in keys()

      providers([])
      refute "myapp.photo_fix" in keys()
    end

    test "a kit module's key wins; the warning names both; collisions/0 lists it" do
      providers([AppTasks])

      log = capture_log(fn -> assert Tasks.get("test.photo").module == FakeAITasks end)

      assert log =~ "test.photo"
      assert log =~ inspect(AppTasks)
      assert log =~ inspect(FakeAITasks)

      assert %{key: "test.photo", kept: FakeAITasks, dropped: AppTasks} in Tasks.collisions()
    end

    test "between providers the first in config wins, and a bad spec is dropped" do
      providers([AppTasks, OtherAppTasks])

      log = capture_log(fn -> assert Tasks.get("myapp.photo_fix").module == AppTasks end)

      assert log =~ "not a %PhoenixKitAI.TaskSpec{}"

      assert %{key: "myapp.photo_fix", kept: AppTasks, dropped: OtherAppTasks} in Tasks.collisions()
    end

    test "a module listed both ways is a kit module, with its switch and no collision" do
      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :fake_ai_tasks_enabled) end)
      providers([FakeAITasks])

      log = capture_log(fn -> assert %TaskSpec{enabled: false} = Tasks.get("test.photo") end)

      refute log =~ "declared again"
      refute Tasks.provider?(Tasks.get("test.photo"))
      assert Tasks.collisions() == []
    end

    test "an improper list is bad config: warned about, its proper part used, nothing raises" do
      providers([AppTasks | :not_a_tail])

      log = capture_log(fn -> assert "myapp.photo_fix" in keys() end)
      assert log =~ "not a proper list"
      assert Tasks.get("myapp.photo_fix").module == AppTasks
      assert Tasks.for_call("test.photo")
    end

    test "a kit module that fails keeps its keys: a provider never takes them over" do
      providers([AppTasks])
      assert Tasks.get("test.photo").module == FakeAITasks

      # The kit module's ai_tasks/0 now raises, and a config change rebuilds.
      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_fail, :raise)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :fake_ai_tasks_fail) end)
      providers([AppTasks, NoTasksProvider])

      log =
        capture_log(fn ->
          spec = Tasks.get("test.photo")
          assert spec.module == FakeAITasks
          refute Tasks.provider?(spec)
        end)

      assert log =~ "ai_tasks/0 failed"
      assert %{key: "test.photo", kept: FakeAITasks, dropped: AppTasks} in Tasks.collisions()
    end

    test "overview/0 returns the tasks, the providers and the collisions" do
      providers([AppTasks])

      assert %{tasks: tasks, providers: providers, collisions: collisions} = Tasks.overview()
      assert MapSet.member?(providers, AppTasks)
      assert %TaskSpec{enabled: true} = Enum.find(tasks, &(&1.key == "myapp.photo_fix"))
      assert Enum.any?(collisions, &(&1.key == "test.photo"))
    end

    test "an invalid config, a missing module, no ai_tasks/0 and a raising provider are warned about" do
      for {config, expected} <- [
            {:not_a_list, "must be a list of modules"},
            {["MyApp.AI", AppTasks], "not module names"},
            {[Elixir.NoSuchProviderModule], "could not be loaded"},
            {[NoTasksProvider], "does not export ai_tasks/0"},
            {[RaisingProvider], "ai_tasks/0 failed"}
          ] do
        :persistent_term.erase({Tasks, :registry})
        providers(config)

        log = capture_log(fn -> assert "test.photo" in keys() end)
        assert log =~ expected, "#{inspect(config)}: #{log}"
      end

      # Warned once per build, not on every lookup.
      providers([NoTasksProvider])
      assert capture_log(fn -> keys() end) =~ "does not export ai_tasks/0"
      refute capture_log(fn -> keys() end) =~ "does not export ai_tasks/0"
    end
  end

  describe "with the builder (the one writer)" do
    setup do
      :persistent_term.erase({Tasks, :registry})
      Application.put_env(:phoenix_kit_ai, :blocking_provider_test, self())

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :blocking_provider_test)
        Application.delete_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms)
      end)

      :ok
    end

    test "concurrent callers share one build: ai_tasks/0 is called once" do
      providers([BlockingProvider])

      first = Task.async(fn -> Tasks.get("myapp.slow") end)
      assert_receive {:called, builder_task}, 1_000
      second = Task.async(fn -> Tasks.get("myapp.slow") end)
      refute_receive {:called, _}, 200

      send(builder_task, {:go, :ok})
      assert %TaskSpec{module: BlockingProvider} = Task.await(first)
      assert %TaskSpec{module: BlockingProvider} = Task.await(second)
      refute_received {:called, _}
    end

    test "a failing build after a good one keeps the declared task" do
      providers([BlockingProvider])
      first = Task.async(fn -> Tasks.get("myapp.slow") end)
      assert_receive {:called, cb}, 1_000
      send(cb, {:go, :ok})
      assert %TaskSpec{} = Task.await(first)

      # A config change rebuilds; the provider now fails.
      providers([BlockingProvider, NoTasksProvider])
      again = Task.async(fn -> capture_log(fn -> Tasks.get("myapp.slow") end) end)
      assert_receive {:called, cb2}, 1_000
      send(cb2, {:go, :raise})
      Task.await(again)

      assert %TaskSpec{module: BlockingProvider} = Tasks.get("myapp.slow")
    end

    test "a build stalled on an old config never outlives the new one" do
      providers([BlockingProvider])
      stalled = Task.async(fn -> Tasks.get("myapp.slow") end)
      assert_receive {:called, cb}, 1_000

      providers([AppTasks])
      current = Task.async(fn -> Tasks.get("myapp.photo_fix") end)

      send(cb, {:go, :ok})
      Task.await(stalled)
      assert %TaskSpec{module: AppTasks} = Task.await(current)

      assert Tasks.get("myapp.photo_fix")
      refute Tasks.get("myapp.slow")
      refute_received {:called, _}
    end

    test "a hanging provider times out and the rest of the registry is served" do
      Application.put_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms, 300)
      providers([HangingProvider, AppTasks])

      log =
        capture_log(fn ->
          task = Task.async(fn -> Tasks.get("myapp.photo_fix") end)
          assert {:ok, %TaskSpec{module: AppTasks}} = Task.yield(task, 3_000)
        end)

      assert log =~ "did not answer within 300 ms"
      assert Tasks.get("test.photo")
    end

    test "re-entry from a Task.async child neither deadlocks nor builds twice" do
      providers([AsyncReentrantProvider])

      task = Task.async(fn -> Tasks.get("myapp.async_reentrant") end)
      assert {:ok, %TaskSpec{module: AsyncReentrantProvider}} = Task.yield(task, 3_000)
      assert_received {:called, _}
      refute_received {:called, _}
    end
  end

  describe "the builder survives its callbacks" do
    test "a callback whose linked child crashes is that module's failure; the builder lives" do
      Application.put_env(:phoenix_kit_ai, :task_registry_retry_ms, 0)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :task_registry_retry_ms) end)
      builder = Process.whereis(PhoenixKitAI.Tasks.Builder)
      providers([CrashingChildProvider, AppTasks])

      # Every lookup is a due retry: more crashes than any restart intensity.
      log =
        capture_log(fn ->
          for _ <- 1..6, do: assert(%TaskSpec{module: AppTasks} = Tasks.get("myapp.photo_fix"))
        end)

      assert Process.whereis(PhoenixKitAI.Tasks.Builder) == builder
      assert Process.alive?(builder)
      assert log =~ "CrashingChildProvider"
      refute Tasks.get("myapp.crashing")
    end
  end

  describe "without the builder" do
    setup do
      :persistent_term.erase({Tasks, :registry})
      Application.put_env(:phoenix_kit_ai, :blocking_provider_test, self())
      :ok = GenServer.stop(PhoenixKitAI.Tasks.Builder)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :blocking_provider_test)
        Application.delete_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms)

        unless Process.whereis(PhoenixKitAI.Tasks.Builder) do
          {:ok, _} =
            GenServer.start(PhoenixKitAI.Tasks.Builder, :ok, name: PhoenixKitAI.Tasks.Builder)
        end
      end)

      :ok
    end

    test "a call builds for itself only and caches nothing" do
      providers([AppTasks])
      assert %TaskSpec{module: AppTasks} = Tasks.get("myapp.photo_fix")
      assert :persistent_term.get({Tasks, :registry}, nil) == nil
    end

    test "an inline build stalled before the builder started never overwrites it" do
      providers([BlockingProvider])
      inline = Task.async(fn -> Tasks.get("myapp.slow") end)
      assert_receive {:called, inline_cb}, 1_000

      {:ok, _} =
        GenServer.start(PhoenixKitAI.Tasks.Builder, :ok, name: PhoenixKitAI.Tasks.Builder)

      built = Task.async(fn -> Tasks.get("myapp.slow") end)
      assert_receive {:called, builder_cb}, 1_000
      send(builder_cb, {:go, :ok})
      assert %TaskSpec{} = Task.await(built)
      stored = :persistent_term.get({Tasks, :registry})

      send(inline_cb, {:go, :raise})
      capture_log(fn -> Task.await(inline) end)

      assert :persistent_term.get({Tasks, :registry}) == stored
    end

    test "inline callbacks time out" do
      Application.put_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms, 300)
      providers([HangingProvider, AppTasks])

      log =
        capture_log(fn ->
          task = Task.async(fn -> Tasks.get("myapp.photo_fix") end)
          assert {:ok, %TaskSpec{module: AppTasks}} = Task.yield(task, 3_000)
        end)

      assert log =~ "did not answer within 300 ms"
    end

    test "a callback dies with its inline caller" do
      providers([NotifyingHangingProvider])
      caller = spawn(fn -> Tasks.list() end)
      assert_receive {:called, callback}, 1_000
      ref = Process.monitor(callback)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^callback, _}, 1_000
    end

    test "late replies never land in the caller's mailbox" do
      Application.put_env(:phoenix_kit_ai, :task_registry_callback_timeout_ms, 1)
      providers([QuickProvider])

      leftovers =
        Task.async(fn ->
          capture_log(fn -> for _ <- 1..500, do: Tasks.list() end)
          Process.sleep(50)
          Process.info(self(), :messages)
        end)
        |> Task.await(30_000)

      assert leftovers == {:messages, []}
    end

    test "a remote pid in $callers is not mistaken for a callback and does not raise" do
      node_name = "other@host"

      remote =
        :erlang.binary_to_term(
          <<131, 88, 119, byte_size(node_name), node_name::binary, 1::32, 0::32, 1::32>>
        )

      task =
        Task.async(fn ->
          Process.put(:"$callers", [remote | List.wrap(Process.get(:"$callers"))])
          Tasks.get("test.photo")
        end)

      assert %TaskSpec{key: "test.photo"} = Task.await(task, 5_000)
    end

    test "an unrelated task of the inline builder's caller reads normally" do
      providers([BlockingProvider])
      test = self()

      parent =
        Task.async(fn ->
          sibling =
            Task.async(fn ->
              receive do
                :go_sibling -> Tasks.get("test.photo")
              end
            end)

          send(test, {:sibling, sibling.pid})
          {Tasks.get("myapp.slow"), Task.await(sibling, 5_000)}
        end)

      assert_receive {:sibling, sibling}, 1_000
      assert_receive {:called, parent_cb}, 1_000

      send(sibling, :go_sibling)
      # The sibling builds for itself instead of being treated as re-entry.
      assert_receive {:called, sibling_cb}, 1_000
      send(sibling_cb, {:go, :ok})
      send(parent_cb, {:go, :ok})

      assert {%TaskSpec{}, %TaskSpec{key: "test.photo"}} = Task.await(parent, 5_000)
    end

    test "re-entry from an inline build's Task.async child does not build again" do
      providers([AsyncReentrantProvider])

      task = Task.async(fn -> Tasks.get("myapp.async_reentrant") end)
      assert {:ok, %TaskSpec{module: AsyncReentrantProvider}} = Task.yield(task, 3_000)
      assert_received {:called, _}
      refute_received {:called, _}
    end
  end

  describe "in a call" do
    setup do
      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      {:ok, _} =
        PhoenixKit.Settings.update_json_setting(
          "integration:openrouter:default",
          %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
        )

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "cost" => 0.01}
        })
      end)

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Provider-EP-#{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "vendor/model",
          api_key: "sk-test-key"
        })

      {:ok, endpoint: endpoint}
    end

    test "a provider's task is known to the call and its limits apply", %{endpoint: ep} do
      providers([AppTasks])

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1", task: "myapp.photo_fix")

      assert {:error, {:task_limit_exceeded, :task, :requests, :day}} =
               PhoenixKitAI.ask(ep.uuid, "q2", task: "myapp.photo_fix")

      tasks =
        TestRepo.all(
          from(r in Request, where: r.endpoint_uuid == ^ep.uuid, select: r.metadata["task"])
        )

      assert tasks == ["myapp.photo_fix", "myapp.photo_fix"]
    end
  end

  describe "AI → Tasks" do
    test "shows who declares each task and the dropped provider declaration", %{conn: conn} do
      providers([AppTasks])

      {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

      assert has_element?(
               view,
               "[data-task-key='myapp.photo_fix'] [data-declared-by]",
               "your app"
             )

      refute has_element?(view, "[data-task-key='myapp.photo_fix'] [data-module-off]")
      assert has_element?(view, "#ai-tasks-collisions [data-collision='test.photo']")

      assert has_element?(
               view,
               "#ai-tasks-collisions [data-collision='test.photo']",
               inspect(AppTasks)
             )
    end
  end
end
