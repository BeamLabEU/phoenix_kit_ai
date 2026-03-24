defmodule PhoenixKitAI.Migrations.V1 do
  @moduledoc """
  Consolidated migration for the PhoenixKit AI module.

  Creates the `phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts`, and
  `phoenix_kit_ai_requests` tables with their final schema (UUIDv7 primary keys,
  timestamptz columns, all indexes).

  All operations use IF NOT EXISTS / idempotent guards so this migration is safe
  to run even if the tables already exist from PhoenixKit core migrations.

  ## Tables

  ### phoenix_kit_ai_endpoints
  AI provider endpoint configurations (model, credentials, generation parameters).

  ### phoenix_kit_ai_prompts
  Reusable prompt templates with variable substitution.

  ### phoenix_kit_ai_requests
  Request logging for usage tracking, cost, and analytics.

  ## Settings Seeds
  Inserts default AI-related settings if not already present.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    # Ensure UUIDv7 generation function exists
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    execute("""
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
    END
    $$ LANGUAGE plpgsql VOLATILE;
    """)

    # ── phoenix_kit_ai_endpoints ─────────────────────────────────────────

    create_if_not_exists table(:phoenix_kit_ai_endpoints, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
      add(:name, :"varchar(100)", null: false)
      add(:description, :"varchar(500)")
      add(:provider, :"varchar(50)", null: false, default: "openrouter")
      add(:api_key, :text, null: false)
      add(:base_url, :"varchar(255)")
      add(:provider_settings, :map, default: "{}")
      add(:model, :"varchar(150)", null: false)
      add(:temperature, :float, default: 0.7)
      add(:max_tokens, :integer)
      add(:top_p, :float)
      add(:top_k, :integer)
      add(:frequency_penalty, :float)
      add(:presence_penalty, :float)
      add(:repetition_penalty, :float)
      add(:stop, {:array, :string})
      add(:seed, :integer)
      add(:image_size, :"varchar(20)")
      add(:image_quality, :"varchar(20)")
      add(:dimensions, :integer)
      add(:enabled, :boolean, null: false, default: true)
      add(:sort_order, :integer, null: false, default: 0)
      add(:last_validated_at, :utc_datetime_usec)
      add(:reasoning_enabled, :boolean)
      add(:reasoning_effort, :"varchar(20)")
      add(:reasoning_max_tokens, :integer)
      add(:reasoning_exclude, :boolean)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists(
      index(:phoenix_kit_ai_endpoints, [:enabled],
        name: :phoenix_kit_ai_endpoints_enabled_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_endpoints, [:sort_order],
        name: :phoenix_kit_ai_endpoints_sort_order_idx,
        prefix: prefix
      )
    )

    # ── phoenix_kit_ai_prompts ───────────────────────────────────────────

    create_if_not_exists table(:phoenix_kit_ai_prompts, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:content, :text, null: false)
      add(:system_prompt, :text)
      add(:variables, {:array, :string}, null: false, default: [])
      add(:enabled, :boolean, null: false, default: true)
      add(:sort_order, :integer, null: false, default: 0)
      add(:usage_count, :integer, null: false, default: 0)
      add(:last_used_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: "{}")
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_ai_prompts, [:name],
        name: :phoenix_kit_ai_prompts_name_uidx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      unique_index(:phoenix_kit_ai_prompts, [:slug],
        name: :phoenix_kit_ai_prompts_slug_uidx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_prompts, [:enabled],
        name: :phoenix_kit_ai_prompts_enabled_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_prompts, [:sort_order],
        name: :phoenix_kit_ai_prompts_sort_order_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_prompts, [:usage_count],
        name: :phoenix_kit_ai_prompts_usage_count_idx,
        prefix: prefix
      )
    )

    # ── phoenix_kit_ai_requests ──────────────────────────────────────────

    create_if_not_exists table(:phoenix_kit_ai_requests, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
      add(:model, :"varchar(100)")
      add(:request_type, :"varchar(50)", null: false, default: "text_completion")
      add(:input_tokens, :integer, null: false, default: 0)
      add(:output_tokens, :integer, null: false, default: 0)
      add(:total_tokens, :integer, null: false, default: 0)
      add(:cost_cents, :integer)
      add(:latency_ms, :integer)
      add(:status, :"varchar(20)", null: false, default: "success")
      add(:error_message, :text)
      add(:metadata, :map, default: "{}")
      add(:endpoint_name, :"varchar(100)")
      add(:prompt_name, :"varchar(255)")
      add(:user_uuid, :uuid)
      add(:endpoint_uuid, :uuid)
      add(:prompt_uuid, :uuid)
      add(:account_uuid, :uuid)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:status],
        name: :phoenix_kit_ai_requests_status_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:inserted_at],
        name: :phoenix_kit_ai_requests_inserted_at_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:model],
        name: :phoenix_kit_ai_requests_model_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:account_uuid],
        name: :phoenix_kit_ai_requests_account_uuid_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:prompt_uuid],
        name: :phoenix_kit_ai_requests_prompt_uuid_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:user_uuid],
        name: :phoenix_kit_ai_requests_user_uuid_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_ai_requests, [:endpoint_uuid],
        name: :phoenix_kit_ai_requests_endpoint_uuid_idx,
        prefix: prefix
      )
    )

    # ── Foreign keys ─────────────────────────────────────────────────────

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_user_uuid_fkey'
        AND conrelid = '#{prefix_table("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_user_uuid_fkey
        FOREIGN KEY (user_uuid)
        REFERENCES #{prefix_table("phoenix_kit_users", prefix)}(uuid)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_endpoint_uuid_fkey'
        AND conrelid = '#{prefix_table("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_endpoint_uuid_fkey
        FOREIGN KEY (endpoint_uuid)
        REFERENCES #{prefix_table("phoenix_kit_ai_endpoints", prefix)}(uuid)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_prompt_uuid_fkey'
        AND conrelid = '#{prefix_table("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_prompt_uuid_fkey
        FOREIGN KEY (prompt_uuid)
        REFERENCES #{prefix_table("phoenix_kit_ai_prompts", prefix)}(uuid)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    # ── Settings seeds ───────────────────────────────────────────────────

    if table_exists?(:phoenix_kit_settings, prefix) do
      execute("""
      INSERT INTO #{prefix_table("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
      VALUES
        ('ai_module_enabled', 'false', 'ai', NOW(), NOW())
      ON CONFLICT (key) DO NOTHING
      """)
    end

    # ── Column comments ──────────────────────────────────────────────────

    execute("""
    COMMENT ON COLUMN #{prefix_table("phoenix_kit_ai_endpoints", prefix)}.provider_settings IS
    'JSONB storage for provider-specific configuration (custom headers, organization ID, etc.).'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix_table("phoenix_kit_ai_endpoints", prefix)}.api_key IS
    'Encrypted API key for the provider. Stored as text, encrypted at the application layer.'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix_table("phoenix_kit_ai_requests", prefix)}.cost_cents IS
    'Cost in nanodollars (1/1,000,000 USD) for precision with cheap API calls.'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix_table("phoenix_kit_ai_requests", prefix)}.metadata IS
    'JSONB storage for request context: source, caller stacktrace, request ID, node, PID, memory.'
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    # Drop foreign key constraints
    for constraint <- ~w(
      phoenix_kit_ai_requests_user_uuid_fkey
      phoenix_kit_ai_requests_endpoint_uuid_fkey
      phoenix_kit_ai_requests_prompt_uuid_fkey
    ) do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{constraint}'
          AND conrelid = '#{prefix_table("phoenix_kit_ai_requests", prefix)}'::regclass
        ) THEN
          ALTER TABLE #{prefix_table("phoenix_kit_ai_requests", prefix)}
          DROP CONSTRAINT #{constraint};
        END IF;
      END $$;
      """)
    end

    # Drop request indexes
    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:endpoint_uuid],
        name: :phoenix_kit_ai_requests_endpoint_uuid_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:user_uuid],
        name: :phoenix_kit_ai_requests_user_uuid_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:prompt_uuid],
        name: :phoenix_kit_ai_requests_prompt_uuid_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:account_uuid],
        name: :phoenix_kit_ai_requests_account_uuid_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:model],
        name: :phoenix_kit_ai_requests_model_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:inserted_at],
        name: :phoenix_kit_ai_requests_inserted_at_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_requests, [:status],
        name: :phoenix_kit_ai_requests_status_idx,
        prefix: prefix
      )
    )

    # Drop prompt indexes
    drop_if_exists(
      index(:phoenix_kit_ai_prompts, [:usage_count],
        name: :phoenix_kit_ai_prompts_usage_count_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_prompts, [:sort_order],
        name: :phoenix_kit_ai_prompts_sort_order_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_prompts, [:enabled],
        name: :phoenix_kit_ai_prompts_enabled_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_prompts, [:slug],
        name: :phoenix_kit_ai_prompts_slug_uidx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_prompts, [:name],
        name: :phoenix_kit_ai_prompts_name_uidx,
        prefix: prefix
      )
    )

    # Drop endpoint indexes
    drop_if_exists(
      index(:phoenix_kit_ai_endpoints, [:sort_order],
        name: :phoenix_kit_ai_endpoints_sort_order_idx,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:phoenix_kit_ai_endpoints, [:enabled],
        name: :phoenix_kit_ai_endpoints_enabled_idx,
        prefix: prefix
      )
    )

    # Drop tables (requests first due to FK dependencies)
    drop_if_exists(table(:phoenix_kit_ai_requests, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_ai_prompts, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_ai_endpoints, prefix: prefix))

    if table_exists?(:phoenix_kit_settings, prefix) do
      execute("""
      DELETE FROM #{prefix_table("phoenix_kit_settings", prefix)}
      WHERE key IN ('ai_module_enabled')
      """)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp table_exists?(table_name, prefix) do
    schema = prefix || "public"

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{schema}'
      AND table_name = '#{table_name}'
    )
    """

    %{rows: [[exists]]} = repo().query!(query)
    exists
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
