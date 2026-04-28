defmodule PhoenixKitAI.Test.Repo.Migrations.AiModuleSetup do
  @moduledoc """
  Test-only migration that creates the three AI tables so the embedded
  `PhoenixKitAI.Test.Repo` has a schema matching production.

  In real deployments these tables are created by core `phoenix_kit`
  versioned migrations (see the module's AGENTS.md). Here we mirror
  them just enough that schemas, changesets, and CRUD tests exercise a
  real DB.
  """

  use Ecto.Migration

  def change do
    # Core phoenix_kit's V40 migration normally provides this in real
    # deployments. Re-create it here so the test DB is self-contained.
    execute(
      """
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """,
      "DROP FUNCTION IF EXISTS uuid_generate_v7()"
    )

    create table(:phoenix_kit_ai_endpoints, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:description, :string)
      add(:provider, :string, default: "openrouter", null: false)
      add(:api_key, :string)
      add(:base_url, :string)
      add(:provider_settings, :map, default: %{})
      add(:model, :string)
      add(:temperature, :float, default: 0.7)
      add(:max_tokens, :integer)
      add(:top_p, :float)
      add(:top_k, :integer)
      add(:frequency_penalty, :float)
      add(:presence_penalty, :float)
      add(:repetition_penalty, :float)
      add(:stop, {:array, :string})
      add(:seed, :integer)
      add(:image_size, :string)
      add(:image_quality, :string)
      add(:dimensions, :integer)
      add(:reasoning_enabled, :boolean)
      add(:reasoning_effort, :string)
      add(:reasoning_max_tokens, :integer)
      add(:reasoning_exclude, :boolean)
      add(:enabled, :boolean, default: true, null: false)
      add(:sort_order, :integer, default: 0, null: false)
      add(:last_validated_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:phoenix_kit_ai_endpoints, [:name]))

    create table(:phoenix_kit_ai_prompts, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:slug, :string)
      add(:description, :string)
      add(:system_prompt, :text)
      add(:content, :text)
      add(:variables, {:array, :string}, default: [])
      add(:enabled, :boolean, default: true, null: false)
      add(:sort_order, :integer, default: 0, null: false)
      add(:usage_count, :integer, default: 0, null: false)
      add(:last_used_at, :utc_datetime)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:phoenix_kit_ai_prompts, [:name], name: :phoenix_kit_ai_prompts_name_uidx)
    )

    create(
      unique_index(:phoenix_kit_ai_prompts, [:slug], name: :phoenix_kit_ai_prompts_slug_uidx)
    )

    create table(:phoenix_kit_ai_requests, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :endpoint_uuid,
        references(:phoenix_kit_ai_endpoints,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all
        )
      )

      add(:endpoint_name, :string)

      add(
        :prompt_uuid,
        references(:phoenix_kit_ai_prompts,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all
        )
      )

      add(:prompt_name, :string)
      add(:account_uuid, :uuid)
      add(:user_uuid, :uuid)
      add(:slot_index, :integer)
      add(:model, :string)
      add(:request_type, :string, default: "chat")
      add(:input_tokens, :integer, default: 0)
      add(:output_tokens, :integer, default: 0)
      add(:total_tokens, :integer, default: 0)
      add(:cost_cents, :integer)
      add(:latency_ms, :integer)
      add(:status, :string, default: "success")
      add(:error_message, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:phoenix_kit_ai_requests, [:endpoint_uuid]))
    create(index(:phoenix_kit_ai_requests, [:prompt_uuid]))
    create(index(:phoenix_kit_ai_requests, [:inserted_at]))

    # Minimal `phoenix_kit_settings` schema so `PhoenixKit.Settings`
    # calls inside our LiveView mounts succeed. Production schema is
    # owned by core phoenix_kit; the shape here tracks just the fields
    # core uses from Settings.get_boolean_setting/2 and friends.
    create table(:phoenix_kit_settings, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:key, :string, null: false)
      add(:value, :string)
      add(:value_json, :map)
      add(:module, :string)
      add(:date_added, :utc_datetime)
      add(:date_updated, :utc_datetime)
    end

    create(unique_index(:phoenix_kit_settings, [:key], name: :phoenix_kit_settings_key_uidx))

    # Minimal `phoenix_kit_activities` schema so our activity-logging
    # calls succeed in integration tests (the primary-op transaction
    # would otherwise abort on the missing-table error).
    create table(:phoenix_kit_activities, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:action, :string, null: false)
      add(:module, :string)
      add(:mode, :string)
      add(:actor_uuid, :uuid)
      add(:resource_type, :string)
      add(:resource_uuid, :uuid)
      add(:target_uuid, :uuid)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:phoenix_kit_activities, [:action]))
    create(index(:phoenix_kit_activities, [:module]))
    create(index(:phoenix_kit_activities, [:actor_uuid]))
  end
end
