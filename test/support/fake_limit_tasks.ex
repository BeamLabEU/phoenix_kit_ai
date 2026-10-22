defmodule PhoenixKitAI.Test.FakeLimitTasks do
  @moduledoc """
  A module that declares AI tasks for the task limits and the guard's
  signals. Registered per test with `PhoenixKit.ModuleRegistry.register/1`
  (and unregistered on exit).

  `test.limited` has declared default limits and a `watchers` callback that
  answers the `:fake_limit_watchers` app env (a list of user uuids) and
  reports the user it was asked about to the `:fake_limit_watchers_pid`.
  `test.unlimited` declares nothing. `test.vision` needs images, for the
  `model_unfit` events. The endpoints of `test.limited` and `test.vision` are
  the `:fake_limit_endpoints` app env.
  """

  alias PhoenixKitAI.TaskSpec

  def ai_tasks do
    [
      %TaskSpec{
        key: "test.limited",
        label: "Limited task",
        default_limits: %{
          task: %{tokens: %{month: 1_000_000}},
          user: %{requests: %{day: 5}}
        },
        watchers: {__MODULE__, :watchers, []},
        endpoints: {__MODULE__, :endpoints, []}
      },
      %TaskSpec{key: "test.unlimited", label: "Unlimited task"},
      %TaskSpec{
        key: "test.vision",
        label: "Vision task",
        needs: [:vision],
        endpoints: {__MODULE__, :endpoints, []}
      }
    ]
  end

  def watchers(user_uuid) do
    case Application.get_env(:phoenix_kit_ai, :fake_limit_watchers_pid) do
      pid when is_pid(pid) -> send(pid, {:watchers_asked, user_uuid})
      _ -> :ok
    end

    Application.get_env(:phoenix_kit_ai, :fake_limit_watchers, [])
  end

  def endpoints, do: Application.get_env(:phoenix_kit_ai, :fake_limit_endpoints, [])
end
