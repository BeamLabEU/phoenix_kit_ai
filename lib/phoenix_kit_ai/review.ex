defmodule PhoenixKitAI.Review do
  @moduledoc """
  One AI result waiting for a person's word: `pending` until it is decided,
  then `confirmed` or `rejected`, once — `phoenix_kit_ai_reviews`, module chain
  V7. Created and decided through `PhoenixKitAI.Reviews`.

  - `kind` — the app's name for what is reviewed (`"listing_description"`);
    it picks the app's `on_decide` handler.
  - `subject_type` / `subject_id` — what the result is about, in the app's
    terms (any strings; no foreign key).
  - `request_uuid` — the usage row of the AI call that produced it, when
    known (`ON DELETE SET NULL`: journal retention may delete the row).
  - `payload` — the result itself, as the app will apply it (a JSON map; a
    reviewer's edit on confirming replaces it, the first proposal is kept in
    `metadata["proposed_payload"]`).
  - `decided_by_uuid`, `decided_at`, `decision_note` (≤ 1 000 characters).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending confirmed rejected)
  @note_max 1_000

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_ai_reviews" do
    field(:kind, :string)
    field(:subject_type, :string)
    field(:subject_id, :string)
    field(:request_uuid, UUIDv7)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:decided_by_uuid, UUIDv7)
    field(:decided_at, :utc_datetime_usec)
    field(:decision_note, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses a review can have."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Whether the review is still waiting for a decision."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: status}), do: status == "pending"

  @doc "The changeset of a new, pending review."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:kind, :subject_type, :subject_id, :request_uuid, :payload, :metadata])
    |> validate_required([:kind])
    |> update_change(:kind, &String.trim/1)
    # In code points, as the `character varying` columns count.
    |> validate_length(:kind, min: 1, max: 100, count: :codepoints)
    |> validate_length(:subject_type, max: 100, count: :codepoints)
    |> validate_length(:subject_id, max: 255, count: :codepoints)
    |> foreign_key_constraint(:request_uuid, name: :phoenix_kit_ai_reviews_request_uuid_fkey)
  end

  @doc "The longest decision note kept."
  @spec note_max() :: pos_integer()
  def note_max, do: @note_max
end
