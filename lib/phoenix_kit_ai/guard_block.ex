defmodule PhoenixKitAI.GuardBlock do
  @moduledoc """
  A person blocked from a group of AI tasks until the block is lifted
  (`phoenix_kit_ai_guard_blocks`, this module's migration chain), written by
  `PhoenixKitAI.GuardBlocks`.

  `block_group` is the group the block is on: a task's `block_group`, or its
  key when it names none. `origin_task_key` and `origin_event_uuid` say where
  the block was set from (a task's page, a flag). `private` is the strictest
  of the group's tasks: the reason of a private block is shown only to the
  holders of `ai.manage`. A block is active while `lifted_at` is nil; at most
  one is active per group and person.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_guard_blocks" do
    field(:block_group, :string)
    field(:user_uuid, UUIDv7)
    field(:origin_task_key, :string)
    field(:origin_event_uuid, UUIDv7)
    field(:private, :boolean, default: false)
    field(:reason, :string)
    field(:blocked_by_uuid, UUIDv7)
    field(:blocked_at, :utc_datetime)
    field(:lifted_at, :utc_datetime)
    field(:lifted_by_uuid, UUIDv7)
    field(:lift_note, :string)
  end
end
