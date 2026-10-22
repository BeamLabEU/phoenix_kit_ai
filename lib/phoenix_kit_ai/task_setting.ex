defmodule PhoenixKitAI.TaskSetting do
  @moduledoc """
  What an admin set for an AI task (`phoenix_kit_ai_task_settings`, this
  module's migration chain): one row per task key. Written through
  `PhoenixKitAI.TaskLimits`, which checks the `ai.manage` permission.

  `limits` is `%{"task" => %{unit => %{period => amount}}, "user" => …}`:
  the task's own limits and the default for each user in it (see
  `PhoenixKitAI.TaskLimits`). `warn_percent` is nil for the default (80).
  `guard_mode` (`off` / `self_flag`, set with
  `PhoenixKitAI.TaskLimits.set_guard_mode/3`) overrides the declaration's
  `self_flag`; the classifier fields are for a later part of the guard.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_task_settings" do
    field(:task_key, :string)
    field(:purpose_override, :string)
    field(:guard_mode, :string)
    field(:classifier_endpoint_uuid, UUIDv7)
    field(:classifier_sample_percent, :integer)
    field(:auto_block_threshold, :integer)
    field(:limits, :map, default: %{})
    field(:warn_percent, :integer)
    field(:updated_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end
end
