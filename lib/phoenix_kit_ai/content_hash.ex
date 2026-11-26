defmodule PhoenixKitAI.ContentHash do
  @moduledoc """
  One stored content hash: what a source (`namespace` + `source_key`) held the
  last time it was recorded — `phoenix_kit_ai_content_hashes`, module chain V7.
  Read and written through `PhoenixKitAI.ContentHashes`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_content_hashes" do
    field(:namespace, :string)
    field(:source_key, :string)
    field(:content_hash, :string)
    field(:content_bytes, :integer)
    field(:metadata, :map, default: %{})
    field(:changed_at, :utc_datetime_usec)
    field(:checked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
