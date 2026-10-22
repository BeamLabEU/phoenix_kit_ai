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

  @current_version 1
  @default_prefix "public"
  @marker_prefix "ai_schema:"
  @version_table "phoenix_kit_ai_model_capabilities"

  # The order `down_statements/2` drops them in (children first).
  @tables ~w(phoenix_kit_ai_model_capabilities)

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
      v1_statements(prefix) ++ [marker_statement(prefix, target)]
    end
  end

  @doc """
  The SQL `down/1` runs, as data. To `0` it drops every table of this chain;
  to a version still in the chain it only re-stamps the marker.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = valid_prefix!(prefix)

    if target == 0 do
      Enum.map(@tables, &"DROP TABLE IF EXISTS #{Helpers.qualify_table(&1, prefix)}")
    else
      [marker_statement(prefix, target)]
    end
  end

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
