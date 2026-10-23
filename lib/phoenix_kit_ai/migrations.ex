defmodule PhoenixKitAI.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_ai` — the protocol core's
  `mix phoenix_kit.update` discovers through `PhoenixKitAI.migration_module/0`
  (`current_version/0`, `migrated_version_runtime/1`, `up/1`, `down/1`). Same
  shape as `PhoenixKitAgent.Migrations`: two version readers, `up/1`
  re-reading the version before it changes anything, the SQL kept as data
  (`up_statements/2`, `down_statements/2`).

  This chain holds only objects core does not create. The tables
  `phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts` and
  `phoenix_kit_ai_requests` stay in core's chain and are never touched here.

  ## Tables (V1)

    * `phoenix_kit_ai_model_capabilities` — the snapshot of what the catalogue
      says each model an endpoint uses can do (`PhoenixKitAI.Capabilities`),
      one row per resolved base URL and model; the flags are `yes`, `no` or
      `unknown`.

  ## V2: the task guard's settings and events

    * `phoenix_kit_ai_task_settings` — what an admin set for an AI task (one
      row per task key): its limits, the warn percent, and the guard mode and
      classifier fields later parts of the guard read.
    * `phoenix_kit_ai_task_user_limits` — a user's personal limits in a task
      (one row per task key and user).
    * `phoenix_kit_ai_guard_events` — what the guard noticed (`kind`, checked
      against the known kinds; a new kind is a new version). `dedupe_key` is
      unique where it is set, so a signal sent once per window is an insert
      that either happens or does not.
    * Two more flags on `phoenix_kit_ai_model_capabilities`: `file_input`
      and `image_output` (`yes`, `no` or `unknown`, default `unknown`),
      for what a later version of the capability cache reads.
    * An index on the journal (core's `phoenix_kit_ai_requests`):
      `((metadata->>'task'), inserted_at)`, with no condition on the status,
      for the task limits and the models that worked in a task. Core's
      schema check reports extra columns of its tables, not extra indexes,
      so it is not drift there; the index is dropped with V2.

  ## V3: blocks

    * `phoenix_kit_ai_guard_blocks` — a person blocked from a group of AI
      tasks (`block_group`; a task's own key unless it names a group) until
      the block is lifted. The row keeps where it came from (the task and
      the flag), whether its reason is private, who set it and when, and
      who lifted it, when and why. One active block per group and person:
      a unique index on (`block_group`, `user_uuid`) where `lifted_at` is
      NULL; lifted blocks stay as the history. The guard event kinds of V2
      already include `off_purpose`, `off_purpose_signal`, `anomaly`,
      `blocked` and `unblocked`.

  ## V4: money in dollars

  Core's V223 turned the journal's `cost_cents` (millionths of a dollar) into
  `cost`, dollars. V4 does the same for what this module stores, so every
  amount is dollars (`PhoenixKitAI.Money`). It is data, not shape, and it
  converts by shape, so a re-run converts nothing twice:

    * the spend caps `ai_daily_budget`, `ai_daily_budget_per_endpoint` and
      `ai_daily_budget_per_user` (core's `phoenix_kit_settings`, digits = millionths)
      are copied to `ai_daily_cap`, `ai_daily_cap_per_endpoint` and
      `ai_daily_cap_per_user` as dollar strings (`"5.00"`), only where the new
      key does not exist yet; the old keys are left as they were;
    * a money cell of a task's limits (`phoenix_kit_ai_task_settings.limits`,
      `phoenix_kit_ai_task_user_limits.limits`) that is a JSON number or a
      digits-only string becomes a dollar string;
    * an endpoint's manual price (`phoenix_kit_ai_endpoints.provider_settings
      -> 'pricing'`) whose halves are numbers becomes dollar strings per 1M.

  It needs core's V223 first (the `cost` column) and stops otherwise. Down to 3
  turns the task limits and prices back into integer millionths and deletes the
  new cap keys (the old ones still hold the released values).

  ## Version marker

  `COMMENT ON TABLE phoenix_kit_ai_model_capabilities IS 'ai_schema:<N>'`.
  No table, or one without an `ai_schema:` comment, reads as version 0.

  ## Idempotency and rollback

  Every statement guards itself (`IF NOT EXISTS` / `IF EXISTS`), so the chain
  can be re-run. `down/1` to version 0 drops the snapshot table; it is
  rebuilt from the providers' catalogues on the next refresh.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @current_version 4
  @default_prefix "public"
  @marker_prefix "ai_schema:"
  @version_table "phoenix_kit_ai_model_capabilities"

  @kinds ~w(model_unfit limit_warning limit_reached limit_forgiven off_purpose off_purpose_signal anomaly blocked unblocked)
  @guard_modes ~w(off self_flag classifier self_flag+classifier)
  @v2_flags ~w(file_input image_output)

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `ai_schema:<N>` marker."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies the chain up to `opts[:version]` (default `current_version/0`).
  Migration context only. Re-reads the installed version first: a database
  already at (or past) the target is left alone.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration context only. To 0 it
  drops every table of this chain — see the moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The installed version, read inside a migration through `Ecto.Migration`'s
  `repo()`. No rescue: a version that cannot be read aborts the migration.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  The installed version, read outside a migration (what `mix phoenix_kit.update`
  calls) through PhoenixKit's configured repo. An invalid prefix raises; a
  database that cannot be reached reads as `0`, which only costs a redundant
  migration file because `up/1` re-reads the version before it changes
  anything.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` runs, as data. `target` is how far to go (default
  `current_version/0`); `0` is nothing.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = valid_prefix!(prefix)

    if target == 0 do
      []
    else
      Enum.flat_map(1..target, &version_up(&1, prefix)) ++ [marker_statement(prefix, target)]
    end
  end

  @doc """
  The SQL `down/1` runs, as data: each later version undone, newest first,
  then the marker re-stamped (to `0` there is no table left to stamp).
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = valid_prefix!(prefix)

    later = Enum.flat_map(@current_version..(target + 1)//-1, &version_down(&1, prefix))
    if target == 0, do: later, else: later ++ [marker_statement(prefix, target)]
  end

  defp version_up(1, prefix), do: v1_statements(prefix)
  defp version_up(2, prefix), do: v2_statements(prefix)
  defp version_up(3, prefix), do: v3_statements(prefix)
  defp version_up(4, prefix), do: v4_statements(prefix)

  defp version_down(1, prefix),
    do: [
      "DROP TABLE IF EXISTS #{Helpers.qualify_table("phoenix_kit_ai_model_capabilities", prefix)}"
    ]

  defp version_down(2, prefix), do: v2_down_statements(prefix)

  defp version_down(3, prefix),
    do: ["DROP TABLE IF EXISTS #{Helpers.qualify_table("phoenix_kit_ai_guard_blocks", prefix)}"]

  defp version_down(4, prefix), do: v4_down_statements(prefix)

  # ── V1 ────────────────────────────────────────────────────────────────

  defp v1_statements(prefix) do
    uuid7 = Helpers.uuid_v7_call(prefix)
    caps = Helpers.qualify_table("phoenix_kit_ai_model_capabilities", prefix)

    [
      """
      CREATE TABLE IF NOT EXISTS #{caps} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        base_url text NOT NULL,
        model text NOT NULL,
        vision character varying(8) DEFAULT 'unknown' NOT NULL,
        tools character varying(8) DEFAULT 'unknown' NOT NULL,
        json_schema character varying(8) DEFAULT 'unknown' NOT NULL,
        json character varying(8) DEFAULT 'unknown' NOT NULL,
        context_length integer,
        lifecycle character varying(16),
        fetched_at timestamp without time zone NOT NULL,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        updated_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_ai_model_capabilities_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_ai_model_capabilities_flags_check CHECK (
          vision IN ('yes', 'no', 'unknown') AND
          tools IN ('yes', 'no', 'unknown') AND
          json_schema IN ('yes', 'no', 'unknown') AND
          json IN ('yes', 'no', 'unknown')
        )
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_model_capabilities_base_url_model_index ON #{caps} (base_url, model)"
    ]
  end

  # ── V2 ────────────────────────────────────────────────────────────────

  defp v2_statements(prefix) do
    uuid7 = Helpers.uuid_v7_call(prefix)
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    endpoints = Helpers.qualify_table("phoenix_kit_ai_endpoints", prefix)
    requests = Helpers.qualify_table("phoenix_kit_ai_requests", prefix)
    settings = Helpers.qualify_table("phoenix_kit_ai_task_settings", prefix)
    user_limits = Helpers.qualify_table("phoenix_kit_ai_task_user_limits", prefix)
    events = Helpers.qualify_table("phoenix_kit_ai_guard_events", prefix)
    caps = Helpers.qualify_table("phoenix_kit_ai_model_capabilities", prefix)

    Enum.map(@v2_flags, &flag_column(caps, &1)) ++
      [
        """
        CREATE TABLE IF NOT EXISTS #{settings} (
          uuid uuid DEFAULT #{uuid7} NOT NULL,
          task_key character varying(255) NOT NULL,
          purpose_override text,
          guard_mode character varying(32),
          classifier_endpoint_uuid uuid,
          classifier_sample_percent integer,
          auto_block_threshold integer,
          limits jsonb DEFAULT '{}'::jsonb NOT NULL,
          warn_percent integer,
          updated_by_uuid uuid,
          inserted_at timestamp without time zone DEFAULT now() NOT NULL,
          updated_at timestamp without time zone DEFAULT now() NOT NULL,
          CONSTRAINT phoenix_kit_ai_task_settings_pkey PRIMARY KEY (uuid),
          CONSTRAINT phoenix_kit_ai_task_settings_classifier_endpoint_uuid_fkey
            FOREIGN KEY (classifier_endpoint_uuid) REFERENCES #{endpoints}(uuid) ON DELETE SET NULL,
          CONSTRAINT phoenix_kit_ai_task_settings_updated_by_uuid_fkey
            FOREIGN KEY (updated_by_uuid) REFERENCES #{users}(uuid) ON DELETE SET NULL,
          CONSTRAINT phoenix_kit_ai_task_settings_values_check CHECK (
            (guard_mode IS NULL OR guard_mode IN (#{sql_list(@guard_modes)})) AND
            (warn_percent IS NULL OR warn_percent BETWEEN 1 AND 100) AND
            (classifier_sample_percent IS NULL OR classifier_sample_percent BETWEEN 0 AND 100) AND
            (auto_block_threshold IS NULL OR auto_block_threshold > 0)
          )
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_task_settings_task_key_index ON #{settings} (task_key)",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_task_settings_classifier_endpoint_uuid_index ON #{settings} (classifier_endpoint_uuid) WHERE classifier_endpoint_uuid IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_task_settings_updated_by_uuid_index ON #{settings} (updated_by_uuid) WHERE updated_by_uuid IS NOT NULL",
        """
        CREATE TABLE IF NOT EXISTS #{user_limits} (
          uuid uuid DEFAULT #{uuid7} NOT NULL,
          task_key character varying(255) NOT NULL,
          user_uuid uuid NOT NULL,
          limits jsonb DEFAULT '{}'::jsonb NOT NULL,
          inserted_at timestamp without time zone DEFAULT now() NOT NULL,
          updated_at timestamp without time zone DEFAULT now() NOT NULL,
          CONSTRAINT phoenix_kit_ai_task_user_limits_pkey PRIMARY KEY (uuid),
          CONSTRAINT phoenix_kit_ai_task_user_limits_user_uuid_fkey
            FOREIGN KEY (user_uuid) REFERENCES #{users}(uuid) ON DELETE CASCADE
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_task_user_limits_task_key_user_uuid_index ON #{user_limits} (task_key, user_uuid)",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_task_user_limits_user_uuid_index ON #{user_limits} (user_uuid)",
        """
        CREATE TABLE IF NOT EXISTS #{events} (
          uuid uuid DEFAULT #{uuid7} NOT NULL,
          kind character varying(32) NOT NULL,
          task_key character varying(255),
          user_uuid uuid,
          endpoint_uuid uuid,
          request_uuid uuid,
          ref jsonb,
          reason text,
          dedupe_key text,
          actor_uuid uuid,
          inserted_at timestamp without time zone DEFAULT now() NOT NULL,
          CONSTRAINT phoenix_kit_ai_guard_events_pkey PRIMARY KEY (uuid),
          CONSTRAINT phoenix_kit_ai_guard_events_user_uuid_fkey
            FOREIGN KEY (user_uuid) REFERENCES #{users}(uuid) ON DELETE CASCADE,
          CONSTRAINT phoenix_kit_ai_guard_events_endpoint_uuid_fkey
            FOREIGN KEY (endpoint_uuid) REFERENCES #{endpoints}(uuid) ON DELETE SET NULL,
          CONSTRAINT phoenix_kit_ai_guard_events_request_uuid_fkey
            FOREIGN KEY (request_uuid) REFERENCES #{requests}(uuid) ON DELETE SET NULL,
          CONSTRAINT phoenix_kit_ai_guard_events_actor_uuid_fkey
            FOREIGN KEY (actor_uuid) REFERENCES #{users}(uuid) ON DELETE SET NULL,
          CONSTRAINT phoenix_kit_ai_guard_events_kind_check CHECK (kind IN (#{sql_list(@kinds)})),
          CONSTRAINT phoenix_kit_ai_guard_events_reason_check
            CHECK (reason IS NULL OR char_length(reason) <= 500)
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_dedupe_key_index ON #{events} (dedupe_key) WHERE dedupe_key IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_task_kind_inserted_at_index ON #{events} (task_key, kind, inserted_at)",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_user_uuid_index ON #{events} (user_uuid) WHERE user_uuid IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_endpoint_uuid_index ON #{events} (endpoint_uuid) WHERE endpoint_uuid IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_request_uuid_index ON #{events} (request_uuid) WHERE request_uuid IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_events_actor_uuid_index ON #{events} (actor_uuid) WHERE actor_uuid IS NOT NULL",
        # On core's journal: an object of this chain, not of core's (see the moduledoc).
        "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_requests_task_inserted_at_index ON #{requests} ((metadata->>'task'), inserted_at)"
      ]
  end

  # The column's CHECK rides on ADD COLUMN, so a re-run skips both.
  defp flag_column(table, flag) do
    "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS #{flag} character varying(8) DEFAULT 'unknown' NOT NULL " <>
      "CONSTRAINT phoenix_kit_ai_model_capabilities_#{flag}_check CHECK (#{flag} IN ('yes', 'no', 'unknown'))"
  end

  defp v2_down_statements(prefix) do
    index = Helpers.qualify_table("phoenix_kit_ai_requests_task_inserted_at_index", prefix)
    caps = Helpers.qualify_table("phoenix_kit_ai_model_capabilities", prefix)

    ["DROP INDEX IF EXISTS #{index}"] ++
      Enum.map(@v2_flags, &"ALTER TABLE #{caps} DROP COLUMN IF EXISTS #{&1}") ++
      Enum.map(
        ~w(phoenix_kit_ai_guard_events phoenix_kit_ai_task_user_limits phoenix_kit_ai_task_settings),
        &"DROP TABLE IF EXISTS #{Helpers.qualify_table(&1, prefix)}"
      )
  end

  # ── V3 ────────────────────────────────────────────────────────────────

  defp v3_statements(prefix) do
    uuid7 = Helpers.uuid_v7_call(prefix)
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    events = Helpers.qualify_table("phoenix_kit_ai_guard_events", prefix)
    blocks = Helpers.qualify_table("phoenix_kit_ai_guard_blocks", prefix)

    [
      """
      CREATE TABLE IF NOT EXISTS #{blocks} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        block_group character varying(255) NOT NULL,
        user_uuid uuid NOT NULL,
        origin_task_key character varying(255),
        origin_event_uuid uuid,
        private boolean DEFAULT false NOT NULL,
        reason text,
        blocked_by_uuid uuid,
        blocked_at timestamp without time zone DEFAULT now() NOT NULL,
        lifted_at timestamp without time zone,
        lifted_by_uuid uuid,
        lift_note text,
        CONSTRAINT phoenix_kit_ai_guard_blocks_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_ai_guard_blocks_user_uuid_fkey
          FOREIGN KEY (user_uuid) REFERENCES #{users}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_ai_guard_blocks_origin_event_uuid_fkey
          FOREIGN KEY (origin_event_uuid) REFERENCES #{events}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_ai_guard_blocks_blocked_by_uuid_fkey
          FOREIGN KEY (blocked_by_uuid) REFERENCES #{users}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_ai_guard_blocks_lifted_by_uuid_fkey
          FOREIGN KEY (lifted_by_uuid) REFERENCES #{users}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_ai_guard_blocks_text_check CHECK (
          (reason IS NULL OR char_length(reason) <= 500) AND
          (lift_note IS NULL OR char_length(lift_note) <= 500)
        )
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_ai_guard_blocks_active_index ON #{blocks} (block_group, user_uuid) WHERE lifted_at IS NULL",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_blocks_user_uuid_index ON #{blocks} (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_blocks_origin_event_uuid_index ON #{blocks} (origin_event_uuid) WHERE origin_event_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_blocks_blocked_by_uuid_index ON #{blocks} (blocked_by_uuid) WHERE blocked_by_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_ai_guard_blocks_lifted_by_uuid_index ON #{blocks} (lifted_by_uuid) WHERE lifted_by_uuid IS NOT NULL"
    ]
  end

  defp sql_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  # ── V4 ────────────────────────────────────────────────────────────────

  @cap_keys [
    {"ai_daily_budget", "ai_daily_cap"},
    {"ai_daily_budget_per_endpoint", "ai_daily_cap_per_endpoint"},
    {"ai_daily_budget_per_user", "ai_daily_cap_per_user"}
  ]

  defp v4_statements(prefix) do
    settings = Helpers.qualify_table("phoenix_kit_settings", prefix)
    task_settings = Helpers.qualify_table("phoenix_kit_ai_task_settings", prefix)
    user_limits = Helpers.qualify_table("phoenix_kit_ai_task_user_limits", prefix)
    endpoints = Helpers.qualify_table("phoenix_kit_ai_endpoints", prefix)

    [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_ai_requests'
            AND column_name = 'cost'
        ) THEN
          RAISE EXCEPTION 'phoenix_kit_ai V4 needs core''s V223 (phoenix_kit_ai_requests.cost); run core''s migrations first';
        END IF;
      END
      $$
      """
    ] ++
      Enum.map(@cap_keys, fn {old, new} ->
        # The released parser read the leading digits of the trimmed value.
        """
        INSERT INTO #{settings} (key, value, module, date_added, date_updated)
        SELECT '#{new}', #{dollars_sql("substring(trim(value) from '^[0-9]+')::numeric / 1000000")},
               'ai', now(), now()
        FROM #{settings}
        WHERE key = '#{old}' AND trim(value) ~ '^[0-9]+'
        ON CONFLICT (key) DO NOTHING
        """
      end) ++
      [
        """
        DO $$
        DECLARE
          r record;
          scope text;
          period text;
          cell jsonb;
          converted jsonb;
        BEGIN
          FOR r IN SELECT uuid, limits FROM #{task_settings}
                   WHERE jsonb_typeof(limits) = 'object' LOOP
            converted := r.limits;
            FOR scope IN SELECT jsonb_object_keys(r.limits) LOOP
              IF jsonb_typeof(r.limits -> scope -> 'money') = 'object' THEN
                FOR period IN SELECT jsonb_object_keys(r.limits -> scope -> 'money') LOOP
                  cell := r.limits -> scope -> 'money' -> period;
                  IF #{legacy_cell_sql("cell")} THEN
                    converted := jsonb_set(converted, ARRAY[scope, 'money', period],
                      to_jsonb(#{dollars_sql(cell_numeric_sql("cell") <> " / 1000000")}));
                  END IF;
                END LOOP;
              END IF;
            END LOOP;
            IF converted IS DISTINCT FROM r.limits THEN
              UPDATE #{task_settings} SET limits = converted WHERE uuid = r.uuid;
            END IF;
          END LOOP;

          FOR r IN SELECT uuid, limits FROM #{user_limits}
                   WHERE jsonb_typeof(limits -> 'money') = 'object' LOOP
            converted := r.limits;
            FOR period IN SELECT jsonb_object_keys(r.limits -> 'money') LOOP
              cell := r.limits -> 'money' -> period;
              IF #{legacy_cell_sql("cell")} THEN
                converted := jsonb_set(converted, ARRAY['money', period],
                  to_jsonb(#{dollars_sql(cell_numeric_sql("cell") <> " / 1000000")}));
              END IF;
            END LOOP;
            IF converted IS DISTINCT FROM r.limits THEN
              UPDATE #{user_limits} SET limits = converted WHERE uuid = r.uuid;
            END IF;
          END LOOP;

          FOR r IN SELECT uuid, provider_settings FROM #{endpoints}
                   WHERE jsonb_typeof(provider_settings -> 'pricing') = 'object' LOOP
            converted := r.provider_settings;
            FOR period IN SELECT unnest(ARRAY['input', 'output']) LOOP
              cell := r.provider_settings -> 'pricing' -> period;
              IF jsonb_typeof(cell) = 'number' THEN
                converted := jsonb_set(converted, ARRAY['pricing', period],
                  to_jsonb(#{dollars_sql("(cell::text)::numeric / 1000000")}));
              END IF;
            END LOOP;
            IF converted IS DISTINCT FROM r.provider_settings THEN
              UPDATE #{endpoints} SET provider_settings = converted WHERE uuid = r.uuid;
            END IF;
          END LOOP;
        END
        $$
        """
      ]
  end

  defp v4_down_statements(prefix) do
    settings = Helpers.qualify_table("phoenix_kit_settings", prefix)
    task_settings = Helpers.qualify_table("phoenix_kit_ai_task_settings", prefix)
    user_limits = Helpers.qualify_table("phoenix_kit_ai_task_user_limits", prefix)
    endpoints = Helpers.qualify_table("phoenix_kit_ai_endpoints", prefix)
    new_keys = Enum.map_join(@cap_keys, ", ", fn {_old, new} -> "'#{new}'" end)

    [
      "DELETE FROM #{settings} WHERE key IN (#{new_keys})",
      """
      DO $$
      DECLARE
        r record;
        scope text;
        period text;
        cell jsonb;
        converted jsonb;
      BEGIN
        FOR r IN SELECT uuid, limits FROM #{task_settings}
                 WHERE jsonb_typeof(limits) = 'object' LOOP
          converted := r.limits;
          FOR scope IN SELECT jsonb_object_keys(r.limits) LOOP
            IF jsonb_typeof(r.limits -> scope -> 'money') = 'object' THEN
              FOR period IN SELECT jsonb_object_keys(r.limits -> scope -> 'money') LOOP
                cell := r.limits -> scope -> 'money' -> period;
                IF #{dollar_cell_sql("cell")} THEN
                  converted := jsonb_set(converted, ARRAY[scope, 'money', period],
                    to_jsonb(round((cell #>> '{}')::numeric * 1000000)::bigint));
                END IF;
              END LOOP;
            END IF;
          END LOOP;
          IF converted IS DISTINCT FROM r.limits THEN
            UPDATE #{task_settings} SET limits = converted WHERE uuid = r.uuid;
          END IF;
        END LOOP;

        FOR r IN SELECT uuid, limits FROM #{user_limits}
                 WHERE jsonb_typeof(limits -> 'money') = 'object' LOOP
          converted := r.limits;
          FOR period IN SELECT jsonb_object_keys(r.limits -> 'money') LOOP
            cell := r.limits -> 'money' -> period;
            IF #{dollar_cell_sql("cell")} THEN
              converted := jsonb_set(converted, ARRAY['money', period],
                to_jsonb(round((cell #>> '{}')::numeric * 1000000)::bigint));
            END IF;
          END LOOP;
          IF converted IS DISTINCT FROM r.limits THEN
            UPDATE #{user_limits} SET limits = converted WHERE uuid = r.uuid;
          END IF;
        END LOOP;

        FOR r IN SELECT uuid, provider_settings FROM #{endpoints}
                 WHERE jsonb_typeof(provider_settings -> 'pricing') = 'object' LOOP
          converted := r.provider_settings;
          FOR period IN SELECT unnest(ARRAY['input', 'output']) LOOP
            cell := r.provider_settings -> 'pricing' -> period;
            IF #{dollar_cell_sql("cell")} THEN
              converted := jsonb_set(converted, ARRAY['pricing', period],
                to_jsonb(round((cell #>> '{}')::numeric * 1000000)::bigint));
            END IF;
          END LOOP;
          IF converted IS DISTINCT FROM r.provider_settings THEN
            UPDATE #{endpoints} SET provider_settings = converted WHERE uuid = r.uuid;
          END IF;
        END LOOP;
      END
      $$
      """
    ]
  end

  # A money cell in the released shape: a JSON number, or a string of digits
  # only (`PhoenixKitAI.Money.legacy_amount?/1`).
  defp legacy_cell_sql(cell) do
    "(jsonb_typeof(#{cell}) = 'number' OR " <>
      "(jsonb_typeof(#{cell}) = 'string' AND trim(#{cell} #>> '{}') ~ '^[0-9]+$'))"
  end

  # A money cell written by this version: a string holding a decimal number.
  defp dollar_cell_sql(cell) do
    "(jsonb_typeof(#{cell}) = 'string' AND trim(#{cell} #>> '{}') ~ '^[0-9]*[.][0-9]+$')"
  end

  defp cell_numeric_sql(cell), do: "trim(#{cell} #>> '{}')::numeric"

  # A numeric expression as a dollar string with at least two places and no
  # trailing zeros beyond them: 5 → '5.00', 0.25 → '0.25', 0.0000004 →
  # '0.0000004' (the shape of `PhoenixKitAI.Money.to_json/1`).
  defp dollars_sql(expr) do
    trimmed = "rtrim(rtrim((#{expr})::text, '0'), '.')"

    "(CASE WHEN (#{expr}) = 0 THEN '0.00' " <>
      "WHEN position('.' in #{trimmed}) = 0 THEN #{trimmed} || '.00' " <>
      "WHEN length(split_part(#{trimmed}, '.', 2)) = 1 THEN #{trimmed} || '0' " <>
      "ELSE #{trimmed} END)"
  end

  defp marker_statement(prefix, version) do
    "COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{@marker_prefix}#{version}'"
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = valid_prefix!(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  # Core's rules: the prefix is interpolated into the SQL.
  defp valid_prefix!(prefix) do
    :ok = Helpers.validate_prefix!(prefix)
    prefix
  end

  defp read_version(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2 AND c.relkind = 'r'
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> parse_version(comment)
      {:ok, %{rows: []}} -> 0
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  # Stamping a version the chain does not have would make every later version
  # look applied, so it is refused.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitAI.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version})"
  end

  defp validate_target!(_target), do: :ok
end
