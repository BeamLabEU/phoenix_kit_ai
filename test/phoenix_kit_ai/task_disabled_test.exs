defmodule PhoenixKitAI.TaskDisabledTest do
  @moduledoc """
  A task whose declaring module is switched off refuses calls:
  `{:error, {:task_disabled, key}}`, written as a refusal row, before the
  request cache (a cached answer cannot bypass it). Switching the module on
  again lets calls through; a provider's tasks have no switch; the
  translation worker discards a refused job instead of retrying it.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Errors, Guard, Request, Tasks, TaskSpec, TranslateWorker}
  alias PhoenixKitAI.Test.{FakeAITasks, FakeTranslatableValid}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defmodule OffProvider do
    @moduledoc false
    # A host module's own enabled?/0 never switches a provider's tasks off.
    def enabled?, do: false
    def ai_tasks, do: [%TaskSpec{key: "myapp.always", label: "Always"}]
  end

  setup do
    PhoenixKitAI.RequestCache.clear()
    PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(FakeAITasks)

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "cost" => 0.01}
      })
    end)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeAITasks)
      :persistent_term.erase({Tasks, :registry})

      for key <- [:req_options, :fake_ai_tasks_enabled, :task_providers],
          do: Application.delete_env(:phoenix_kit_ai, key)
    end)

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Disabled-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/model",
        api_key: "sk-test-key"
      })

    {:ok, endpoint: endpoint}
  end

  defp switch(on?), do: Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, on?)

  defp rows(ep), do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))

  test "a switched-off module's task is refused before HTTP, with a refusal row", %{endpoint: ep} do
    switch(false)

    assert {:error, {:task_disabled, "test.plain"}} =
             PhoenixKitAI.ask(ep.uuid, "q", task: "test.plain")

    refute_received :provider_called

    assert [%Request{status: "error", metadata: %{"refused" => true, "task" => "test.plain"}}] =
             rows(ep)

    assert Errors.message({:task_disabled, "test.plain"}) =~ "switched off"
  end

  test "a cached answer cannot bypass the switch, and switching on lets it through",
       %{endpoint: ep} do
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", task: "test.plain", cache: true)
    assert_received :provider_called

    # Warm: the same call is answered from the cache, without the provider.
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", task: "test.plain", cache: true)
    refute_received :provider_called

    switch(false)

    assert {:error, {:task_disabled, "test.plain"}} =
             PhoenixKitAI.ask(ep.uuid, "same", task: "test.plain", cache: true)

    switch(true)
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", task: "test.plain", cache: true)
  end

  test "an admission is refused too" do
    switch(false)

    assert {:error, {:task_disabled, "test.plain"}} =
             Guard.admit("test.plain", nil, "turn-1", 60)
  end

  test "calls without a task, or naming an undeclared one, run as before", %{endpoint: ep} do
    switch(false)

    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")

    capture_log(fn ->
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2", task: "nobody.declares.this")
    end)
  end

  test "a provider's task has no switch", %{endpoint: ep} do
    Application.put_env(:phoenix_kit_ai, :task_providers, [OffProvider])

    assert %TaskSpec{enabled: true} = Tasks.for_call("myapp.always")
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q", task: "myapp.always")
  end

  test "with the AI module off its own tasks refuse calls", %{endpoint: ep} do
    PhoenixKitAI.disable_system()

    assert {:error, {:task_disabled, "ai.playground"}} =
             PhoenixKitAI.ask(ep.uuid, "q", task: "ai.playground")
  end

  describe "the translation worker" do
    setup %{endpoint: ep} do
      :ok = ModuleRegistry.register(FakeTranslatableValid)
      on_exit(fn -> ModuleRegistry.unregister(FakeTranslatableValid) end)

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Disabled-prompt-#{System.unique_integer([:positive])}",
          content: "Translate {{name}} from {{SourceLanguage}} to {{TargetLanguage}}."
        })

      {:ok, prompt: prompt, endpoint: ep}
    end

    test "discards a refused job instead of retrying it", %{endpoint: ep, prompt: prompt} do
      PhoenixKitAI.disable_system()

      job = %Oban.Job{
        args: %{
          "resource_type" => FakeTranslatableValid.resource_type(),
          "resource_uuid" => Ecto.UUID.generate(),
          "endpoint_uuid" => ep.uuid,
          "prompt_uuid" => prompt.uuid,
          "source_lang" => "en",
          "target_lang" => "fr"
        },
        attempt: 1,
        max_attempts: 3
      }

      capture_log(fn ->
        assert {:discard, {:ai_error, {:task_disabled, "ai.translation"}}} =
                 TranslateWorker.perform(job)
      end)

      refute_received :provider_called
    end
  end
end
