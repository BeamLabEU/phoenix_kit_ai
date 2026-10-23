defmodule PhoenixKitAI.TaskUserLimit do
  @moduledoc """
  A user's personal limits in an AI task (`phoenix_kit_ai_task_user_limits`,
  this module's migration chain): `limits` is `%{unit => %{period =>
  amount}}`, each amount set here overriding the task's default for its
  users (`PhoenixKitAI.TaskLimits`). Deleted with the user.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_task_user_limits" do
    field(:task_key, :string)
    field(:user_uuid, UUIDv7)
    field(:limits, :map, default: %{})

    timestamps(type: :utc_datetime)
  end
end
