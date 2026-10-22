defmodule PhoenixKitAI.Test.FakeOwnUserLimitsTasks do
  @moduledoc """
  A module that declares an AI task whose per-user limits are its own
  (`user_limits: false`): `test.own_user_limits` declares a task limit and a
  user limit, of which only the task's is in force. `test.user_limits_nil`
  and `test.user_limits_other` set the flag to values that are not
  `false` (read as `true`). Registered per test with
  `PhoenixKit.ModuleRegistry.register/1` (and unregistered on exit).
  """

  alias PhoenixKitAI.TaskSpec

  def ai_tasks do
    [
      %TaskSpec{
        key: "test.own_user_limits",
        label: "Own user limits task",
        user_limits: false,
        default_limits: %{
          task: %{requests: %{day: 3}},
          user: %{requests: %{day: 1}}
        }
      },
      %TaskSpec{key: "test.user_limits_nil", user_limits: nil},
      %TaskSpec{key: "test.user_limits_other", user_limits: :no}
    ]
  end
end
