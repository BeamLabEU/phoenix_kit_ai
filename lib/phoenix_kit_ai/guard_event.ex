defmodule PhoenixKitAI.GuardEvent do
  @moduledoc """
  Something the AI task guard noticed (`phoenix_kit_ai_guard_events`, this
  module's migration chain), written by `PhoenixKitAI.GuardEvents`.

  `kind` is one of `kinds/0`. `dedupe_key`, when set, is unique: an event
  that should be signalled once per window carries a key naming that window,
  and only the insert that went through signals. `ref` holds what the kind
  needs (the scope, unit and period of a limit). `reason` is never sent in a
  notification.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @kinds ~w(model_unfit limit_warning limit_reached limit_forgiven off_purpose off_purpose_signal anomaly blocked unblocked)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_guard_events" do
    field(:kind, :string)
    field(:task_key, :string)
    field(:user_uuid, UUIDv7)
    field(:endpoint_uuid, UUIDv7)
    field(:request_uuid, UUIDv7)
    field(:ref, :map)
    field(:reason, :string)
    field(:dedupe_key, :string)
    field(:actor_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime)
  end

  @doc "Every kind the table takes (its CHECK constraint)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
