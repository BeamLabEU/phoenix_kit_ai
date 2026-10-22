defmodule PhoenixKitAI.Test.FakeAITasks do
  @moduledoc """
  A module that declares AI tasks through `ai_tasks/0`, for the task
  registry and the call-time guard. Registered per test with
  `PhoenixKit.ModuleRegistry.register/1` (and unregistered on exit).

  `ai_tasks/0` reports each call to the pid in the `:fake_ai_tasks_pid`
  app env, so a test can see when the registry is rebuilt; `enabled?/0`
  answers the `:fake_ai_tasks_enabled` app env (default true).
  """

  alias PhoenixKitAI.TaskSpec

  def enabled?, do: Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, true)

  def ai_tasks do
    case Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_pid) do
      pid when is_pid(pid) -> send(pid, :ai_tasks_called)
      _ -> :ok
    end

    [
      %TaskSpec{
        key: "test.photo",
        label: "Photo reading",
        purpose: "Read the items in a shelf photo.",
        needs: [:vision, :json_schema],
        endpoints: {__MODULE__, :photo_endpoints, []}
      },
      %TaskSpec{key: "test.tools", label: "Tool user", needs: [:tools]},
      %TaskSpec{key: "test.plain", label: "Plain text", needs: []},
      %TaskSpec{key: "test.json", label: "Loose JSON", needs: [:json]},
      # Accepted for later parts of the guard, not used yet.
      %TaskSpec{
        key: "test.free",
        label: "Free text",
        block_group: "free_text",
        private: true,
        self_flag: true,
        typical_tokens: {1_000, 200}
      }
    ]
  end

  def photo_endpoints, do: Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, [])
end
