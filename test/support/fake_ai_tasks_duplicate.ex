defmodule PhoenixKitAI.Test.FakeAITasksDuplicate do
  @moduledoc "Declares a key `PhoenixKitAI.Test.FakeAITasks` already declares, plus junk."

  def ai_tasks do
    [
      %PhoenixKitAI.TaskSpec{key: "test.plain", label: "Shadowed", needs: [:vision]},
      %{key: "not.a.spec"}
    ]
  end
end
