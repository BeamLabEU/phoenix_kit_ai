defmodule PhoenixKitAI.Test.FakeGuardTasks do
  @moduledoc """
  A module that declares AI tasks for the off-purpose flags, the anomaly
  rules and the blocks. Registered per test with
  `PhoenixKit.ModuleRegistry.register/1` (and unregistered on exit).

  It stands in for another module of the same site: its permission key is
  `agent`, with the sub-permission `agent.manage`, and it declares
  `agent.chat`, a private free-text task in the `free_text` block group
  (which `ai.playground` shares). `test.flagged` is a self-flagging task
  that is not private, `test.private` one that is, `test.quiet` one that
  does not self-flag, and `test.rules` has the anomaly rules. The
  `watchers` callback of `agent.chat` and `test.flagged` answers the
  `:fake_guard_watchers` app env.
  """

  alias PhoenixKitAI.TaskSpec

  def module_key, do: "agent"

  def enabled?, do: true

  def permission_metadata do
    %{
      key: "agent",
      label: "Assistant",
      icon: "hero-chat-bubble-left-right",
      description: "A stand-in for another module",
      sub_permissions: [%{key: "manage", label: "Manage", description: "Manage it"}]
    }
  end

  def ai_tasks do
    [
      %TaskSpec{
        key: "agent.chat",
        label: "Assistant chat",
        purpose: "Answer questions about the company's orders and products.",
        self_flag: true,
        private: true,
        block_group: "free_text",
        watchers: {__MODULE__, :watchers, []}
      },
      %TaskSpec{
        key: "test.flagged",
        label: "Flagged task",
        purpose: "Read the items in a shelf photo.",
        self_flag: true,
        watchers: {__MODULE__, :watchers, []}
      },
      %TaskSpec{key: "test.private", label: "Private task", self_flag: true, private: true},
      %TaskSpec{key: "test.quiet", label: "Quiet task", purpose: "Count things."},
      %TaskSpec{
        key: "test.rules",
        label: "Ruled task",
        sources: ["Allowed.Caller"],
        max_calls_per_hour: 2,
        max_tokens_per_call: 100
      }
    ]
  end

  def watchers(_user_uuid), do: Application.get_env(:phoenix_kit_ai, :fake_guard_watchers, [])
end
