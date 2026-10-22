defmodule PhoenixKitAI.ModelCapability do
  @moduledoc """
  One row of the capability snapshot (`phoenix_kit_ai_model_capabilities`,
  this module's own migration chain): what the catalogue said a model can do,
  for a model an endpoint uses, keyed by the endpoint's resolved base URL.

  Written and read only by `PhoenixKitAI.Capabilities`, which loads the rows
  into its cache at start so a restart without network does not turn every
  model into `:unknown`. The flags are `"yes"`, `"no"` or `"unknown"`
  (`file_input` and `image_output` came with schema V2).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_model_capabilities" do
    field(:base_url, :string)
    field(:model, :string)
    field(:vision, :string, default: "unknown")
    field(:tools, :string, default: "unknown")
    field(:json_schema, :string, default: "unknown")
    field(:json, :string, default: "unknown")
    field(:file_input, :string, default: "unknown")
    field(:image_output, :string, default: "unknown")
    field(:context_length, :integer)
    field(:lifecycle, :string)
    field(:fetched_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end
end
