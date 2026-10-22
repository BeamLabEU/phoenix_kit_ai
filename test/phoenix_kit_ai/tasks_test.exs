defmodule PhoenixKitAI.TasksTest do
  @moduledoc """
  The task registry (`PhoenixKitAI.Tasks`): discovery through `ai_tasks/0`,
  the cache that is rebuilt only when the module set changes, tasks of a
  switched-off module, and fitness for consumer forms — `fitness/2`,
  `endpoint_options/1`, `check_selection/2`. Capabilities come from
  declarations on the endpoints (no catalogue process runs here).
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.Tasks
  alias PhoenixKitAI.TaskSpec
  alias PhoenixKitAI.Test.{FakeAITasks, FakeAITasksDuplicate}

  setup do
    Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_pid, self())
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      # A build with a failed callback is kept for a minute; never let one
      # reach the next test.
      :persistent_term.erase({Tasks, :registry})
      ModuleRegistry.unregister(FakeAITasks)
      ModuleRegistry.unregister(FakeAITasksDuplicate)

      for key <- [
            :fake_ai_tasks_pid,
            :fake_ai_tasks_enabled,
            :fake_ai_tasks_endpoints,
            :fake_ai_tasks_fail,
            :task_registry_retry_ms
          ],
          do: Application.delete_env(:phoenix_kit_ai, key)
    end)

    :ok
  end

  # An endpoint whose model's capabilities are declared on it.
  defp endpoint(declared \\ %{}, attrs \\ %{}) do
    model = "vendor/model-#{System.unique_integer([:positive])}"

    settings =
      if declared == %{},
        do: %{},
        else: %{"capabilities" => Map.put(declared, "model", model)}

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Tasks EP #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: model,
            api_key: "sk-test-key",
            provider_settings: settings
          },
          attrs
        )
      )

    endpoint
  end

  describe "discovery" do
    test "finds the tasks of registered modules and this module's own" do
      keys = Enum.map(Tasks.list(), & &1.key)

      assert "ai.translation" in keys
      assert "ai.playground" in keys
      assert "test.photo" in keys
      assert keys == Enum.sort(keys)

      assert %TaskSpec{needs: [:vision, :json_schema], module: FakeAITasks, enabled: true} =
               Tasks.get("test.photo")

      assert %TaskSpec{needs: [], block_group: "free_text", module: PhoenixKitAI} =
               Tasks.get("ai.playground")

      assert %TaskSpec{needs: []} = Tasks.get("ai.translation")
      assert Tasks.get("no.such.task") == nil
    end

    test "keeps the fields later parts of the guard read" do
      assert %TaskSpec{private: true, self_flag: true, typical_tokens: {1_000, 200}} =
               Tasks.get("test.free")
    end

    test "is built once and again only when the module set changes" do
      Tasks.list()
      flush_ai_tasks_calls()

      Tasks.list()
      Tasks.get("test.photo")
      Tasks.for_call("test.photo")
      refute_received :ai_tasks_called

      :ok = ModuleRegistry.register(FakeAITasksDuplicate)

      capture_log(fn -> Tasks.list() end)
      assert_received :ai_tasks_called
    end

    test "marks the tasks of a switched-off module" do
      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, false)

      assert %TaskSpec{enabled: false} = Tasks.get("test.photo")

      for task <- Tasks.list() do
        if task.module == FakeAITasks,
          do: refute(task.enabled),
          else: assert(task.enabled == PhoenixKitAI.enabled?())
      end

      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, true)
      assert %TaskSpec{enabled: true} = Tasks.get("test.photo")
    end

    test "a second declaration of a key loses, with a warning; junk entries are skipped" do
      # Built for the set without the duplicate first, so registering it
      # is a change (an earlier test may have left this very set cached).
      Tasks.list()
      :ok = ModuleRegistry.register(FakeAITasksDuplicate)

      log = capture_log(fn -> Tasks.list() end)

      assert %TaskSpec{label: "Plain text", needs: [], module: FakeAITasks} =
               Tasks.get("test.plain")

      assert log =~ "declared again"
      assert log =~ "not a %PhoenixKitAI.TaskSpec{}"
    end

    test "a callback that exits or throws drops its tasks, with a warning, and does not crash" do
      for failure <- [:exit, :throw, :raise] do
        # A module set the registry has not been built for, so it is built now.
        :ok = ModuleRegistry.unregister(FakeAITasks)
        Tasks.list()
        :ok = ModuleRegistry.register(FakeAITasks)
        Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_fail, failure)

        log = capture_log(fn -> assert Tasks.get("test.photo") == nil end)
        assert log =~ "ai_tasks/0 failed", "#{failure}"
      end
    end

    test "callback failures keep their payload out of the log" do
      secret = "secret-provider-key-and-user-content"
      spec = %TaskSpec{key: "test.callback", endpoints: {FakeAITasks, :photo_endpoints, []}}

      for kind <- [:raise, :exit, :throw] do
        :persistent_term.erase({Tasks, :registry})
        Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_fail, {kind, secret})

        log =
          capture_log(fn ->
            assert Tasks.get("test.photo") == nil
            assert Tasks.endpoints(spec) == []
          end)

        assert log =~ "ai_tasks/0 failed"
        assert log =~ "endpoints callback failed"
        refute log =~ secret
      end
    end

    test "a build with a failed callback is tried again, at most once per interval" do
      :ok = ModuleRegistry.unregister(FakeAITasks)
      Tasks.list()
      :ok = ModuleRegistry.register(FakeAITasks)
      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_fail, :exit)
      capture_log(fn -> assert Tasks.get("test.photo") == nil end)

      # Fixed, but within the interval (default one minute): not rebuilt yet.
      Application.delete_env(:phoenix_kit_ai, :fake_ai_tasks_fail)
      flush_ai_tasks_calls()
      assert Tasks.get("test.photo") == nil
      refute_received :ai_tasks_called

      # The interval over: rebuilt, and kept from then on.
      Application.put_env(:phoenix_kit_ai, :task_registry_retry_ms, 0)
      assert %TaskSpec{} = Tasks.get("test.photo")
      flush_ai_tasks_calls()
      assert %TaskSpec{} = Tasks.get("test.photo")
      refute_received :ai_tasks_called
    end

    test "an unknown key in a call is reported once per key" do
      key = "unknown.task-#{System.unique_integer([:positive])}"

      first = capture_log(fn -> assert Tasks.for_call(key) == nil end)
      second = capture_log(fn -> assert Tasks.for_call(key) == nil end)

      assert first =~ key
      refute second =~ key
    end
  end

  describe "fitness/2" do
    test "fit, unfit and unknown by the hard needs" do
      assert Tasks.fitness("test.photo", endpoint(%{"vision" => "yes", "json_schema" => "yes"})) ==
               :fit

      assert Tasks.fitness("test.photo", endpoint(%{"vision" => "no", "json_schema" => "yes"})) ==
               {:unfit, [:vision]}

      assert Tasks.fitness("test.photo", endpoint(%{"vision" => "yes"})) ==
               {:unknown, [:json_schema]}

      assert Tasks.fitness("test.photo", endpoint()) == {:unknown, [:vision, :json_schema]}
    end

    test "a task without needs, a soft :json need and an unknown key always fit" do
      ep = endpoint(%{"vision" => "no"})

      assert Tasks.fitness("test.plain", ep) == :fit
      assert Tasks.fitness("test.json", ep) == :fit
      capture_log(fn -> assert Tasks.fitness("no.such.task", ep) == :fit end)
    end
  end

  describe "endpoint_options/1 and check_selection/2" do
    test "lists the enabled endpoints with their fitness" do
      fit = endpoint(%{"vision" => "yes", "json_schema" => "yes"})
      unfit = endpoint(%{"vision" => "no", "json_schema" => "yes"})
      off = endpoint(%{"vision" => "yes", "json_schema" => "yes"}, %{enabled: false})

      options = Map.new(Tasks.endpoint_options("test.photo"), &{&1.endpoint.uuid, &1.fitness})

      assert options[fit.uuid] == :fit
      assert options[unfit.uuid] == {:unfit, [:vision]}
      refute Map.has_key?(options, off.uuid)
    end

    test "refuses an unfit endpoint and one nobody has verified" do
      assert :ok =
               Tasks.check_selection(
                 "test.photo",
                 endpoint(%{"vision" => "yes", "json_schema" => "yes"})
               )

      assert {:error, {:model_unfit, [:vision]}} =
               Tasks.check_selection("test.photo", endpoint(%{"vision" => "no"}).uuid)

      assert {:error, {:model_unverified, [:vision, :json_schema]}} =
               Tasks.check_selection("test.photo", endpoint())

      assert :ok = Tasks.check_selection("test.plain", endpoint())

      assert {:error, :endpoint_not_found} =
               Tasks.check_selection("test.photo", Ecto.UUID.generate())
    end
  end

  describe "endpoints/1" do
    test "reads the task's callback; uuids, structs and {:ok, uuid} all count" do
      a = endpoint()
      b = endpoint()

      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, [a.uuid, b, a.uuid, nil])
      assert Enum.map(Tasks.endpoints(Tasks.get("test.photo")), & &1.uuid) == [a.uuid, b.uuid]

      Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, {:ok, b.uuid})
      assert [%{uuid: uuid}] = Tasks.endpoints(Tasks.get("test.photo"))
      assert uuid == b.uuid

      assert Tasks.endpoints(Tasks.get("test.tools")) == []
    end

    test "a callback that exits or throws gives no endpoints, without crashing" do
      spec = Tasks.get("test.photo")

      for failure <- [:exit, :throw, :raise] do
        Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_fail, failure)
        capture_log(fn -> assert Tasks.endpoints(spec) == [] end)
      end
    end
  end

  defp flush_ai_tasks_calls do
    receive do
      :ai_tasks_called -> flush_ai_tasks_calls()
    after
      0 -> :ok
    end
  end

  describe "TaskSpec.purpose/1" do
    test "translates the purpose through the declaring module's backend; the msgid stays as declared" do
      spec = Enum.find(PhoenixKitAI.ai_tasks(), &(&1.key == "ai.translation"))

      assert spec.purpose =~ "Translate the text fields"
      assert TaskSpec.purpose(spec) =~ "Translate the text fields"

      Gettext.with_locale(PhoenixKitAI.Gettext, "ru", fn ->
        assert TaskSpec.purpose(spec) =~ "Переводит текстовые поля"
      end)

      Gettext.with_locale(PhoenixKitAI.Gettext, "et", fn ->
        assert TaskSpec.purpose(spec) =~ "Tõlgib kirje tekstiväljad"
      end)
    end

    test "without a backend or a purpose" do
      assert TaskSpec.purpose(%TaskSpec{key: "x", purpose: "Plain"}) == "Plain"
      assert TaskSpec.purpose(%TaskSpec{key: "x", purpose: nil}) == nil
      assert TaskSpec.purpose(%TaskSpec{key: "x", purpose: ""}) == nil
    end
  end
end
