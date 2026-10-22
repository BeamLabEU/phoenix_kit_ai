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

  @current_version 2
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

  defp version_down(1, prefix),
    do: [
      "DROP TABLE IF EXISTS #{Helpers.qualify_table("phoenix_kit_ai_model_capabilities", prefix)}"
    ]

  defp version_down(2, prefix), do: v2_down_statements(prefix)

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

  defp sql_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

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
