defmodule PhoenixKitAI.Test.FakeAITasks do
  @moduledoc """
  A module that declares AI tasks through `ai_tasks/0`, for the task
  registry and the call-time guard. Registered per test with
  `PhoenixKit.ModuleRegistry.register/1` (and unregistered on exit).

  `ai_tasks/0` reports each call to the pid in the `:fake_ai_tasks_pid`
  app env, so a test can see when the registry is rebuilt; `enabled?/0`
  answers the `:fake_ai_tasks_enabled` app env (default true).
  `:fake_ai_tasks_fail` (`:raise`, `:exit` or `:throw`) makes `ai_tasks/0`
  and the `endpoints` callback fail that way.
  """

  alias PhoenixKitAI.TaskSpec

  def enabled?, do: Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, true)

  def ai_tasks do
    case Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_pid) do
      pid when is_pid(pid) -> send(pid, :ai_tasks_called)
      _ -> :ok
    end

    maybe_fail()

    [
      %TaskSpec{
        key: "test.photo",
        label: "Photo reading",
        purpose: "Read the items in a shelf photo.",
        needs: [:vision, :json_schema],
        endpoints: {__MODULE__, :photo_endpoints, []}
      },
      %TaskSpec{
        key: "test.sized",
        label: "Sized photo task",
        needs: [:vision],
        typical_tokens: {10_000, 1_000}
      },
      %TaskSpec{key: "test.tools", label: "Tool user", needs: [:tools]},
      %TaskSpec{key: "test.plain", label: "Plain text", needs: []},
      # Two keys a naive DOM id would make the same.
      %TaskSpec{key: "test.same.id", label: "Dotted"},
      %TaskSpec{key: "test.same-id", label: "Dashed"},
      %TaskSpec{key: "test.json", label: "Loose JSON", needs: [:json]},
      %TaskSpec{key: "test.documents", label: "Document reading", needs: [:file_input]},
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

  def photo_endpoints do
    maybe_fail()
    Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, [])
  end

  defp maybe_fail do
    case Application.get_env(:phoenix_kit_ai, :fake_ai_tasks_fail) do
      :raise -> raise "fake ai_tasks failure"
      :exit -> exit(:fake_timeout)
      :throw -> throw(:fake_throw)
      {:raise, message} -> raise message
      {:exit, reason} -> exit(reason)
      {:throw, reason} -> throw(reason)
      _ -> :ok
    end
  end
end
