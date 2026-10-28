defmodule PhoenixKitAI do
  @moduledoc """
  Main context for PhoenixKit AI system.

  Provides AI endpoint management and usage tracking for AI API requests.

  ## Architecture

  Each **Endpoint** is a unified configuration that combines:
  - Provider credentials (api_key, base_url, provider_settings)
  - Model selection (single model per endpoint)
  - Generation parameters (temperature, max_tokens, etc.)

  Users create as many endpoints as needed, each representing one complete
  AI configuration ready for making API requests.

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if AI module is enabled
  - `enable_system/0` - Enable the AI module
  - `disable_system/0` - Disable the AI module
  - `get_config/0` - Get module configuration with statistics

  ### Endpoint CRUD
  - `list_endpoints/1` - List all endpoints with filters
  - `get_endpoint!/1` - Get endpoint by UUID (raises)
  - `get_endpoint/1` - Get endpoint by UUID
  - `create_endpoint/1` - Create new endpoint
  - `update_endpoint/2` - Update existing endpoint
  - `delete_endpoint/1` - Delete endpoint

  ### Completion API
  - `ask/3` - Simple single-turn completion
  - `complete/3` - Multi-turn chat completion
  - `embed/3` - Generate embeddings
  - `speak/3` - Synthesize speech from text
  - `generate_image/3`, `edit_image/4`, `process_image/4` - Images
  - `describe_image/3`, `extract_text/3`, `compare_images/4` - Vision

  ### Options

  Taken by every verb, except `capture_request_content:` (see its entry):

  - `user_uuid:` - a PhoenixKit user uuid recorded on the usage row and
    selecting the per-user spend cap. Host-supplied identity: the module has
    no session of its own. An unknown uuid is logged as a warning and the
    row is written without it, so that call is not attributed or capped.
  - `source:`, `attribution:`, `idempotency_key:` - tracking only; never
    part of a cache key.
  - `capture_request_content: false` - keeps this call's message, prompt and
    response content out of its usage row(s); source, user, tokens, cost and
    the other base metadata are written either way. It only narrows: the
    global `config :phoenix_kit_ai, capture_request_content` (below) is the
    operator's switch, and `true` on a call never turns capture on while it
    is `false`. Honoured by `complete/3` and the image verbs
    (`describe_image/3`, `extract_text/3`, `compare_images/4`,
    `generate_image/3`, `edit_image/4`, `process_image/4`); `speak/3` and
    `embed/3` ignore it and follow the global setting only.
  - `cache:` - `true`, `[ttl: seconds | :infinity, key: term]` or
    `:refresh`; see `PhoenixKitAI.RequestCache`. Entries are shared across
    users.
  - `schema:` / `json: true` on `ask/3`, `complete/3`, `describe_image/3` -
    a JSON answer; see `PhoenixKitAI.StructuredOutput`.
  - Every verb returns `{:error, {:budget_exceeded, scope}}` once a spend
    cap is reached (`PhoenixKitAI.Budget`), cached answers included, and
    every usage row emits `[:phoenix_kit_ai, :request]`.

  ### Usage Tracking
  - `list_requests/1` - List requests with pagination/filters
  - `create_request/1` - Log a new request
  - `get_usage_stats/1` - Get aggregated statistics
  - `get_dashboard_stats/0` - Get stats for dashboard display

  ## Usage Examples

      # Enable the module
      PhoenixKitAI.enable_system()

      # Create an endpoint
      {:ok, endpoint} = PhoenixKitAI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })

      # Use the endpoint
      {:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Hello!")

      # Extract the response text
      {:ok, text} = PhoenixKitAI.extract_content(response)

  ## Configuration

      # Persist message + response content in request metadata (default: true).
      # Disable for deployments with PII / data-retention obligations — token
      # counts, latency, model, and cost are still recorded.
      config :phoenix_kit_ai, capture_request_content: false

      # Capture process memory in request caller_context (default: false).
      config :phoenix_kit_ai, capture_request_memory: true

      # Allow endpoint base_url to point at private/loopback IPs (default: false).
      # Required for self-hosted Ollama / intranet inference.
      config :phoenix_kit_ai, allow_internal_endpoint_urls: true
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitAI.Gettext

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries, as: SettingsQueries
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Reorder
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitAI.{Budget, Endpoint, Prompt, Provider, RequestCache, StructuredOutput}
  alias PhoenixKitAI.CallCost
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Guard
  alias PhoenixKitAI.GuardBlocks
  alias PhoenixKitAI.GuardEvents
  alias PhoenixKitAI.Images.{ImageModel, ImageModels, Operations, Regions}
  alias PhoenixKitAI.ManualPrice
  alias PhoenixKitAI.Money
  alias PhoenixKitAI.ProviderError
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.TaskLimits
  alias PhoenixKitAI.Tasks
  alias PhoenixKitAI.TaskSpec
  alias PhoenixKitAI.TtsPricing

  # ===========================================
  # PUBSUB TOPICS
  # ===========================================

  @endpoints_topic "phoenix_kit:ai:endpoints"
  @prompts_topic "phoenix_kit:ai:prompts"
  @requests_topic "phoenix_kit:ai:requests"

  # Set once the legacy api_key auto-migrator has run; see
  # `run_legacy_api_key_migration/0`.
  @legacy_migration_marker "ai_legacy_api_key_migration_completed_at"

  # Single-sourced from mix.exs so a release bump touches one place only.
  @version Mix.Project.config()[:version]

  @doc """
  Returns the PubSub topic for AI endpoints.
  Subscribe to this topic to receive real-time updates.
  """
  @spec endpoints_topic() :: String.t()
  def endpoints_topic, do: @endpoints_topic

  @doc """
  Returns the PubSub topic for AI prompts.
  """
  @spec prompts_topic() :: String.t()
  def prompts_topic, do: @prompts_topic

  @doc """
  Returns the PubSub topic for AI requests/usage.
  """
  @spec requests_topic() :: String.t()
  def requests_topic, do: @requests_topic

  @doc """
  Subscribes the current process to AI endpoint changes.

  Messages are `{:endpoint_created | :endpoint_updated | :endpoint_deleted, uuid}` — the uuid only, never the record.
  """
  @spec subscribe_endpoints() :: :ok | {:error, term()}
  def subscribe_endpoints do
    PubSub.subscribe(@endpoints_topic)
  end

  @doc """
  Subscribes the current process to AI prompt changes.

  Messages are `{:prompt_created | :prompt_updated | :prompt_deleted, uuid}` — the uuid only, never the record.
  """
  @spec subscribe_prompts() :: :ok | {:error, term()}
  def subscribe_prompts do
    PubSub.subscribe(@prompts_topic)
  end

  @doc """
  Subscribes the current process to AI request/usage changes.

  Messages are `{:request_created, uuid}` — the uuid only, never the record.
  """
  @spec subscribe_requests() :: :ok | {:error, term()}
  def subscribe_requests do
    PubSub.subscribe(@requests_topic)
  end

  # ===========================================
  # HELPERS
  # ===========================================

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  # Textual-UUID check (36 chars, hyphenated). Core's `UUIDUtils.valid?/1`
  # delegates to `Ecto.UUID.cast/1`, which also accepts *16-byte* raw
  # binaries — that means any 16-character slug would be mistaken for a
  # UUID in UUID-vs-slug dispatch helpers. Guarding with byte_size keeps
  # the dispatch correct without touching core.
  defp textual_uuid?(string) when is_binary(string) do
    byte_size(string) == 36 and UUIDUtils.valid?(string)
  end

  # Change broadcasts carry the record's uuid and nothing else. A topic is
  # readable by anything on the node that subscribes to it, and the records
  # hold what must not travel that way: an endpoint its legacy `api_key`
  # column, a request the prompt and response text, a prompt its content.
  # A subscriber that needs the record reads it by uuid.
  defp broadcast_endpoint_change(result, event),
    do: broadcast_change(result, @endpoints_topic, event)

  defp broadcast_prompt_change(result, event), do: broadcast_change(result, @prompts_topic, event)

  defp broadcast_request_change(result, event),
    do: broadcast_change(result, @requests_topic, event)

  defp broadcast_change({:ok, %{uuid: uuid}} = result, topic, event) do
    PubSub.broadcast(topic, {event, uuid})
    result
  end

  defp broadcast_change(result, _topic, _event), do: result

  # ===========================================
  # ACTIVITY LOGGING HELPERS
  # ===========================================

  # Log a successful endpoint mutation. The failure-branch row is
  # written by `log_failed_endpoint_mutation/3` lower down. Together
  # they ensure the audit feed records every user-initiated mutation
  # attempt, including ones that failed due to validation, FK
  # violations, or DB outages. `metadata.db_pending: true`
  # distinguishes attempted-but-failed from completed actions.
  defp log_endpoint_activity({:ok, endpoint} = result, action, opts) do
    log_activity(action, "endpoint", endpoint.uuid, opts, %{"name" => endpoint.name})
    result
  end

  defp log_endpoint_activity(error, _action, _opts), do: error

  defp log_prompt_activity({:ok, prompt} = result, action, opts) do
    log_activity(action, "prompt", prompt.uuid, opts, %{"name" => prompt.name})
    result
  end

  defp log_prompt_activity(error, _action, _opts), do: error

  # Failure-branch audit row. Writes `metadata.db_pending: true` plus
  # the validation `error_keys` so the audit feed can distinguish
  # attempted-but-failed from completed mutations. Returns the result
  # unchanged so callers can continue piping. No-op on `{:ok, _}`.
  defp log_failed_endpoint_mutation(
         {:error, %Ecto.Changeset{} = changeset} = result,
         action,
         opts
       ) do
    log_activity(
      action,
      "endpoint",
      Map.get(changeset.data, :uuid),
      opts,
      failure_metadata(changeset, :name)
    )

    result
  end

  defp log_failed_endpoint_mutation(result, _action, _opts), do: result

  defp log_failed_prompt_mutation(
         {:error, %Ecto.Changeset{} = changeset} = result,
         action,
         opts
       ) do
    log_activity(
      action,
      "prompt",
      Map.get(changeset.data, :uuid),
      opts,
      failure_metadata(changeset, :name)
    )

    result
  end

  defp log_failed_prompt_mutation(result, _action, _opts), do: result

  # PII-safe failure metadata — `name` is the only changeset field we
  # surface (the resource's display string, already public in the admin
  # UI); `error_keys` is the list of failed validation keys, never the
  # rejected values themselves.
  defp failure_metadata(changeset, name_field) do
    %{
      "name" => Ecto.Changeset.get_field(changeset, name_field),
      "db_pending" => true,
      "error_keys" => changeset.errors |> Keyword.keys() |> Enum.map(&Atom.to_string/1)
    }
  end

  # Enable/disable toggle — logs only when the flag actually changes.
  defp maybe_log_endpoint_toggle({:ok, endpoint} = result, was_enabled, opts) do
    cond do
      was_enabled == endpoint.enabled -> result
      endpoint.enabled -> log_toggle(result, "endpoint.enabled", endpoint, "endpoint", opts)
      true -> log_toggle(result, "endpoint.disabled", endpoint, "endpoint", opts)
    end
  end

  defp maybe_log_endpoint_toggle(error, _, _), do: error

  defp maybe_log_prompt_toggle({:ok, prompt} = result, was_enabled, opts) do
    cond do
      was_enabled == prompt.enabled -> result
      prompt.enabled -> log_toggle(result, "prompt.enabled", prompt, "prompt", opts)
      true -> log_toggle(result, "prompt.disabled", prompt, "prompt", opts)
    end
  end

  defp maybe_log_prompt_toggle(error, _, _), do: error

  defp log_toggle(result, action, resource, resource_type, opts) do
    log_activity(action, resource_type, resource.uuid, opts, %{"name" => resource.name})
    result
  end

  # Unified logger. Core's log never raises, so activity failures never
  # crash the primary operation.
  defp log_activity(action, resource_type, resource_uuid, opts, extra) do
    PhoenixKit.Activity.log("ai", action,
      mode: Keyword.get(opts, :mode, "manual"),
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: Map.merge(%{"actor_role" => Keyword.get(opts, :actor_role, "user")}, extra)
    )
  end

  # ===========================================
  # SYSTEM MANAGEMENT
  # ===========================================

  @doc """
  Checks if the AI module is enabled.
  """
  @impl PhoenixKit.Module
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting("ai_enabled", false)
  rescue
    _ -> false
  catch
    # `Settings.get_boolean_setting/2` can hit a shutting-down pool
    # in tests and exit on `DBConnection.Holder.checkout/3`. The
    # convention is "must return false as fallback" — that includes
    # process exits, not just exceptions.
    :exit, _ -> false
  end

  @doc """
  Enables the AI module.
  """
  @impl PhoenixKit.Module
  @spec enable_system() :: {:ok, term()} | {:error, term()}
  def enable_system do
    Settings.update_boolean_setting_with_module("ai_enabled", true, module_key())
  end

  @doc """
  Disables the AI module.
  """
  @impl PhoenixKit.Module
  @spec disable_system() :: {:ok, term()} | {:error, term()}
  def disable_system do
    Settings.update_boolean_setting_with_module("ai_enabled", false, module_key())
  end

  @doc """
  One-shot auto-migrator for legacy `endpoint.api_key` values into
  `PhoenixKit.Integrations` connections.

  Mirrors the pattern of `PhoenixKit.Integrations.run_legacy_migrations/0`
  — call it at host-app boot to fold pre-Integrations endpoint api_keys
  into the named-connection model. Safe to call multiple times:
  multiple idempotency guards short-circuit on already-migrated state.

  ## What it does

  For each `phoenix_kit_ai_endpoints` row whose `provider` is the bare
  string `"openrouter"` (i.e., NOT already pointing at a named
  Integrations connection like `"openrouter:my-key"`) AND whose
  `api_key` is non-empty:

  1. Group by api_key value — endpoints sharing a key share one
     connection (dedup).
  2. Create a `PhoenixKit.Integrations` connection per distinct key.
     Naming: `"openrouter:default"` if there's exactly one key in the
     deployment; `"openrouter:imported-1"`, `"openrouter:imported-2"`
     (1-indexed by first-seen order) if there are multiple.
  3. Update each endpoint's `provider` field to point at the new
     connection key (e.g., `"openrouter:default"`).

  The legacy `api_key` column is cleared to `""` in the same `UPDATE`
  that sets `provider` and `integration_uuid`, so the Integrations row
  is the only credential source and the two cannot drift apart.
  `OpenRouterClient.resolve_api_key/2` still falls back to the column
  for endpoints this run did not reach.

  ## Idempotency guards (any one short-circuits)

  - The `ai_legacy_api_key_migration_completed_at` setting is set →
    already ran, skip.
  - ANY OpenRouter integration already exists in
    `phoenix_kit_settings` (operator already set up Integrations
    manually) → mark completed and skip.
  - NO endpoints have `provider == "openrouter"` with a non-empty
    `api_key` → nothing to migrate, mark completed.

  ## Failure modes

  Top-level `try/rescue/catch :exit` so DB outages, race conditions,
  or any unexpected exception NEVER crashes the host app's boot.
  Per-key-group operations are isolated — one bad group doesn't abort
  the others. Partial migration is safe because un-migrated endpoints
  still resolve via the legacy fallback path.

  ## Configuration

  No options. Disable by simply not calling the function.
  """
  @spec run_legacy_api_key_migration() :: :ok
  def run_legacy_api_key_migration do
    case do_run_legacy_api_key_migration() do
      :skipped ->
        :ok

      {:migrated, count} ->
        require Logger

        Logger.info(
          "[PhoenixKitAI] Auto-migrated #{count} endpoint(s) from legacy api_key " <>
            "to PhoenixKit.Integrations connections"
        )

        :ok
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "[PhoenixKitAI] Legacy api_key migration crashed (host boot continues): " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _reason ->
      :ok
  end

  defp do_run_legacy_api_key_migration do
    cond do
      not Code.ensure_loaded?(PhoenixKit.Integrations) ->
        :skipped

      legacy_api_key_migration_completed?() ->
        :skipped

      any_openrouter_integration_exists?() ->
        # The auto-migrator only ever creates `integration:openrouter:*`
        # rows (its target population is endpoints with `provider ==
        # "openrouter"` and a non-empty `api_key`). If any OpenRouter
        # connection already exists in `phoenix_kit_settings`, the
        # operator either set Integrations up manually OR a previous
        # run completed — either way the desired end state is reached.
        # Mark complete and skip future runs.
        #
        # **Scope clarification** (PR #6 review finding #8): this gate
        # is OpenRouter-only. A multi-provider deployment that has,
        # say, a Mistral integration set up but still has unmigrated
        # legacy OpenRouter `api_key` columns will NOT trip this guard
        # — the migration runs normally for the OpenRouter rows.
        # `any_openrouter_integration_exists?/0` mirrors the
        # migration's actual target population, not a global "any
        # integration anywhere" check.
        mark_legacy_api_key_migration_complete()
        :skipped

      true ->
        attempt_legacy_api_key_migration()
    end
  end

  # Read from the row itself, not through `Settings.get_setting/2`: with
  # core's `update_mode` on (`mix phoenix_kit.update` / `mix
  # phoenix_kit.doctor` start the host app that way, and its boot runs this)
  # `get_setting/2` answers nil without reading, while writes still go
  # through. The marker looked absent, a later guard marked the migration
  # complete again (an existing OpenRouter connection, or no candidates
  # left), and each such run stamped a new value — a new permanent
  # settings-history entry. Present once = done for good.
  defp legacy_api_key_migration_completed? do
    SettingsQueries.get_setting_by_key(@legacy_migration_marker) != nil
  rescue
    # Settings table missing in this environment — treat as not completed
    # but the next guard (any_openrouter_integration_exists?) will trip
    # on the same missing infra and we'll skip safely.
    _ -> false
  end

  defp any_openrouter_integration_exists? do
    # Two storage generations: pre-V114 composite keys
    # (integration:openrouter:<name>) and the current uuid-keyed rows
    # (module = "integrations", provider in the JSONB). Checking only the
    # legacy shape made operator-created integrations invisible on modern
    # cores — the migration then ran instead of skipping.
    legacy =
      from(s in "phoenix_kit_settings",
        where: like(s.key, "integration:openrouter:%"),
        select: count(s.uuid)
      )

    modern =
      from(s in "phoenix_kit_settings",
        where: s.module == "integrations",
        where: fragment("?->>'provider' = ?", s.value_json, "openrouter"),
        select: count(s.uuid)
      )

    repo().one(legacy) > 0 or repo().one(modern) > 0
  rescue
    # If the settings table or column shape isn't what we expect, fall
    # through to "yes, skip" — safer than risking a partial migration
    # against an unfamiliar schema.
    _ -> true
  end

  defp attempt_legacy_api_key_migration do
    candidates = list_legacy_api_key_endpoints()

    if Enum.empty?(candidates) do
      mark_legacy_api_key_migration_complete()
      :skipped
    else
      grouped_by_key = Enum.group_by(candidates, & &1.api_key)
      total_groups = map_size(grouped_by_key)

      # Snapshot the existing OpenRouter connections once so the
      # `:already_exists` fallback is a map lookup rather than a fresh
      # `list_connections/1` query per group. On a deployment with N
      # distinct legacy keys re-running migration, this collapses
      # `O(groups × connections)` reads down to one. Connections
      # created during the loop come back via `add_connection`'s
      # `{:ok, %{uuid: _}}` directly, so they don't need the cache.
      existing_uuids = snapshot_connection_uuids("openrouter")

      migrated_count =
        grouped_by_key
        |> Enum.with_index(1)
        |> Enum.reduce(0, fn {{api_key, endpoints}, index}, acc ->
          name = legacy_connection_name(total_groups, index)
          acc + migrate_endpoint_group(name, api_key, endpoints, existing_uuids)
        end)

      mark_legacy_api_key_migration_complete()
      {:migrated, migrated_count}
    end
  end

  defp snapshot_connection_uuids(provider) do
    PhoenixKit.Integrations.list_connections(provider)
    |> Map.new(fn conn -> {conn.name, conn.uuid} end)
  rescue
    _ -> %{}
  end

  defp list_legacy_api_key_endpoints do
    # Only touch endpoints whose provider is the bare "openrouter"
    # string. Endpoints already pointing at a named connection (e.g.
    # "openrouter:my-key") have been migrated by hand or by an earlier
    # run — leave them alone.
    query =
      from(e in Endpoint,
        where:
          e.provider == "openrouter" and
            not is_nil(e.api_key) and
            e.api_key != "",
        select: %{uuid: e.uuid, api_key: e.api_key, name: e.name}
      )

    repo().all(query)
  rescue
    _ -> []
  end

  defp legacy_connection_name(1, _index), do: "default"
  defp legacy_connection_name(_total, index), do: "imported-#{index}"

  defp migrate_endpoint_group(name, api_key, endpoints, existing_uuids) do
    # Two-step write under core's strict-UUID Integrations API:
    # add_connection/3 creates (or surfaces) the row and returns its
    # uuid; save_setup/3 then stores the legacy api_key against that
    # uuid. `:already_exists` on re-runs is fine — pull the existing
    # row's uuid out of the snapshot taken before the loop started.
    integration_uuid =
      case PhoenixKit.Integrations.add_connection("openrouter", name) do
        {:ok, %{uuid: uuid}} -> uuid
        {:error, :already_exists} -> Map.get(existing_uuids, name)
        _ -> nil
      end

    if is_nil(integration_uuid) do
      require Logger

      Logger.warning(
        "[PhoenixKitAI] Skipping legacy api_key group (#{length(endpoints)} endpoints) — " <>
          "could not resolve integration uuid"
      )

      0
    else
      persist_migrated_credentials(integration_uuid, api_key, endpoints, name)
    end
  rescue
    _ -> 0
  end

  # Re-points the endpoint group at the resolved integration uuid.
  # Returns the count of endpoints updated (0 if the credential save fails).
  defp persist_migrated_credentials(integration_uuid, api_key, endpoints, name) do
    case PhoenixKit.Integrations.save_setup(integration_uuid, %{"api_key" => api_key}) do
      {:ok, _saved} ->
        count = update_endpoints_provider(endpoints, "openrouter:#{name}", integration_uuid)
        maybe_log_credentials_migrated(count, integration_uuid, name)
        count

      {:error, _reason} ->
        require Logger

        Logger.warning(
          "[PhoenixKitAI] Skipping legacy api_key group (#{length(endpoints)} endpoints) — " <>
            "save_setup failed"
        )

        0
    end
  end

  defp maybe_log_credentials_migrated(count, _integration_uuid, _name) when count <= 0, do: :ok

  defp maybe_log_credentials_migrated(count, integration_uuid, name) do
    log_migration_activity(:credentials_migrated, %{
      "endpoint_count" => count,
      "integration_uuid" => integration_uuid,
      "connection_name" => name
    })
  end

  defp update_endpoints_provider(endpoints, new_provider, integration_uuid) do
    uuids = Enum.map(endpoints, & &1.uuid)

    # Atomic write: set the new provider/integration_uuid AND clear
    # the legacy api_key column in the same UPDATE statement. The
    # integration row created above (`save_setup`) holds the same
    # api_key the endpoint had — it's the canonical credential
    # source now. Keeping a duplicate on the endpoint row would only
    # rot quietly (admin rotates the integration's key, endpoint's
    # column drifts) and mask config drift if the integration ever
    # breaks. Cleared to "" rather than NULL because the column is
    # NOT NULL (V34); both the runtime fallback chain
    # (`maybe_get_credentials("") => {:error, :not_configured}`) and
    # the recovery-card render condition treat "" as "no fallback".
    set_clause =
      [provider: new_provider, api_key: "", updated_at: DateTime.utc_now()]
      |> maybe_add_integration_uuid(integration_uuid)

    {count, _} =
      from(e in Endpoint, where: e.uuid in ^uuids)
      |> repo().update_all(set: set_clause)

    # `update_all` passes `update_endpoint/3` by, and with it the lookup cache.
    Enum.each(uuids, &PhoenixKitAI.Cache.invalidate_endpoint/1)
    count
  rescue
    _ -> 0
  end

  # Caller (`update_endpoints_provider/3`) is only reachable via the
  # `is_nil(integration_uuid) -> 0` short-circuit one frame up, so the
  # `nil` clause here is unreachable per dialyzer's typeflow. Empty
  # string is still possible (call sites that pass through raw form
  # input) — keep that branch.
  defp maybe_add_integration_uuid(set_clause, ""), do: set_clause

  defp maybe_add_integration_uuid(set_clause, uuid) when is_binary(uuid) do
    Keyword.put(set_clause, :integration_uuid, uuid)
  end

  defp mark_legacy_api_key_migration_complete do
    Settings.update_setting_with_module(
      @legacy_migration_marker,
      DateTime.utc_now() |> DateTime.to_iso8601(),
      module_key()
    )

    :ok
  rescue
    _ -> :ok
  end

  # ===========================================
  # Combined migrate_legacy/0 callback
  # ===========================================

  @doc """
  Combined boot-time migration entry point.

  Runs the legacy data transitions for AI:

  1. **Local api_key → Integrations row + integration_uuid**
     (delegates to `run_legacy_api_key_migration/0`). Endpoints with
     bare `provider == "openrouter"` and a non-empty `api_key` get
     grouped, get an Integration row created, and have both `provider`
     AND `integration_uuid` updated to point at it.

  2. **`provider`-string → `integration_uuid`** (sweep). Endpoints with
     `integration_uuid IS NULL` whose `provider` field resolves to a
     real integration uuid (either bare provider, `provider:name` shape,
     or a uuid stuffed in the string column from pre-V107 form saves)
     get their `integration_uuid` populated. V107's migration backfilled
     most of these at install time; this pass catches stragglers
     (e.g., endpoints created post-form-update but pre-V107).

  3. **Sub-permission backfill.** `ai.view_usage` and
     `ai.manage_endpoints` are granted once each to every role that holds
     the base `ai` key, guarded by `ai_view_usage_backfilled` /
     `ai_manage_endpoints_backfilled`; a flag is set only after every grant
     for its key succeeded, so a failed pass retries on the next boot.

  The first two kinds log to `PhoenixKit.Activity` per migrated record / group
  with `mode: "auto"` and module `"ai"`. PII-safe: never logs
  `api_key` values.

  Idempotent — run on every host-app boot. Designed to be invoked via
  the orchestrator (`PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`),
  but can be called directly for ad-hoc migration runs.
  """
  @impl PhoenixKit.Module
  @spec migrate_legacy() :: {:ok, map()} | {:error, term()}
  def migrate_legacy do
    credentials_result = run_legacy_api_key_migration()
    references_result = sweep_provider_string_to_integration_uuid()
    permissions_result = backfill_sub_permissions()

    summary = %{
      credentials_migration: credentials_result,
      reference_migration: references_result,
      permissions_backfill: permissions_result
    }

    # Surface inner sweep failures at the outer return shape so the
    # orchestrator (`PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`)
    # can pattern-match on `{:ok, _}` to decide "ran cleanly". Wrapping
    # `:error` inside `{:ok, %{reference_migration: :error}}` would
    # silently swallow the failure for any caller that doesn't drill
    # into the map.
    cond do
      references_result == :error -> {:error, {:sweep_failed, summary}}
      permissions_result != :ok -> {:error, {:permission_backfill_incomplete, summary}}
      true -> {:ok, summary}
    end
  rescue
    e ->
      require Logger

      Logger.warning("[PhoenixKitAI] migrate_legacy/0 raised: #{Exception.message(e)}")

      {:error, e}
  end

  # One flag per sub-permission, so a later split gets its own pass.
  @sub_permission_backfills [
    {"ai.view_usage", "ai_view_usage_backfilled"},
    {"ai.manage_endpoints", "ai_manage_endpoints_backfilled"}
  ]

  # Each split-out sub-permission is granted ONCE to every role that held the
  # base `ai` key at the time, so nobody loses what the base key used to
  # allow. A role granted `ai` afterwards gets the narrow meaning, and an
  # Owner's later revoke sticks, because the flag stops the pass for good.
  defp backfill_sub_permissions do
    results =
      for {key, flag} <- @sub_permission_backfills,
          Settings.get_setting(flag) != "true",
          do: backfill_sub_permission(key, flag)

    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc false
  # `:grant` and `:role_grants` are options only so a test can make a grant
  # or the lookup fail and prove the flag then stays unset; production always
  # uses core's grant and `role_grants/0`.
  @spec backfill_sub_permission(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def backfill_sub_permission(key, flag, opts \\ []) do
    grant = Keyword.get(opts, :grant, &Permissions.grant_permission/3)
    role_grants = Keyword.get(opts, :role_grants, &role_grants/0)

    failures =
      for {role_uuid, granted} <- role_grants.(),
          module_key() in granted,
          key not in granted,
          result = grant.(role_uuid, key, nil),
          not match?({:ok, _}, result) do
        {role_uuid, result}
      end

    with [] <- failures,
         {:ok, _} <- Settings.update_setting_with_module(flag, "true", module_key()) do
      :ok
    else
      failed ->
        Logger.warning(
          "[PhoenixKitAI] #{key} backfill incomplete, will retry next boot: #{inspect(failed)}"
        )

        {:error, {key, failed}}
    end
  rescue
    e ->
      Logger.warning("[PhoenixKitAI] #{key} backfill failed: #{Exception.message(e)}")
      {:error, {key, e}}
  end

  # Every role's granted keys, read with a query that RAISES on failure.
  # Core's `Permissions.get_permissions_for_role/1` rescues a query error to
  # `[]`, which would read as "this role has no `ai`" and let the flag be set
  # for good with the role never granted the sub-key.
  defp role_grants do
    from(rp in PhoenixKit.Users.RolePermission, select: {rp.role_uuid, rp.module_key})
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp sweep_provider_string_to_integration_uuid do
    endpoints = list_endpoints_needing_uuid_promotion()

    if Enum.empty?(endpoints) do
      :nothing_to_migrate
    else
      migrated = count_promoted_endpoints(endpoints)
      maybe_log_reference_migrated(migrated)
      {:migrated, migrated}
    end
  rescue
    e ->
      require Logger

      Logger.warning(fn ->
        "[PhoenixKitAI] reference sweep crashed: " <>
          "exception=#{inspect(e.__struct__)}, " <>
          "message=#{Exception.message(e)}"
      end)

      :error
  end

  # Promotes each endpoint's provider string to an integration uuid,
  # returning the count that succeeded.
  defp count_promoted_endpoints(endpoints) do
    Enum.reduce(endpoints, 0, fn endpoint, acc ->
      case promote_provider_to_integration_uuid(endpoint) do
        :ok -> acc + 1
        _ -> acc
      end
    end)
  end

  defp maybe_log_reference_migrated(migrated) when migrated <= 0, do: :ok

  defp maybe_log_reference_migrated(migrated) do
    log_migration_activity(:reference_migrated, %{
      "endpoint_count" => migrated,
      "source" => "boot_sweep"
    })
  end

  defp list_endpoints_needing_uuid_promotion do
    # Endpoints with NULL integration_uuid but a provider field that
    # might resolve. Skip rows whose provider is the bare default
    # ("openrouter") because credentials migration handles those when
    # they have an api_key — and a bare provider with no api_key
    # has nothing to promote to.
    query =
      from(e in Endpoint,
        where:
          is_nil(e.integration_uuid) and
            not is_nil(e.provider) and
            e.provider != "" and
            e.provider != "openrouter",
        select: %{uuid: e.uuid, provider: e.provider}
      )

    repo().all(query)
  rescue
    _ -> []
  end

  defp promote_provider_to_integration_uuid(%{uuid: endpoint_uuid, provider: provider}) do
    integration_uuid = resolve_provider_to_uuid(provider)

    if is_nil(integration_uuid) do
      :no_match
    else
      {count, _} =
        from(e in Endpoint, where: e.uuid == ^endpoint_uuid and is_nil(e.integration_uuid))
        |> repo().update_all(
          set: [integration_uuid: integration_uuid, updated_at: DateTime.utc_now()]
        )

      PhoenixKitAI.Cache.invalidate_endpoint(endpoint_uuid)
      if count > 0, do: :ok, else: :no_op
    end
  rescue
    _ -> :error
  end

  defp resolve_provider_to_uuid(provider) when is_binary(provider) do
    # Delegates to core's dual-input primitive. Previously this helper
    # carried its own regex + dispatch + provider:name split — a
    # near-clone of `OpenRouterClient.lookup_uuid_for_provider/1`.
    # Centralising into `Integrations.resolve_to_uuid/1` removes the
    # duplication and eliminates the "fourth provider tempts a third
    # copy-paste" risk.
    case PhoenixKit.Integrations.resolve_to_uuid(provider) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_provider_to_uuid(_), do: nil

  # Never raises (core's `log/3`); the migration goes on whether or not
  # its entry landed.
  defp log_migration_activity(action_atom, metadata) do
    PhoenixKit.Activity.log(module_key(), "integration.legacy_migrated",
      mode: "auto",
      resource_type: "endpoint",
      metadata:
        Map.merge(metadata, %{
          "migration_kind" => Atom.to_string(action_atom),
          "actor_role" => "system"
        })
    )

    :ok
  end

  @doc """
  Gets the AI module configuration with statistics.

  Stat queries are wrapped in a try/rescue so that environments without a
  live Repo connection (early boot, test cases without sandbox checkout)
  still get a well-formed map — matching the defensive pattern in
  `enabled?/0`.
  """
  @impl PhoenixKit.Module
  @spec get_config() :: %{
          enabled: boolean(),
          endpoints_count: non_neg_integer(),
          total_requests: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
  def get_config do
    %{
      enabled: enabled?(),
      endpoints_count: safe_count(&count_endpoints/0),
      total_requests: safe_count(&count_requests/0),
      total_tokens: safe_count(&sum_tokens/0)
    }
  end

  defp safe_count(fun) do
    fun.()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ===========================================
  # MODULE BEHAVIOUR CALLBACKS
  # ===========================================

  @impl PhoenixKit.Module
  @spec module_key() :: String.t()
  def module_key, do: "ai"

  @impl PhoenixKit.Module
  @spec module_name() :: String.t()
  def module_name, do: "AI"

  @impl PhoenixKit.Module
  @spec permission_metadata() :: map()
  def permission_metadata do
    %{
      key: module_key(),
      label: "AI",
      icon: "hero-sparkles",
      description: "AI endpoints, prompts, and usage tracking",
      # `ai.manage`: changes to the AI task guard (limits, watchers, "only
      # verified models", forgiving a limit, blocks) and the reasons of a
      # private task's flags and blocks. Core grants a new
      # sub-permission to Admin once while Admin holds `ai`; an Owner holds
      # every key.
      #
      # `ai.view_usage`: the Usage tab, which shows every AI request on the
      # site with its prompt and response. `ai.manage_endpoints`: creating,
      # editing, enabling, reordering and deleting endpoints (the list stays
      # on the base key). Both were part of the base key before; the
      # once-only backfill in `migrate_legacy/0` keeps them for every role
      # that held `ai` then.
      sub_permissions: [
        %{
          key: "manage",
          label: "Manage the AI task guard",
          description:
            "Change the limits of AI tasks, who is told about them and which models may be used; block a person from a task; see why a private task's request was flagged"
        },
        %{
          key: "view_usage",
          label: "See AI usage",
          description:
            "Open the Usage tab: every AI request on the site with its prompt and response"
        },
        %{
          key: "manage_endpoints",
          label: "Manage AI endpoints",
          description: "Create, edit, enable, disable, reorder and delete AI endpoints"
        }
      ],
      # Renders the label translated in the admin permissions matrix, the
      # same way the sidebar tabs below translate theirs.
      gettext_backend: PhoenixKitAI.Gettext,
      gettext_domain: "default"
    }
  end

  @doc """
  The notification type of the module: `"ai_guard"`, what the watchers of
  the AI task guard get when a task's limit is near or reached, a spending
  cap refuses a call, a task's model stops fitting it, a person's request is
  flagged as off-purpose (once a day), a task's anomaly rule is broken, or a
  person is blocked or unblocked (`PhoenixKitAI.GuardEvents`). A watcher can
  switch it off for themselves.
  """
  @impl PhoenixKit.Module
  @spec notification_types() :: [map()]
  def notification_types do
    [
      %{
        key: GuardEvents.notice_type(),
        label: gettext("AI task guard"),
        description:
          gettext(
            "An AI task is near or at a limit, a spending cap refused a call, a task's model no longer fits it, a request was flagged as off-purpose, a task is used unusually, or a person was blocked or unblocked"
          ),
        actions: [],
        default: true
      }
    ]
  end

  @doc """
  The module's scheduled job: the nightly cleanup of the AI journal by the
  periods set for it (`PhoenixKitAI.JournalPruneWorker`, core `default`
  queue; kept forever by default, see `PhoenixKitAI.Retention`).
  """
  @impl PhoenixKit.Module
  @spec oban_crons() :: [{String.t(), module()}]
  def oban_crons, do: [{"17 3 * * *", PhoenixKitAI.JournalPruneWorker}]

  @impl PhoenixKit.Module
  @spec admin_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def admin_tabs do
    [
      %Tab{
        id: :admin_ai,
        label: "AI",
        icon: "hero-cpu-chip",
        path: "ai",
        priority: 640,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_ai_endpoints,
        label: "Endpoints",
        icon: "hero-server-stack",
        path: "ai/endpoints",
        priority: 641,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_ai_prompts,
        label: "Prompts",
        icon: "hero-document-text",
        path: "ai/prompts",
        priority: 642,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_ai_playground,
        label: "Playground",
        icon: "hero-beaker",
        path: "ai/playground",
        priority: 643,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_ai_usage,
        label: "Usage",
        icon: "hero-chart-bar",
        path: "ai/usage",
        priority: 644,
        level: :admin,
        # Hides the tab; `Web.Endpoints` refuses the page itself (the tabs
        # declare `path:`, not `live_view:`, so core's route gate admits any
        # `ai` holder).
        permission: "ai.view_usage",
        parent: :admin_ai,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      },
      %Tab{
        id: :admin_ai_tasks,
        label: "Tasks",
        icon: "hero-clipboard-document-check",
        path: "ai/tasks",
        priority: 645,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai,
        gettext_backend: PhoenixKitAI.Gettext,
        gettext_domain: "default"
      }
    ]
  end

  @doc """
  Pins every label this module declares as a gettext msgid.

  `permission_metadata/0` and `admin_tabs/0` declare their labels as plain
  string literals, so `mix gettext.extract` never sees this file — it scans
  for gettext macro calls, not struct fields. PhoenixKit translates them at
  render time through each declaration's `gettext_backend`/`gettext_domain`,
  but only if the msgid exists in this module's own catalogue.

  Without this function, `"AI"`, `"Endpoints"`, `"Prompts"`, and
  `"Playground"` would depend on `mix gettext.extract` never running, since
  `mix gettext.merge` deletes any `.po` entry absent from a freshly built
  `.pot` (`on_obsolete: :delete` by default) — and `"Usage"` would stay in
  the `.pot` only by coincidence, because `gettext("Usage")` happens to
  appear verbatim in `web/prompts.ex`. Reword that string and this tab would
  silently revert to English with no compile error and no failing test.

  `dgettext_noop/2` registers the msgid and returns it unchanged — nothing
  here runs at request time.
  """
  @spec translatable_labels() :: [String.t()]
  def translatable_labels do
    [
      dgettext_noop("default", "AI"),
      dgettext_noop("default", "Endpoints"),
      dgettext_noop("default", "Prompts"),
      dgettext_noop("default", "Playground"),
      dgettext_noop("default", "Usage"),
      dgettext_noop("default", "Tasks"),
      dgettext_noop("default", "Manage the AI task guard"),
      dgettext_noop(
        "default",
        "Change the limits of AI tasks, who is told about them and which models may be used; block a person from a task; see why a private task's request was flagged"
      ),
      dgettext_noop("default", "See AI usage"),
      dgettext_noop(
        "default",
        "Open the Usage tab: every AI request on the site with its prompt and response"
      ),
      dgettext_noop("default", "Manage AI endpoints"),
      dgettext_noop(
        "default",
        "Create, edit, enable, disable, reorder and delete AI endpoints"
      )
    ]
  end

  @doc """
  The AI tasks this module runs itself, found by `PhoenixKitAI.Tasks` like
  any module's `ai_tasks/0`: the translation pipeline and the Playground.
  Neither needs more than text in and text out. The Playground takes free
  text, so it shares the `free_text` block group with other free-text
  tasks.
  """
  @spec ai_tasks() :: [TaskSpec.t()]
  def ai_tasks do
    [
      %TaskSpec{
        key: "ai.translation",
        label: dgettext_noop("default", "Translation"),
        gettext_backend: PhoenixKitAI.Gettext,
        purpose:
          dgettext_noop(
            "default",
            "Translate the text fields of a record from one language into another, keeping the field structure."
          ),
        needs: [],
        endpoints: {PhoenixKitAI.Translations, :unattended_endpoint_uuid, []}
      },
      %TaskSpec{
        key: "ai.playground",
        label: dgettext_noop("default", "Playground"),
        gettext_backend: PhoenixKitAI.Gettext,
        purpose:
          dgettext_noop("default", "Let an administrator try endpoints and prompts by hand."),
        needs: [],
        block_group: "free_text"
      }
    ]
  end

  @impl PhoenixKit.Module
  @dialyzer {:nowarn_function, css_sources: 0}
  @spec css_sources() :: [atom()]
  def css_sources, do: [:phoenix_kit_ai]

  @impl PhoenixKit.Module
  @spec js_sources() :: [map()]
  def js_sources do
    [
      %{
        app: :phoenix_kit_ai,
        file: "static/assets/phoenix_kit_ai.js",
        global: "PhoenixKitAIHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children do
    [
      {DynamicSupervisor, name: PhoenixKitAI.Realtime.Supervisor, strategy: :one_for_one},
      PhoenixKitAI.RequestCache,
      # The task registry's one writer, before anything that reads tasks.
      PhoenixKitAI.Tasks.Builder,
      PhoenixKitAI.Capabilities,
      PhoenixKitAI.GuardWatch,
      PhoenixKitAI.Cache,
      PhoenixKitAI.Limiter,
      PhoenixKitAI.RequestLog
    ]
  end

  @doc """
  The module's own migration chain (`PhoenixKitAI.Migrations`), run by
  `mix phoenix_kit.update` after core's. It owns every table of the module;
  V5 adopted the endpoint, prompt and request tables core's chain used to
  create first.
  """
  @impl PhoenixKit.Module
  @spec migration_module() :: module()
  def migration_module, do: PhoenixKitAI.Migrations

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKitAI.ExpectedSchema`.
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKitAI.ExpectedSchema

  @impl PhoenixKit.Module
  @spec required_integrations() :: [String.t()]
  def required_integrations, do: ["openrouter"]

  @impl PhoenixKit.Module
  @spec version() :: String.t()
  def version, do: @version

  @impl PhoenixKit.Module
  @spec route_module() :: module()
  def route_module, do: PhoenixKitAI.Routes

  # ===========================================
  # ENDPOINT CRUD
  # ===========================================

  @doc """
  Lists all AI endpoints.

  ## Options
  - `:provider` - Filter by provider type
  - `:enabled` - Filter by enabled status
  - `:preload` - Associations to preload

  ## Examples

      PhoenixKitAI.list_endpoints()
      PhoenixKitAI.list_endpoints(provider: "openrouter", enabled: true)
  """
  @spec list_endpoints(keyword()) :: {[Endpoint.t()], non_neg_integer()}
  def list_endpoints(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :sort_order)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)
    # Always paginate, default to page 1 and ensure it's > 0
    page = Keyword.get(opts, :page, 1) |> max(1)
    page_size = Keyword.get(opts, :page_size, 20)

    # Build base query with filters (no sorting yet)
    base_query = from(e in Endpoint)

    base_query =
      case Keyword.get(opts, :provider) do
        nil -> base_query
        provider -> where(base_query, [e], e.provider == ^provider)
      end

    base_query =
      case Keyword.get(opts, :enabled) do
        nil -> base_query
        enabled -> where(base_query, [e], e.enabled == ^enabled)
      end

    # Count on base query BEFORE applying sorting (which may add group_by)
    total = repo().aggregate(base_query, :count)

    # Now apply sorting (may add group_by for usage/tokens/cost/last_used)
    query = apply_endpoint_sorting(base_query, sort_by, sort_dir)

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    offset = (page - 1) * page_size

    endpoints =
      query
      |> limit(^page_size)
      |> offset(^offset)
      |> repo().all()

    # Always return the same shape
    {endpoints, total}
  end

  # Stable secondary key applied to every sort branch so tied values get
  # deterministic ordering (without it, `ORDER BY enabled` with all-true rows
  # returns whatever physical order PostgreSQL feels like — page/refresh can
  # subtly shift positions). `:uuid` is UUIDv7 → time-sortable + always unique.

  defp apply_endpoint_sorting(query, :usage, dir) do
    # Sort by total request count using a subquery to avoid GROUP BY issues
    stats_subquery =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid),
        group_by: r.endpoint_uuid,
        select: %{endpoint_uuid: r.endpoint_uuid, count: count()}
      )

    from(e in query,
      left_join: s in subquery(stats_subquery),
      on: s.endpoint_uuid == e.uuid,
      order_by: [{^dir, coalesce(s.count, 0)}, asc: e.uuid]
    )
  end

  defp apply_endpoint_sorting(query, :tokens, dir) do
    # Sort by total tokens used
    stats_subquery =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid),
        group_by: r.endpoint_uuid,
        select: %{endpoint_uuid: r.endpoint_uuid, total: coalesce(sum(r.total_tokens), 0)}
      )

    from(e in query,
      left_join: s in subquery(stats_subquery),
      on: s.endpoint_uuid == e.uuid,
      order_by: [{^dir, coalesce(s.total, 0)}, asc: e.uuid]
    )
  end

  defp apply_endpoint_sorting(query, :cost, dir) do
    # Sort by total cost
    stats_subquery =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid),
        group_by: r.endpoint_uuid,
        select: %{
          endpoint_uuid: r.endpoint_uuid,
          total: coalesce(sum(r.cost), 0)
        }
      )

    from(e in query,
      left_join: s in subquery(stats_subquery),
      on: s.endpoint_uuid == e.uuid,
      order_by: [{^dir, coalesce(s.total, 0)}, asc: e.uuid]
    )
  end

  defp apply_endpoint_sorting(query, :last_used, dir) do
    # Sort by most recent request time
    stats_subquery =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid),
        group_by: r.endpoint_uuid,
        select: %{endpoint_uuid: r.endpoint_uuid, last_used: max(r.inserted_at)}
      )

    from(e in query,
      left_join: s in subquery(stats_subquery),
      on: s.endpoint_uuid == e.uuid,
      order_by: [{^dir, s.last_used}, asc: e.uuid]
    )
  end

  defp apply_endpoint_sorting(query, field, dir)
       when field in [:name, :enabled, :model, :sort_order, :inserted_at] do
    order_by(query, [e], [{^dir, field(e, ^field)}, asc: e.uuid])
  end

  defp apply_endpoint_sorting(query, _field, _dir) do
    # Default sorting
    order_by(query, [e], asc: e.sort_order, desc: e.inserted_at, asc: e.uuid)
  end

  @doc """
  Returns usage statistics for each endpoint.

  Returns a map of endpoint_uuid => %{request_count, total_tokens, total_cost,
  last_used_at}; `total_cost` is US dollars, a `Decimal`.
  """
  @spec get_endpoint_usage_stats() :: %{optional(String.t()) => map()}
  def get_endpoint_usage_stats do
    query =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid),
        group_by: r.endpoint_uuid,
        select: {
          r.endpoint_uuid,
          %{
            request_count: count(),
            total_tokens: coalesce(sum(r.total_tokens), 0),
            total_cost: coalesce(sum(r.cost), 0),
            last_used_at: max(r.inserted_at)
          }
        }
      )

    query
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Gets a single endpoint by UUID.

  Raises `Ecto.NoResultsError` if the endpoint does not exist.
  """
  @spec get_endpoint!(String.t()) :: Endpoint.t()
  def get_endpoint!(id) do
    case get_endpoint(id) do
      nil -> raise Ecto.NoResultsError, queryable: Endpoint
      endpoint -> endpoint
    end
  end

  @doc """
  Gets a single endpoint by UUID.

  Accepts a UUID string (e.g., "550e8400-e29b-41d4-a716-446655440000").

  Returns `nil` if the endpoint does not exist.
  """
  @spec get_endpoint(term()) :: Endpoint.t() | nil
  def get_endpoint(id) when is_binary(id) do
    if textual_uuid?(id) do
      repo().get_by(Endpoint, uuid: id)
    else
      nil
    end
  end

  def get_endpoint(_), do: nil

  @doc """
  Gets an endpoint by its name — case-insensitive, and with surrounding
  spaces ignored on both sides (a name saved as `" Label reader"` is still
  found), so an app can refer to "Label reader" instead of carrying a uuid
  through config. The unique index is on `lower(name)` alone, so two names
  differing only in surrounding spaces can both exist; the exact one wins.

  Disabled endpoints are returned too; calling one is refused at call time
  (`{:error, :endpoint_disabled}`). Returns `nil` when there is none.
  """
  @spec get_endpoint_by_name(term()) :: Endpoint.t() | nil
  def get_endpoint_by_name(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        nil

      trimmed ->
        normalized = String.downcase(trimmed)

        from(e in Endpoint,
          where: fragment("lower(btrim(?))", e.name) == ^normalized,
          order_by: [
            desc: fragment("lower(?) = ?", e.name, ^normalized),
            asc: e.inserted_at,
            asc: e.uuid
          ],
          limit: 1
        )
        |> repo().one()
    end
  end

  def get_endpoint_by_name(_), do: nil

  @doc """
  `get_endpoint_by_name/1` as `{:ok, endpoint}` or `{:error, :endpoint_not_found}`,
  for `with` chains.
  """
  @spec resolve_endpoint_by_name(term()) :: {:ok, Endpoint.t()} | {:error, :endpoint_not_found}
  def resolve_endpoint_by_name(name) do
    case get_endpoint_by_name(name) do
      nil -> {:error, :endpoint_not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  @doc """
  Resolves an endpoint from an ID (UUID string) or Endpoint struct.

  ## Examples

      {:ok, endpoint} = PhoenixKitAI.resolve_endpoint("019abc12-3456-7def-8901-234567890abc")
      {:ok, endpoint} = PhoenixKitAI.resolve_endpoint(endpoint)
  """
  @spec resolve_endpoint(term()) ::
          {:ok, Endpoint.t()}
          | {:error, :endpoint_not_found | :invalid_endpoint_identifier}
  def resolve_endpoint(id) when is_binary(id) do
    # Cached briefly (PhoenixKitAI.Cache): every verb resolves its endpoint, and
    # update_endpoint/delete_endpoint + the endpoints broadcast drop the entry.
    # Keyed on the lowercase uuid, the form those invalidations name.
    PhoenixKitAI.Cache.endpoint(String.downcase(id), fn ->
      case get_endpoint(id) do
        nil -> {:error, :endpoint_not_found}
        endpoint -> {:ok, endpoint}
      end
    end)
  end

  def resolve_endpoint(%Endpoint{} = endpoint), do: {:ok, endpoint}

  def resolve_endpoint(_), do: {:error, :invalid_endpoint_identifier}

  @doc """
  Whether calls on `endpoint` get a cost in the usage journal: its provider
  reports one (OpenRouter), or the operator's catalogue, the endpoint's
  manual price (`provider_settings["pricing"]`) or the built-in Anthropic
  rates price its model. Where it is false, money limits and the daily
  budget cannot count the endpoint's calls. The order the sources are tried
  in is `PhoenixKitAI.CallCost`'s. It speaks for chat, embeddings and the
  vision verbs; making or editing images counts only the provider's own
  cost.
  """
  @spec reports_cost?(Endpoint.t()) :: boolean()
  def reports_cost?(%Endpoint{} = endpoint), do: CallCost.reports_cost?(endpoint)

  @doc """
  Creates a new AI endpoint.

  A manual price in `provider_settings["pricing"]` (`PhoenixKitAI.ManualPrice`:
  `%{"input" => µ$, "output" => µ$}` per 1M tokens, both halves, stamped with
  the endpoint's model) steers the money limits, so setting one needs the
  `:scope` option of a holder of `ai.manage` (an Owner always); without it
  the call is `{:error, changeset}` with an error on `:provider_settings`.
  A capability declaration needs the same while only verified models are
  allowed.

  ## Examples

      {:ok, endpoint} = PhoenixKitAI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })
  """
  @spec create_endpoint(map(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def create_endpoint(attrs, opts \\ []) do
    # `log: false`: the query log would print the api key.
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> guard_declaration(%Endpoint{}, opts)
    |> guard_pricing(%Endpoint{}, opts)
    |> repo().insert(log: false)
    |> broadcast_endpoint_change(:endpoint_created)
    |> log_endpoint_activity("endpoint.created", opts)
    |> log_capabilities_declaration(%Endpoint{}, opts)
    |> log_pricing_change(%Endpoint{}, opts)
    |> refresh_capabilities(true)
    |> log_failed_endpoint_mutation("endpoint.created", opts)
  end

  @doc """
  Updates an existing AI endpoint.

  Accepts an `:actor_uuid` option so the mutation can be attributed in
  the activity feed. If the change toggles the `enabled` flag an
  additional `endpoint.enabled` / `endpoint.disabled` entry is logged.

  Setting, changing or removing the manual price
  (`provider_settings["pricing"]`, `PhoenixKitAI.ManualPrice`) needs the
  `:scope` option of a holder of `ai.manage` (an Owner always); without it
  the call is `{:error, changeset}` with an error on `:provider_settings`.
  That includes replacing `provider_settings` wholesale without
  `"pricing"` on an endpoint that has a price — merge the stored settings
  instead. A model change drops the old model's price and needs nothing;
  an update that leaves the price as it is needs nothing either.
  """
  @spec update_endpoint(Endpoint.t(), map(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def update_endpoint(%Endpoint{} = endpoint, attrs, opts \\ []) do
    was_enabled = endpoint.enabled

    changeset =
      endpoint
      |> Endpoint.changeset(attrs)
      |> guard_declaration(endpoint, opts)
      |> guard_pricing(endpoint, opts)

    # Skip the activity row when the update is a no-op (no field actually
    # changed). The toggle log keeps its own guard so an enable/disable
    # via a bare `%{enabled: x}` still attributes correctly.
    has_changes = changeset.changes != %{}

    # `log: false`: the query log would print the api key.
    changeset
    |> repo().update(log: false)
    |> tap(fn _ -> PhoenixKitAI.Cache.invalidate_endpoint(endpoint.uuid) end)
    |> broadcast_endpoint_change(:endpoint_updated)
    |> maybe_log_endpoint_update(has_changes, opts)
    |> maybe_log_endpoint_toggle(was_enabled, opts)
    |> log_capabilities_declaration(endpoint, opts)
    |> log_pricing_change(endpoint, opts)
    |> refresh_capabilities(catalogue_inputs_changed?(changeset))
    |> log_failed_endpoint_mutation("endpoint.updated", opts)
  end

  defp maybe_log_endpoint_update({:ok, _} = result, true, opts) do
    log_endpoint_activity(result, "endpoint.updated", opts)
  end

  defp maybe_log_endpoint_update(result, _has_changes, _opts), do: result

  # A saved endpoint whose model or provider is new to the capability cache
  # has its catalogue read right away, not at the next 6-hourly refresh, so
  # its snapshot row exists before a restart could need it.
  defp refresh_capabilities({:ok, _} = result, true) do
    Capabilities.refresh_after_change()
    result
  end

  defp refresh_capabilities(result, _changed?), do: result

  defp catalogue_inputs_changed?(changeset) do
    Enum.any?(
      [:model, :provider, :base_url, :integration_uuid],
      &Map.has_key?(changeset.changes, &1)
    )
  end

  # Declaring capabilities on an endpoint (`provider_settings["capabilities"]`)
  # is logged on its own, with the flags, whenever the stored declaration
  # changes — set, changed, or removed (a model change removes it).
  defp log_capabilities_declaration({:ok, endpoint} = result, before, opts) do
    old = capabilities_declaration(before)
    new = capabilities_declaration(endpoint)

    if old != new do
      metadata =
        case new do
          nil -> %{"name" => endpoint.name, "model" => endpoint.model, "cleared" => true}
          declaration -> Map.put(declaration, "name", endpoint.name)
        end

      log_activity("endpoint.capabilities_declared", "endpoint", endpoint.uuid, opts, metadata)
    end

    result
  end

  defp log_capabilities_declaration(result, _before, _opts), do: result

  # A manual price (`PhoenixKitAI.ManualPrice`) set, changed or removed is
  # logged with the price before and after, dollar strings per 1M tokens.
  defp log_pricing_change({:ok, endpoint} = result, before, opts) do
    old = before |> ManualPrice.get() |> price_strings()
    new = endpoint |> ManualPrice.get() |> price_strings()

    if old != new do
      log_activity("endpoint.pricing_changed", "endpoint", endpoint.uuid, opts, %{
        "name" => endpoint.name,
        "model" => endpoint.model,
        "input_before" => old["input"],
        "input_after" => new["input"],
        "output_before" => old["output"],
        "output_after" => new["output"]
      })
    end

    result
  end

  defp log_pricing_change(result, _before, _opts), do: result

  defp price_strings(nil), do: %{}

  defp price_strings(pricing),
    do: Map.new(pricing, fn {half, dollars} -> {half, Money.to_json(dollars)} end)

  # While only verified models may be used (`Guard.verified_only?/0`), what
  # an admin declares an endpoint's model can do decides which calls go
  # through, so a new or changed declaration needs `ai.manage` (the `:scope`
  # option; an Owner always). Keeping a declaration as it is, or removing
  # one, needs nothing.
  defp guard_declaration(changeset, before, opts) do
    declared =
      capabilities_declaration(%Endpoint{
        provider_settings: Ecto.Changeset.get_field(changeset, :provider_settings)
      })

    if declared != nil and declared != capabilities_declaration(before) and
         Guard.verified_only?() and not Guard.may_manage?(opts[:scope]) do
      Ecto.Changeset.add_error(
        changeset,
        :provider_settings,
        gettext(
          "only a holder of ai.manage may declare capabilities while only verified models are allowed"
        )
      )
    else
      changeset
    end
  end

  # A manual price steers the money limits (`PhoenixKitAI.ManualPrice`), so
  # setting, changing or removing one needs `ai.manage` (the `:scope`
  # option; an Owner always). A price dropped because the model changed
  # needs nothing: it no longer applies.
  defp guard_pricing(changeset, before, opts) do
    new = changeset |> Ecto.Changeset.get_field(:provider_settings) |> stored_pricing()
    old = stored_pricing(before.provider_settings)
    model = Ecto.Changeset.get_field(changeset, :model)
    dropped_stale? = new == nil and old != nil and old["model"] != model

    if new != old and not dropped_stale? and not Guard.may_manage?(opts[:scope]) do
      Ecto.Changeset.add_error(
        changeset,
        :provider_settings,
        gettext("only a holder of ai.manage may set or change a manual price")
      )
    else
      changeset
    end
  end

  # The halves in one spelling ("0.6" and "0.60" are the same price), so a
  # re-save of the same price is not a change.
  defp stored_pricing(%{"pricing" => %{} = pricing}) do
    Map.new(pricing, fn
      {half, value} when half in ["input", "output"] ->
        case Money.to_decimal(value) do
          {:ok, dollars} when is_binary(value) -> {half, Money.to_json(dollars)}
          _ -> {half, value}
        end

      other ->
        other
    end)
  end

  defp stored_pricing(_settings), do: nil

  defp capabilities_declaration(%Endpoint{provider_settings: %{"capabilities" => declaration}})
       when is_map(declaration) do
    Map.take(declaration, ["model" | Enum.map(Capabilities.declarable(), &Atom.to_string/1)])
  end

  defp capabilities_declaration(_endpoint), do: nil

  @doc """
  Deletes an AI endpoint.
  """
  @spec delete_endpoint(Endpoint.t(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def delete_endpoint(%Endpoint{} = endpoint, opts \\ []) do
    repo().delete(endpoint)
    |> tap(fn _ -> PhoenixKitAI.Cache.invalidate_endpoint(endpoint.uuid) end)
    |> broadcast_endpoint_change(:endpoint_deleted)
    |> log_endpoint_activity("endpoint.deleted", opts)
    |> log_failed_endpoint_mutation("endpoint.deleted", opts)
  end

  @doc """
  Returns an endpoint changeset for use in forms.
  """
  @spec change_endpoint(Endpoint.t(), map()) :: Ecto.Changeset.t()
  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    # Built on every keystroke: the base URL's host is not resolved here
    # (`create_endpoint/2` and `update_endpoint/3` do that on save).
    Endpoint.changeset(endpoint, attrs, resolve_base_url: false)
  end

  @doc """
  Marks an endpoint as validated by updating its last_validated_at timestamp.
  """
  @spec mark_endpoint_validated(Endpoint.t()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def mark_endpoint_validated(%Endpoint{} = endpoint) do
    endpoint
    |> Endpoint.validation_changeset()
    |> repo().update()
  end

  @doc """
  Counts the total number of endpoints.
  """
  @spec count_endpoints() :: non_neg_integer()
  def count_endpoints do
    repo().aggregate(Endpoint, :count)
  end

  @doc """
  Counts the number of enabled endpoints.
  """
  @spec count_enabled_endpoints() :: non_neg_integer()
  def count_enabled_endpoints do
    query = from(e in Endpoint, where: e.enabled == true)
    repo().aggregate(query, :count)
  end

  # ===========================================
  # PROMPT CRUD
  # ===========================================

  @doc """
  Lists all AI prompts.

  ## Options
  - `:sort_by` - Field to sort by (default: :sort_order)
  - `:sort_dir` - Sort direction, :asc or :desc (default: :asc)
  - `:enabled` - Filter by enabled status

  ## Examples

      PhoenixKitAI.list_prompts()
      PhoenixKitAI.list_prompts(sort_by: :name, sort_dir: :asc)
      PhoenixKitAI.list_prompts(enabled: true)
  """
  @spec list_prompts(keyword()) :: [Prompt.t()] | {[Prompt.t()], non_neg_integer()}
  def list_prompts(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :sort_order)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)
    page = Keyword.get(opts, :page)
    page_size = Keyword.get(opts, :page_size, 20)

    query = from(p in Prompt)

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [p], p.enabled == ^enabled)
      end

    # Stable tiebreaker on :uuid so tied sort-field values get deterministic
    # ordering (otherwise pagination + refresh can subtly reshuffle rows).
    query = order_by(query, [p], [{^sort_dir, field(p, ^sort_by)}, asc: p.uuid])

    # If page is provided, return paginated results with total count
    if page do
      total = repo().aggregate(query, :count)
      offset = (page - 1) * page_size

      prompts =
        query
        |> limit(^page_size)
        |> offset(^offset)
        |> repo().all()

      {prompts, total}
    else
      # No pagination - return all (backwards compatible)
      repo().all(query)
    end
  end

  @doc """
  Lists only enabled prompts.

  Convenience wrapper for `list_prompts(enabled: true)`.

  ## Examples

      PhoenixKitAI.list_enabled_prompts()
  """
  @spec list_enabled_prompts() :: [Prompt.t()] | {[Prompt.t()], non_neg_integer()}
  def list_enabled_prompts do
    list_prompts(enabled: true)
  end

  @doc """
  Gets a single prompt by UUID.

  Raises `Ecto.NoResultsError` if the prompt does not exist.
  """
  @spec get_prompt!(String.t()) :: Prompt.t()
  def get_prompt!(id) do
    case get_prompt(id) do
      nil -> raise Ecto.NoResultsError, queryable: Prompt
      prompt -> prompt
    end
  end

  @doc """
  Gets a single prompt by UUID.

  Accepts a UUID string (e.g., "550e8400-e29b-41d4-a716-446655440000").

  Returns `nil` if the prompt does not exist.
  """
  @spec get_prompt(term()) :: Prompt.t() | nil
  def get_prompt(id) when is_binary(id) do
    if textual_uuid?(id) do
      repo().get_by(Prompt, uuid: id)
    else
      nil
    end
  end

  def get_prompt(_), do: nil

  @doc """
  Gets a prompt by slug.

  Returns `nil` if the prompt does not exist.
  """
  @spec get_prompt_by_slug(String.t()) :: Prompt.t() | nil
  def get_prompt_by_slug(slug) when is_binary(slug) do
    repo().get_by(Prompt, slug: slug)
  end

  @doc """
  Creates a new AI prompt.

  ## Examples

      {:ok, prompt} = PhoenixKitAI.create_prompt(%{
        name: "Translator",
        content: "Translate the following text to {{Language}}:\\n\\n{{Text}}"
      })
  """
  @spec create_prompt(map(), keyword()) ::
          {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def create_prompt(attrs, opts \\ []) do
    # `log: false`: the query log would print the prompt text.
    %Prompt{}
    |> Prompt.changeset(attrs)
    |> repo().insert(log: false)
    |> broadcast_prompt_change(:prompt_created)
    |> log_prompt_activity("prompt.created", opts)
    |> log_failed_prompt_mutation("prompt.created", opts)
  end

  @doc """
  Updates an existing AI prompt.

  Accepts an `:actor_uuid` option so the mutation can be attributed in
  the activity feed. If the change toggles the `enabled` flag an
  additional `prompt.enabled` / `prompt.disabled` entry is logged.
  """
  @spec update_prompt(Prompt.t(), map(), keyword()) ::
          {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def update_prompt(%Prompt{} = prompt, attrs, opts \\ []) do
    was_enabled = prompt.enabled
    changeset = Prompt.changeset(prompt, attrs)
    has_changes = changeset.changes != %{}

    # `log: false`: the query log would print the prompt text.
    changeset
    |> repo().update(log: false)
    |> broadcast_prompt_change(:prompt_updated)
    |> maybe_log_prompt_update(has_changes, opts)
    |> maybe_log_prompt_toggle(was_enabled, opts)
    |> log_failed_prompt_mutation("prompt.updated", opts)
  end

  defp maybe_log_prompt_update({:ok, _} = result, true, opts) do
    log_prompt_activity(result, "prompt.updated", opts)
  end

  defp maybe_log_prompt_update(result, _has_changes, _opts), do: result

  @doc """
  Deletes an AI prompt.
  """
  @spec delete_prompt(Prompt.t(), keyword()) ::
          {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def delete_prompt(%Prompt{} = prompt, opts \\ []) do
    repo().delete(prompt)
    |> broadcast_prompt_change(:prompt_deleted)
    |> log_prompt_activity("prompt.deleted", opts)
    |> log_failed_prompt_mutation("prompt.deleted", opts)
  end

  @doc """
  Returns a prompt changeset for use in forms.
  """
  @spec change_prompt(Prompt.t(), map()) :: Ecto.Changeset.t()
  def change_prompt(%Prompt{} = prompt, attrs \\ %{}) do
    Prompt.changeset(prompt, attrs)
  end

  @doc """
  Increments the usage count for a prompt and updates last_used_at.
  """
  @spec record_prompt_usage(Prompt.t()) :: {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def record_prompt_usage(%Prompt{} = prompt) do
    prompt
    |> Prompt.usage_changeset()
    |> repo().update()
  end

  @doc """
  Counts the total number of prompts.
  """
  @spec count_prompts() :: non_neg_integer()
  def count_prompts do
    repo().aggregate(Prompt, :count)
  end

  @doc """
  Counts the number of enabled prompts.
  """
  @spec count_enabled_prompts() :: non_neg_integer()
  def count_enabled_prompts do
    query = from(p in Prompt, where: p.enabled == true)
    repo().aggregate(query, :count)
  end

  @doc """
  Resolves a prompt from various input types.

  Accepts:
  - UUID string (e.g., "019abc12-3456-7def-8901-234567890abc")
  - String slug (e.g., "my-prompt")
  - Prompt struct (returned as-is)

  Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  @spec resolve_prompt(term()) :: {:ok, Prompt.t()} | {:error, {:prompt_error, atom()}}
  def resolve_prompt(%Prompt{} = prompt), do: {:ok, prompt}

  def resolve_prompt(id_or_slug) when is_binary(id_or_slug) do
    if textual_uuid?(id_or_slug) do
      # It's a UUID
      case get_prompt(id_or_slug) do
        nil -> {:error, {:prompt_error, :not_found}}
        prompt -> {:ok, prompt}
      end
    else
      # It's a slug
      case get_prompt_by_slug(id_or_slug) do
        nil -> {:error, {:prompt_error, :not_found}}
        prompt -> {:ok, prompt}
      end
    end
  end

  def resolve_prompt(_), do: {:error, {:prompt_error, :invalid_identifier}}

  @doc """
  Renders a prompt by replacing variables with provided values.

  Returns `{:ok, rendered_text}` or `{:error, reason}`.
  """
  @spec render_prompt(String.t() | Prompt.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_prompt(prompt_uuid, variables \\ %{}) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      Prompt.render(prompt, variables)
    end
  end

  @doc """
  Increments the usage count for a prompt and updates last_used_at.
  """
  @spec increment_prompt_usage(String.t() | Prompt.t()) :: {:ok, Prompt.t()} | {:error, term()}
  def increment_prompt_usage(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      record_prompt_usage(prompt)
    end
  end

  @doc """
  Makes an AI completion using a prompt template.

  The prompt content is rendered with the provided variables and sent as
  the user message.
  """
  @spec ask_with_prompt(String.t() | Endpoint.t(), String.t() | Prompt.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ask_with_prompt(endpoint_uuid, prompt_uuid, variables \\ %{}, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, rendered} <- Prompt.render(prompt, variables),
         {:ok, system_prompt} <- Prompt.render_system_prompt(prompt, variables) do
      # §9.2 guard: after rendering, check whether any `{{...}}` is still
      # literally present — a variable the caller didn't bind. Non-fatal
      # (a prompt may legitimately contain a literal `{{...}}`), but cheap
      # insurance against the whole defect class diagnosed in the
      # translation-control design doc §2: an unbound placeholder left in
      # a rendered prompt reads to the model as real content, not an
      # error. Logged now; recorded into the request's metadata below via
      # `:unbound_placeholders` so it shows up next to the request that
      # actually rendered it, not just in the log stream.
      unbound =
        detect_unbound_placeholders(prompt, [prompt.content, prompt.system_prompt], variables)

      # Pass prompt info to ask for request logging
      opts_with_prompt =
        opts
        |> Keyword.put(:prompt_uuid, prompt.uuid)
        |> Keyword.put(:prompt_name, prompt.name)
        |> Keyword.put(:prompt_snapshot, prompt_snapshot(prompt))
        |> Keyword.put(:unbound_placeholders, unbound)

      # Include system prompt if the prompt template defines one
      opts_with_prompt =
        if system_prompt do
          Keyword.put_new(opts_with_prompt, :system, system_prompt)
        else
          opts_with_prompt
        end

      case ask(endpoint_uuid, rendered, opts_with_prompt) do
        {:ok, response} ->
          # Only increment usage on successful completion
          increment_prompt_usage(prompt_uuid)
          {:ok, response}

        error ->
          error
      end
    end
  end

  # What the saved prompt was when it ran: an admin can edit it later and a
  # "write once" answer should still say which version produced it. A
  # content hash only — `updated_at` moves on every usage increment.
  defp prompt_snapshot(%Prompt{} = prompt) do
    body = (prompt.system_prompt || "") <> "\n---\n" <> (prompt.content || "")
    %{hash: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)}
  end

  # §9.2: finds the `{{...}}` placeholders the given templates (user prompt,
  # system prompt) leave unbound and logs a warning when any are found.
  # Returns the deduplicated list so the caller can thread it into request
  # metadata. Scans the templates, not the rendered text: a variable's value
  # is caller content (source text to translate), and a `{{...}}` inside it
  # is neither a template defect nor something to copy into logs and
  # metadata outside the `capture_request_content?/0` gate.
  defp detect_unbound_placeholders(prompt, templates, variables) do
    unbound =
      templates
      |> Enum.flat_map(&Prompt.unbound_placeholders(&1, variables))
      |> Enum.uniq()

    if unbound != [] do
      Logger.warning(
        "[PhoenixKitAI] prompt #{inspect(prompt.slug)} rendered with unbound " <>
          "placeholder(s): #{Enum.join(unbound, ", ")}"
      )
    end

    unbound
  end

  @doc """
  Makes an AI completion with a prompt template as the system message.

  The prompt is rendered and used as the system message, with the user_message
  as the user message.
  """
  @spec complete_with_system_prompt(
          String.t() | Endpoint.t(),
          String.t() | Prompt.t(),
          map(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def complete_with_system_prompt(endpoint_uuid, prompt_uuid, variables, user_message, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, system_prompt} <- Prompt.render(prompt, variables) do
      # Build messages with system prompt
      messages = [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_message}
      ]

      # §9.2 guard — the same net `ask_with_prompt/4` applies. This is the
      # module's other render-a-template-then-call-the-model path, so an
      # unbound `{{...}}` reaching a model through it has to be just as
      # visible; only `content` is rendered here (as the system message).
      unbound = detect_unbound_placeholders(prompt, [prompt.content], variables)

      # Pass prompt info to complete for request logging
      opts_with_prompt =
        opts
        |> Keyword.put(:prompt_uuid, prompt.uuid)
        |> Keyword.put(:prompt_name, prompt.name)
        |> Keyword.put(:prompt_snapshot, prompt_snapshot(prompt))
        |> Keyword.put(:unbound_placeholders, unbound)

      case complete(endpoint_uuid, messages, opts_with_prompt) do
        {:ok, response} ->
          # Only increment usage on successful completion
          increment_prompt_usage(prompt_uuid)
          {:ok, response}

        error ->
          error
      end
    end
  end

  @doc """
  Validates that a prompt is ready for use.

  Returns `{:ok, prompt}` if valid, or `{:error, reason}` if not.
  """
  @spec validate_prompt(Prompt.t()) :: {:ok, Prompt.t()} | {:error, {:prompt_error, atom()}}
  def validate_prompt(prompt) do
    cond do
      prompt.content == nil or prompt.content == "" ->
        {:error, {:prompt_error, :empty_content}}

      prompt.enabled == false ->
        {:error, {:prompt_error, :disabled}}

      true ->
        {:ok, prompt}
    end
  end

  @doc """
  Duplicates a prompt with a new name.

  Everything the operator wrote is copied (description, system prompt,
  content, enabled, position, metadata); the slug and variables are derived
  afresh and the usage counters start at zero. `opts` takes `:actor_uuid`,
  as `create_prompt/2` does.
  """
  @spec duplicate_prompt(String.t(), String.t(), keyword()) ::
          {:ok, Prompt.t()} | {:error, term()}
  def duplicate_prompt(prompt_uuid, new_name, opts \\ []) when is_binary(new_name) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      create_prompt(
        %{
          name: new_name,
          description: prompt.description,
          system_prompt: prompt.system_prompt,
          content: prompt.content,
          enabled: prompt.enabled,
          sort_order: prompt.sort_order,
          metadata: prompt.metadata
        },
        opts
      )
    end
  end

  @doc """
  Enables a prompt. `opts` takes `:actor_uuid`, as `update_prompt/3` does.
  """
  @spec enable_prompt(String.t(), keyword()) :: {:ok, Prompt.t()} | {:error, term()}
  def enable_prompt(prompt_uuid, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      update_prompt(prompt, %{enabled: true}, opts)
    end
  end

  @doc """
  Disables a prompt. `opts` takes `:actor_uuid`, as `update_prompt/3` does.
  """
  @spec disable_prompt(String.t(), keyword()) :: {:ok, Prompt.t()} | {:error, term()}
  def disable_prompt(prompt_uuid, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      update_prompt(prompt, %{enabled: false}, opts)
    end
  end

  @doc """
  Gets the variables defined in a prompt.
  """
  @spec get_prompt_variables(String.t() | Prompt.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_prompt_variables(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      {:ok, prompt.variables || []}
    end
  end

  @doc """
  Previews a rendered prompt without making an AI call.
  """
  @spec preview_prompt(String.t() | Prompt.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def preview_prompt(prompt_uuid, variables \\ %{}) do
    render_prompt(prompt_uuid, variables)
  end

  @doc """
  Validates that all required variables are provided for a prompt.
  """
  @spec validate_prompt_variables(String.t() | Prompt.t(), term()) ::
          :ok | {:error, term()}
  def validate_prompt_variables(prompt_uuid, variables) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      Prompt.validate_variables(prompt, variables)
    end
  end

  @doc """
  Searches prompts by name, description, or content. LIKE metacharacters in
  `query` (`%`, `_`, `\\`) are matched literally.
  """
  @spec search_prompts(String.t(), keyword()) :: [Prompt.t()]
  def search_prompts(query, opts \\ []) when is_binary(query) do
    pattern = "%#{escape_like(query)}%"
    limit = Keyword.get(opts, :limit, 50)

    base_query =
      from(p in Prompt,
        where:
          ilike(p.name, ^pattern) or
            ilike(p.description, ^pattern) or
            ilike(p.content, ^pattern),
        order_by: [asc: p.sort_order, desc: p.inserted_at, asc: p.uuid],
        limit: ^limit
      )

    base_query =
      case Keyword.get(opts, :enabled) do
        nil -> base_query
        enabled -> where(base_query, [p], p.enabled == ^enabled)
      end

    repo().all(base_query)
  end

  @doc """
  Finds all prompts that use a specific variable.
  """
  @spec get_prompts_with_variable(String.t()) :: [Prompt.t()]
  def get_prompts_with_variable(variable_name) when is_binary(variable_name) do
    query =
      from(p in Prompt,
        where: ^variable_name in p.variables,
        order_by: [asc: p.sort_order, desc: p.inserted_at, asc: p.uuid]
      )

    repo().all(query)
  end

  @doc """
  Validates that the content has valid variable syntax.
  """
  @spec validate_prompt_content(term()) :: :ok | {:error, term()}
  def validate_prompt_content(content) when is_binary(content) do
    all_patterns = Regex.scan(~r/\{\{([^}]+)\}\}/, content)

    invalid =
      all_patterns
      |> Enum.map(fn [_full, inner] -> inner end)
      |> Enum.reject(fn inner -> Regex.match?(~r/^\w+$/, inner) end)

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, invalid}
    end
  end

  def validate_prompt_content(_), do: {:error, {:prompt_error, :content_not_string}}

  @doc """
  Gets usage statistics for all prompts.
  """
  @spec get_prompt_usage_stats(keyword()) :: [map()]
  def get_prompt_usage_stats(opts \\ []) do
    query =
      from(p in Prompt,
        select: %{
          prompt: p,
          usage_count: p.usage_count,
          last_used_at: p.last_used_at
        },
        order_by: [desc: p.usage_count, desc: p.last_used_at]
      )

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [p], p.enabled == ^enabled)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    repo().all(query)
  end

  @doc """
  Resets the usage statistics for a prompt, logging a `prompt.usage_reset`
  activity row. `opts` takes `:actor_uuid`, as `update_prompt/3` does.
  """
  @spec reset_prompt_usage(String.t(), keyword()) :: {:ok, Prompt.t()} | {:error, term()}
  def reset_prompt_usage(prompt_uuid, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      prompt
      |> Ecto.Changeset.change(%{usage_count: 0, last_used_at: nil})
      |> repo().update()
      |> log_prompt_activity("prompt.usage_reset", opts)
      |> log_failed_prompt_mutation("prompt.usage_reset", opts)
    end
  end

  @doc """
  Reorders prompts based on a list of UUIDs in their new display order.

  Delegates to `PhoenixKit.Utils.Reorder.reorder/4` — the same shared
  two-phase index-rewrite primitive `reorder_endpoints/2` uses, so the
  two reorder paths share the malformed-uuid filtering, dedup, and
  payload-cap guard. Returns `:ok` on success or
  `{:error, :too_many_uuids}` when the payload exceeds the cap.

  On success, logs one `prompt.reordered` activity row with the actual
  updated count and, as the resource, the first uuid in the new order that
  names an existing row (`Reorder` skips ids it does not know) so the audit
  feed records the drag-to-reorder action without per-row noise. `opts` is forwarded to
  `log_activity/5` so callers can thread `actor_uuid` / `actor_role`.
  """
  @spec reorder_prompts([String.t()], keyword()) :: :ok | {:error, :too_many_uuids}
  def reorder_prompts(ordered_ids, opts \\ []) when is_list(ordered_ids) do
    case Reorder.reorder(Prompt, ordered_ids, :sort_order, repo: repo()) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        log_activity(
          "prompt.reordered",
          "prompt",
          first_existing_uuid(Prompt, ordered_ids),
          opts,
          %{"count" => count}
        )

        :ok

      # See `reorder_endpoints/2` — `:too_many_uuids` is the only error
      # `Reorder.reorder/4` emits; match it explicitly to stay in sync
      # with @spec.
      {:error, :too_many_uuids} = err ->
        err
    end
  end

  # The audit row's resource: the first id in the caller's order that is a
  # real row. `Reorder.reorder/4` filters unknown ids silently, so the raw
  # first element could name a row that was never touched (PR #9 review).
  defp first_existing_uuid(schema, ordered_ids) do
    import Ecto.Query, only: [from: 2]

    uuids = for id <- ordered_ids, is_binary(id), match?({:ok, _}, Ecto.UUID.cast(id)), do: id

    case uuids do
      [] ->
        nil

      uuids ->
        existing = repo().all(from(r in schema, where: r.uuid in ^uuids, select: r.uuid))
        Enum.find(uuids, &(&1 in existing))
    end
  end

  @doc """
  Reorders endpoints based on a list of UUIDs in their new display order.

  Delegates to `PhoenixKit.Utils.Reorder.reorder/4` for the shared
  two-phase index-rewrite primitive. Returns `:ok` on success or
  `{:error, :too_many_uuids}` when the payload exceeds the cap.

  On success, logs one `endpoint.reordered` activity row with the
  actual updated count and, as the resource, the first uuid in the new
  order that names an existing row (`Reorder` skips ids it does not
  know) so the audit feed records the drag-to-reorder action without
  per-row noise. `opts` is forwarded
  to `log_activity/5` so callers can thread `actor_uuid` / `mode`.
  """
  @spec reorder_endpoints([String.t()], keyword()) :: :ok | {:error, :too_many_uuids}
  def reorder_endpoints(ordered_ids, opts \\ []) when is_list(ordered_ids) do
    case Reorder.reorder(Endpoint, ordered_ids, :sort_order, repo: repo()) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        log_activity(
          "endpoint.reordered",
          "endpoint",
          first_existing_uuid(Endpoint, ordered_ids),
          opts,
          %{"count" => count}
        )

        :ok

      # `Reorder.reorder/4`'s @type result only ever errors with
      # `:too_many_uuids` — match it explicitly so this body stays in
      # sync with @spec. A future error tag from the helper would fail
      # here loudly rather than leak an undocumented value to callers.
      {:error, :too_many_uuids} = err ->
        err
    end
  end

  # ===========================================
  # USAGE TRACKING (REQUESTS)
  # ===========================================

  @doc """
  Lists AI requests with pagination and filters.

  ## Options
  - `:page` - Page number (default: 1)
  - `:page_size` - Results per page (default: 20)
  - `:endpoint_uuid` - Filter by endpoint
  - `:user_uuid` - Filter by user
  - `:status` - Filter by status
  - `:model` - Filter by model
  - `:source` - Filter by source (from metadata)
  - `:source_prefix` - Filter by sources starting with this prefix
  - `:since` - Filter by date (requests after this date)
  - `:preload` - Associations to preload

  ## Returns
  `{requests, total_count}`
  """
  @spec list_requests(keyword()) :: {[Request.t()], non_neg_integer()}
  def list_requests(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    offset = (page - 1) * page_size
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)
    base_query = apply_request_sorting(base_query, sort_by, sort_dir)

    total = repo().aggregate(base_query, :count)

    query =
      base_query
      |> limit(^page_size)
      |> offset(^offset)

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    requests = repo().all(query)

    {requests, total}
  end

  defp apply_request_sorting(query, field, dir)
       when field in [
              :inserted_at,
              :model,
              :total_tokens,
              :latency_ms,
              :cost,
              :status,
              :endpoint_name
            ] do
    # `inserted_at` has second precision: the uuid (time-ordered) breaks a tie,
    # so a page boundary inside one second neither repeats nor skips a row.
    order_by(query, [r], [{^dir, field(r, ^field)}, {^dir, r.uuid}])
  end

  defp apply_request_sorting(query, _field, _dir) do
    order_by(query, [r], desc: r.inserted_at, desc: r.uuid)
  end

  @doc """
  Gets a single request by UUID.
  """
  @spec get_request!(String.t()) :: Request.t()
  def get_request!(id) do
    case get_request(id) do
      nil -> raise Ecto.NoResultsError, queryable: Request
      request -> request
    end
  end

  @doc """
  Gets a single request by UUID.

  Accepts a UUID string (e.g., "550e8400-e29b-41d4-a716-446655440000").

  Returns `nil` if the request does not exist.
  """
  @spec get_request(term()) :: Request.t() | nil
  def get_request(id) when is_binary(id) do
    if textual_uuid?(id) do
      repo().get_by(Request, uuid: id)
    else
      nil
    end
  end

  def get_request(_), do: nil

  # Opaque attribution payload: string-keyed, nil for junk (this package
  # records it verbatim; usage sinks interpret it).
  defp normalize_attribution(map) when is_map(map) and map_size(map) > 0 do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_attribution(_), do: nil

  defp maybe_put_prompt_snapshot(metadata, %{} = snapshot),
    do: Map.put(metadata, :prompt_snapshot, snapshot)

  defp maybe_put_prompt_snapshot(metadata, _), do: metadata

  defp maybe_put_attribution(metadata, nil), do: metadata

  defp maybe_put_attribution(metadata, attribution),
    do: Map.put(metadata, :attribution, attribution)

  # §9.2: only stamp `unbound_placeholders` when the guard actually found
  # something — the common case (nothing unbound, or no prompt template
  # involved at all — plain `complete/3`/`ask/3` calls never set this key
  # in `opts`) stays metadata-neutral rather than adding a noisy `[]` to
  # every single request row.
  defp maybe_put_unbound_placeholders(metadata, list) when list in [nil, []], do: metadata

  defp maybe_put_unbound_placeholders(metadata, list),
    do: Map.put(metadata, :unbound_placeholders, list)

  @doc """
  Usage sinks: every discovered module exporting `handle_ai_usage/1`
  receives each persisted `%Request{}` — the zero-coupling observer seam
  (the Translatables discovery pattern), first consumer being the
  projects work ledger's AI attribution. Best-effort per sink: a raising
  sink is logged and never breaks request logging.

  A row of a call the guard refused before any HTTP (`metadata.refused`)
  is not dispatched: nothing was spent, and a sink such as a work ledger
  would book it as work all the same.
  """
  @spec dispatch_usage_sinks(Request.t()) :: :ok
  def dispatch_usage_sinks(%Request{} = request) do
    if refused_row?(request), do: :ok, else: dispatch_to_sinks(request)
  end

  defp refused_row?(%Request{metadata: %{} = metadata}),
    do: Map.get(metadata, :refused, Map.get(metadata, "refused")) == true

  defp refused_row?(_request), do: false

  defp dispatch_to_sinks(request) do
    PhoenixKit.ModuleRegistry.all_modules()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :handle_ai_usage, 1)
    end)
    |> Enum.each(fn module ->
      try do
        module.handle_ai_usage(request)
      rescue
        e ->
          Logger.error("AI usage sink #{inspect(module)} failed: #{Exception.message(e)}")
      catch
        # `kind, reason` (not just :exit) — a sink that THROWS must not
        # break request logging either (the panel's contract-gap find).
        kind, reason ->
          Logger.error("AI usage sink #{inspect(module)} #{kind}: #{inspect(reason)}")
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # The usage loggers' entry point: writes the row now, or hands it to
  # `PhoenixKitAI.RequestLog` when `request_log_mode: :async` (default `:sync`).
  # A queued row gets its uuid here, so the answer can name it
  # (`request_uuid`) before it is written; the struct handed back carries
  # only that uuid. `create_request/1` itself stays synchronous — it is
  # public and returns the row.
  @spec log_usage(map()) :: {:ok, Request.t()} | {:error, term()}
  def log_usage(attrs) do
    # A row that would not insert is written now instead, where
    # `create_request/1` logs why and the answer names no row.
    if PhoenixKitAI.RequestLog.async?() and Request.changeset(%Request{}, attrs).valid? do
      uuid = UUIDv7.generate()
      :ok = PhoenixKitAI.RequestLog.enqueue({uuid, attrs})
      # The row is not written yet; the uuid and the cost it will carry are
      # known, so a verb can still hand both back.
      {:ok, %Request{uuid: uuid, cost: Map.get(attrs, :cost)}}
    else
      create_request(attrs)
    end
  end

  @doc false
  # Used by `PhoenixKitAI.RequestLog` to write a queued row under the uuid
  # `log_usage/1` gave it.
  @spec write_request(Ecto.UUID.t(), map()) :: {:ok, Request.t()} | {:error, term()}
  def write_request(uuid, attrs), do: do_create_request(attrs, uuid)

  @doc """
  Creates a new AI request record.

  Used to log every AI API call for tracking and statistics.

  A call that has happened is written even when one of its references does
  not resolve. `user_uuid`, `endpoint_uuid` and `prompt_uuid` are foreign
  keys, so an id that names no row — a caller passing a stale or foreign user
  id, an endpoint deleted mid-call — used to fail the insert, and the usage
  row of a call already made (and paid for) vanished from the log and every
  spend cap. Such a reference is now left empty, the submitted id is kept in
  `metadata["unresolved_refs"]`, and a warning is logged. The row still counts
  toward every cap it can be attributed to (a row without a user still counts
  toward its endpoint's and the global cap). Several dangling references are
  all dropped, and inside a caller's transaction the refused insert is
  confined to a savepoint so the retry — and the caller's transaction — go on.

  Any other validation failure still returns `{:error, changeset}`.
  """
  @spec create_request(map()) :: {:ok, Request.t()} | {:error, term()}
  def create_request(attrs), do: do_create_request(attrs, nil)

  defp do_create_request(attrs, uuid) do
    result =
      attrs
      |> insert_request(uuid, [])
      |> broadcast_request_change(:request_created)

    case result do
      {:ok, request} ->
        emit_request_telemetry(request)
        dispatch_usage_sinks(request)
        Guard.check_anomalies(request)
        {:ok, request}

      {:error, %Ecto.Changeset{} = changeset} = error ->
        # Every logger discards this result; a usage row that fails to
        # insert must not vanish quietly.
        Logger.warning(
          "[PhoenixKitAI] usage row not written: #{inspect(changeset.errors)} (type=#{inspect(attr(attrs, :request_type))})"
        )

        error

      other ->
        other
    end
  end

  @unresolvable_refs [:user_uuid, :endpoint_uuid, :prompt_uuid]

  # Postgres stops at the first foreign key it finds broken, so a row with two
  # dangling references reports one per attempt: retry, dropping what has been
  # refused so far, until the insert succeeds or fails for another reason. At
  # most one retry per reference.
  defp insert_request(attrs, uuid, dropped) do
    case attrs |> without_refs(dropped) |> insert_row(uuid) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        case unresolved_refs(changeset) -- dropped do
          [] -> error
          fields -> insert_request(attrs, uuid, dropped ++ fields)
        end

      {:ok, _} = ok when dropped != [] ->
        Logger.warning(
          "[PhoenixKitAI] usage row written without #{Enum.join(dropped, ", ")}: " <>
            "no such row for #{inspect(submitted_refs(attrs, dropped))} (type=#{inspect(attr(attrs, :request_type))})"
        )

        ok

      other ->
        other
    end
  end

  # Inside a caller's transaction a refused insert aborts the whole
  # transaction, so the retry (and every later query of the caller) would fail
  # with `in_failed_sql_transaction`. A savepoint confines the failure to this
  # statement. Outside a transaction there is nothing to protect.
  # `log: false`: the query log would print the captured messages and reply.
  defp insert_row(attrs, uuid) do
    opts = if repo().in_transaction?(), do: [mode: :savepoint, log: false], else: [log: false]

    %Request{uuid: uuid}
    |> Request.changeset(attrs)
    |> repo().insert(opts)
  end

  # The references the database refused because the row they name does not
  # exist. Only a foreign-key violation counts: that is the database saying
  # "no such row", which is conclusive. Any other error keeps failing.
  defp unresolved_refs(%Ecto.Changeset{errors: errors}) do
    for {field, {_message, opts}} <- errors,
        field in @unresolvable_refs,
        Keyword.get(opts, :constraint) == :foreign,
        uniq: true,
        do: field
  end

  defp without_refs(attrs, []), do: attrs

  defp without_refs(attrs, fields) do
    metadata =
      attrs
      |> attr(:metadata)
      |> case do
        %{} = map -> map
        _ -> %{}
      end
      |> Map.put("unresolved_refs", submitted_refs(attrs, fields))

    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(Enum.map(fields, &Atom.to_string/1))
    |> Map.put("metadata", metadata)
  end

  defp submitted_refs(attrs, fields), do: Map.new(fields, &{Atom.to_string(&1), attr(attrs, &1)})

  # Attrs arrive with atom keys from this module and string keys from callers
  # that pass params through.
  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  # `[:phoenix_kit_ai, :request]` — one event per usage row, every verb,
  # cached rows included; tags only, never content.
  defp emit_request_telemetry(%Request{} = request) do
    metadata = request.metadata || %{}

    :telemetry.execute(
      [:phoenix_kit_ai, :request],
      %{
        input_tokens: request.input_tokens || 0,
        output_tokens: request.output_tokens || 0,
        # dollars; a measurement must be a number, so a float here only
        cost: if(request.cost, do: Decimal.to_float(request.cost), else: 0.0),
        latency_ms: request.latency_ms || 0
      },
      %{
        request_type: request.request_type,
        status: request.status,
        endpoint_uuid: request.endpoint_uuid,
        model: request.model,
        user_uuid: request.user_uuid,
        source: metadata["source"] || metadata[:source],
        cached: (metadata["cached"] || metadata[:cached]) == true
      }
    )
  rescue
    _ -> :ok
  end

  # The provider call behind each cached verb, out of the closure so the
  # verbs stay flat: call, log the success row, shape the return.
  defp run_complete(
         endpoint,
         messages,
         merged_opts,
         format,
         {source, stacktrace, caller_context, prompt_info}
       ) do
    with {:ok, response} <-
           StructuredOutput.with_fallback(format, fn retry_format ->
             PhoenixKitAI.Completion.chat_completion(
               endpoint,
               messages,
               put_response_format(merged_opts, format, retry_format)
             )
           end) do
      logged =
        log_request(
          endpoint,
          messages,
          response,
          source,
          stacktrace,
          caller_context,
          prompt_info
        )

      # Parsed here, before the cache sees the result, so a prose answer to
      # a JSON request is never stored as a success.
      response
      |> put_request_uuid("request_uuid", logged)
      |> attach_json(format != nil)
    end
  end

  # No structured output asked for → the caller's own `response_format:`
  # (if any) passes through untouched; a retry after 400/422 drops it.
  defp put_response_format(opts, nil, _retry), do: opts
  defp put_response_format(opts, _requested, nil), do: Keyword.delete(opts, :response_format)

  defp put_response_format(opts, _requested, format),
    do: Keyword.put(opts, :response_format, format)

  defp run_speak(endpoint, text, opts, trace) do
    with {:ok, result} <- PhoenixKitAI.Completion.text_to_speech(endpoint, text, opts) do
      logged = log_tts_request(endpoint, text, result, trace)

      {:ok,
       result
       |> Map.take([:audio, :format, :timestamps])
       |> put_request_uuid(:request_uuid, logged)}
    end
  end

  defp run_compare_images(endpoint, before, after_image, opts, prompt, trace) do
    opts = log_unparsed_answer(opts, endpoint, prompt, [before, after_image], trace)

    with {:ok, result} <- PhoenixKitAI.Images.compare(endpoint, before, after_image, opts) do
      row =
        log_image_op_request(
          endpoint,
          "vision",
          prompt,
          [before, after_image],
          Map.put(result, :text, result.summary),
          %{passed: result.passed},
          trace
        )

      {:ok,
       result
       |> Map.drop([:usage, :latency_ms])
       |> put_request_uuid(:request_uuid, row)
       |> put_cost(row)}
    end
  end

  defp run_embed(endpoint, input, merged_opts, trace) do
    with {:ok, response} <- PhoenixKitAI.Completion.embeddings(endpoint, input, merged_opts) do
      logged = log_embedding_request(endpoint, input, response, trace)

      {:ok,
       response
       |> Map.put("space", embedding_space(response, endpoint))
       |> Map.put("cost", logged_cost(logged))
       |> put_request_uuid("request_uuid", logged)}
    end
  end

  defp embed_image_item?(%{"content" => parts}) when is_list(parts),
    do: Enum.any?(parts, &match?(%{"type" => "image_url"}, &1))

  defp embed_image_item?(_item), do: false

  defp logged_cost({:ok, %Request{cost: cost}}), do: cost
  defp logged_cost(_logged), do: nil

  # Vectors are comparable only within one model and one size: `space`
  # names both, so a host can refuse to compare vectors from two spaces.
  defp embedding_space(response, endpoint) do
    dims =
      case response["data"] do
        [%{"embedding" => vector} | _] when is_list(vector) -> length(vector)
        _ -> nil
      end

    model = response["model"] || endpoint.model
    if dims, do: "#{model}:#{dims}", else: model
  end

  # What `embed/3` takes: a string, or a list of strings and images. An
  # image is `{:image, input}`, `%{image: input}`, or with a caption for a
  # joint vector `{:image, input, text}` / `%{image: input, text: text}` —
  # `input` anything the image verbs take (bytes, `%{data:, content_type:}`,
  # `%{url:}`, a data or https URL). Images are checked like the vision
  # verbs' (bytes become a data URL within the size limits; a URL is passed
  # through after the fetch host policy) and sent as
  # OpenRouter's multimodal `{"content": [image_url part]}` inputs.
  defp prepare_embed_input(input, _opts) when is_binary(input), do: {:ok, input}
  defp prepare_embed_input([], _opts), do: {:error, :empty_input}

  defp prepare_embed_input(list, opts) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case embed_item(item, opts) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, items |> Enum.reverse() |> uniform_embed_items()}
      error -> error
    end
  end

  defp prepare_embed_input(single, opts), do: prepare_embed_input([single], opts)

  # OpenRouter takes a list of strings or a list of multimodal objects, never
  # a mix (HTTP 400 `invalid_union`): once one item is an image, every text
  # goes as a text part too. A text-only list stays plain strings.
  defp uniform_embed_items(items) do
    if Enum.any?(items, &is_map/1),
      do:
        Enum.map(items, fn
          text when is_binary(text) -> %{"content" => [%{"type" => "text", "text" => text}]}
          item -> item
        end),
      else: items
  end

  defp embed_item(text, _opts) when is_binary(text), do: {:ok, text}
  defp embed_item({:image, image}, opts), do: image_embed_item(image, nil, opts)

  defp embed_item({:image, image, text}, opts) when is_binary(text),
    do: image_embed_item(image, text, opts)

  defp embed_item(%{image: image, text: text}, opts) when is_binary(text) or is_nil(text),
    do: image_embed_item(image, text, opts)

  defp embed_item(%{image: _image, text: _not_text}, _opts),
    do: {:error, :invalid_embedding_input}

  defp embed_item(%{image: image}, opts), do: image_embed_item(image, nil, opts)
  defp embed_item(_other, _opts), do: {:error, :invalid_embedding_input}

  defp image_embed_item(image, text, opts) do
    with {:ok, [ref]} <- PhoenixKitAI.Images.normalize_inputs([image], opts) do
      part = %{"type" => "image_url", "image_url" => %{"url" => ref}}

      content =
        if is_binary(text) and text != "",
          do: [%{"type" => "text", "text" => text}, part],
          else: [part]

      {:ok, %{"content" => content}}
    end
  end

  defp run_generate_image(endpoint, prompt, opts, trace) do
    with {:ok, result} <- PhoenixKitAI.Completion.generate_image(endpoint, prompt, opts) do
      logged = log_image_op_request(endpoint, "image", prompt, [], result, %{}, trace)

      {:ok,
       result
       |> Map.put_new(:warnings, [])
       |> Map.take([:images, :model, :warnings])
       |> put_request_uuid(:request_uuid, logged)}
    end
  end

  defp run_edit_image(endpoint, prompt, images, opts, trace) do
    with {:ok, result} <- PhoenixKitAI.Completion.edit_image(endpoint, prompt, images, opts) do
      logged = log_image_op_request(endpoint, "image_edit", prompt, images, result, %{}, trace)

      {:ok,
       result
       |> Map.put_new(:warnings, [])
       |> Map.take([:images, :text, :model, :warnings])
       |> put_request_uuid(:request_uuid, logged)}
    end
  end

  defp run_process_image(endpoint, images, operations, opts, trace) do
    case PhoenixKitAI.Images.process(endpoint, images, operations, opts) do
      {:ok, %{dry_run: true}} = plan ->
        plan

      {:ok, result} ->
        extra = %{
          operations: Enum.map(result.operations, &Atom.to_string/1),
          warnings:
            result.warnings
            |> Enum.map(&PhoenixKitAI.Images.redact_warning/1)
            |> inspect(),
          warning_tags: Enum.map(result.warnings, &elem(&1, 0))
        }

        logged =
          log_image_op_request(
            endpoint,
            "image_edit",
            result.prompt,
            images,
            result,
            extra,
            trace
          )

        {:ok,
         result
         |> Map.take([:images, :text, :prompt, :operations, :warnings, :model])
         |> put_request_uuid(:request_uuid, logged)}

      {:error, _} = error ->
        error
    end
  end

  defp run_describe_image(endpoint, images, opts, prompt, trace) do
    opts = log_unparsed_answer(opts, endpoint, prompt, images, trace)

    with {:ok, result} <- PhoenixKitAI.Images.describe(endpoint, images, opts) do
      extra = if result[:regions], do: %{region_count: length(result.regions)}, else: %{}
      logged = log_image_op_request(endpoint, "vision", prompt, images, result, extra, trace)

      {:ok,
       result
       |> Map.take([:text, :json, :model, :truncated, :regions, :dropped_regions])
       |> put_request_uuid(:request_uuid, logged)
       |> put_cost(logged)}
    end
  end

  # The per-process sum of billed but unusable vision answers (see
  # `take_unparsed_cost/0`).
  @unparsed_cost_key {__MODULE__, :last_unparsed_cost}

  # `fallback_models: [model, ...]` on a vision verb: when a call fails for a
  # reason another model could fix — a safety block, an answer that is not the
  # JSON asked for or was cut off, a provider outage, a model or parameters
  # the provider cannot serve — the same call is made again with the next
  # model (`model:` set to it), through the whole gate, cache and usage row.
  # Never on a refusal (caps, limits, blocks, an unfit model), a bad key or
  # balance, or a caller's input error: another model would get the same.
  # The answer lists the models that failed before it in `:fallbacks`.
  defp with_fallback_models(endpoint_uuid, opts, call) do
    case Keyword.get(opts, :fallback_models) do
      [_ | _] = models ->
        # Every entry a model id: an empty or non-string one would send one
        # model while the guard checks another.
        if Enum.all?(models, &(is_binary(&1) and String.trim(&1) != "")),
          do: try_models(endpoint_uuid, Keyword.delete(opts, :fallback_models), models, call, []),
          else: {:error, :invalid_fallback_models}

      empty when empty in [nil, []] ->
        call.(Keyword.delete(opts, :fallback_models))

      _not_a_list ->
        {:error, :invalid_fallback_models}
    end
  end

  defp try_models(endpoint_uuid, opts, rest, call, failed) do
    before = Process.get(@unparsed_cost_key)

    case call.(opts) do
      {:ok, result} when is_map(result) ->
        {:ok,
         if(failed == [], do: result, else: Map.put(result, :fallbacks, Enum.reverse(failed)))}

      {:error, reason} = error ->
        case {fallback_reason?(reason), rest} do
          {true, [next | more]} ->
            tried = %{
              model: opts[:model] || endpoint_model(endpoint_uuid),
              error: fallback_tag(reason),
              # what the failed attempt was billed (an unparsed or cut-off answer), else nil
              cost: unparsed_cost_since(before)
            }

            try_models(endpoint_uuid, Keyword.put(opts, :model, next), more, call, [
              tried | failed
            ])

          _ ->
            error
        end
    end
  end

  defp endpoint_model(%Endpoint{model: model}), do: model

  defp endpoint_model(uuid) do
    case resolve_endpoint(uuid) do
      {:ok, %Endpoint{model: model}} -> model
      _ -> nil
    end
  end

  @fallback_tags [
    :content_policy,
    :no_json_in_response,
    :output_truncated,
    :no_provider_for_params,
    :connection_error
  ]

  @doc false
  # Whether a vision verb's error is one another model could avoid (see
  # `with_fallback_models/3`). Public for VisionBatch and the tests.
  @spec fallback_reason?(term()) :: boolean()
  def fallback_reason?({tag, _}) when tag in @fallback_tags, do: true

  def fallback_reason?({:api_error, status})
      when is_integer(status) and (status >= 500 or status == 408),
      do: true

  def fallback_reason?(reason)
      when reason in [
             :model_not_found,
             :request_timeout,
             :rate_limited,
             :invalid_response_format,
             :invalid_json_response
           ],
      do: true

  def fallback_reason?(_reason), do: false

  # The kind of error only, never its text (a refusal's text can paraphrase the request).
  defp fallback_tag({tag, _}) when is_atom(tag), do: tag
  defp fallback_tag({tag, _, _}) when is_atom(tag), do: tag
  defp fallback_tag(tag) when is_atom(tag), do: tag
  defp fallback_tag(_reason), do: :error

  @doc false
  # The summed cost of the vision answers in this process that were billed
  # but unusable (not the JSON asked for, or cut off) since the last take,
  # and clears it: see `log_unparsed_answer/5`. `vision_batch/3` reads it
  # per item; an error tuple has no room for the money it ran up.
  @spec take_unparsed_cost() :: Decimal.t() | nil
  def take_unparsed_cost, do: Process.delete(@unparsed_cost_key)

  # What was added to that sum since `before` (a value read earlier), or nil.
  defp unparsed_cost_since(before) do
    case Process.get(@unparsed_cost_key) do
      nil -> nil
      now when is_nil(before) -> now
      now -> if Decimal.gt?(now, before), do: Decimal.sub(now, before)
    end
  end

  # The cost the call's usage row carries (nil when the call has none, as
  # for a provider reporting no usage and no price for the model).
  defp put_cost(result, {:ok, %Request{cost: cost}}) when is_map(result),
    do: Map.put(result, :cost, cost)

  defp put_cost(result, _logged) when is_map(result), do: Map.put(result, :cost, nil)

  # A JSON request answered in prose still cost a provider call. The vision
  # layer hands that answer to `:on_no_json` before returning the error, so
  # its usage row is written (the spend caps sum those rows) and the verb's
  # error branch does not log the same call again as a zero-cost failure.
  # A nil `prompt` takes the one the vision layer actually sent.
  defp log_unparsed_answer(opts, endpoint, prompt, images, trace) do
    Keyword.put(opts, :on_no_json, fn raw ->
      # `unparsed: true` keeps the billed-but-unusable answer apart from a
      # good one in reports (`run_costs/2` counts them).
      logged =
        log_image_op_request(
          endpoint,
          "vision",
          prompt || raw[:prompt],
          images,
          raw,
          if(raw[:truncated], do: %{unparsed: true, truncated: true}, else: %{unparsed: true}),
          trace
        )

      # The error the verb returns (`{:no_json_in_response, text}`) has no
      # room for the cost it ran up; `vision_batch/3`, which calls the verb in
      # this same process, reads it to keep its budget honest.
      with {:ok, %Request{cost: %Decimal{} = cost}} <- logged,
           do: Process.put(@unparsed_cost_key, add_costs(Process.get(@unparsed_cost_key), cost))

      logged
    end)
  end

  defp run_extract_text(endpoint, images, opts, _prompt, trace) do
    opts = log_unparsed_answer(opts, endpoint, nil, images, trace)

    with {:ok, result} <- PhoenixKitAI.Images.extract_text(endpoint, images, opts) do
      # Model-derived values are normalised before they reach the row: a
      # language tag is a tag or nothing, never free text.
      logged =
        log_image_op_request(
          endpoint,
          "vision",
          result.prompt,
          images,
          result,
          %{
            language: language_tag(result.language),
            confidence: if(is_number(result.confidence), do: result.confidence),
            has_illegible_text: result.has_illegible_text == true
          },
          trace
        )

      {:ok,
       result
       |> Map.drop([:usage, :latency_ms, :prompt])
       |> put_request_uuid(:request_uuid, logged)
       |> put_cost(logged)}
    end
  end

  defp language_tag(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}\z/, value), do: value
  end

  defp language_tag(_), do: nil

  @cached_row_type %{
    complete: "chat",
    embed: "embedding",
    speak: "tts",
    generate_image: "image",
    edit_image: "image_edit",
    process_image: "image_edit",
    describe_image: "vision",
    extract_text: "vision",
    compare_images: "vision"
  }

  # The cache wrapper every verb shares: the key over `material` (built
  # only when caching is on — image bytes are not free to hash) or the
  # caller's own `cache: [key: …]` plus the JSON shape asked for (`schema:`,
  # `json:`, `extract_text/3`'s `fields:`), the
  # fetch, and the zero-cost row a hit writes. Logging stays in the run_*
  # functions and the verbs' error branches.
  defp with_cache(verb, endpoint, opts, material, row, fun) do
    model = sent_model(endpoint, opts, verb)

    key = fn ->
      material =
        case RequestCache.caller_key(opts) do
          nil ->
            material.()

          caller_key ->
            caller_material(caller_key, opts)
        end

      RequestCache.key(verb, endpoint, model, material)
    end

    RequestCache.fetch(key, opts, fun, %{
      verb: verb,
      endpoint_uuid: endpoint.uuid,
      on_hit: cached_row(endpoint, verb, model, row, log_cache_hit?(opts))
    })
  end

  # A thinking budget not below `max_tokens` is not sent (`Completion`);
  # the row says why the call ran without thinking.
  defp note_skipped_thinking(guard, endpoint, opts) do
    if PhoenixKitAI.Completion.thinking_budget_skipped?(endpoint, opts),
      do:
        Map.update(
          guard,
          :guard_warnings,
          ["thinking_budget_not_below_max_tokens"],
          &(&1 ++ ["thinking_budget_not_below_max_tokens"])
        ),
      else: guard
  end

  # Where a verb's result carries the uuid of its usage row: the chat and
  # embedding responses are provider maps with string keys, the rest are
  # this module's atom-keyed maps.
  defp request_uuid_key(verb) when verb in [:complete, :embed], do: "request_uuid"
  defp request_uuid_key(_verb), do: :request_uuid

  defp put_request_uuid(result, key, {:ok, %Request{uuid: uuid}}) when is_map(result),
    do: Map.put(result, key, uuid)

  defp put_request_uuid(result, _key, _logged), do: result

  # `log_cache_hit: false` on the call, or `config :phoenix_kit_ai, log_cache_hits: false`,
  # skips the zero-cost row of a hit — for hot paths (search queries) where a write per
  # hit costs more than the report is worth. The telemetry hit event still fires.
  # Unlogged hits are not counted anywhere a row is counted (`ai_daily_calls_per_user`,
  # a task's request limit).
  defp log_cache_hit?(opts) do
    case Keyword.get(opts, :log_cache_hit) do
      nil -> Application.get_env(:phoenix_kit_ai, :log_cache_hits, true) != false
      value -> value != false
    end
  end

  # A cache hit is still a logical request the host made: a zero-cost row
  # marked cached, with the same attribution, prompt link and task as a
  # fresh one, keeps reports truthful without pretending a provider was
  # called. The answer handed back names this row, not the one the cached
  # answer was first logged under — and names no row (`nil`) when this one
  # could not be written, since the stored uuid is another call's, perhaps
  # another user's.
  #
  # With `log_cache_hit?/1` false no row is written, and the answer names no
  # row either.
  defp cached_row(_endpoint, verb, _model, _row, false) do
    fn value ->
      {:replace, hit_value(value, verb, nil)}
    end
  end

  defp cached_row(endpoint, verb, model, row, true) do
    prompt_info = row[:prompt_info] || %{}

    fn value ->
      metadata =
        %{cached: true, source: row.source, caller_context: row.caller_context}
        |> maybe_put_attribution(prompt_info[:attribution] || row[:attribution])
        |> maybe_put_prompt_snapshot(prompt_info[:prompt_snapshot])
        |> maybe_put_unbound_placeholders(prompt_info[:unbound_placeholders])
        |> Map.merge(row[:guard] || %{})

      logged =
        safe_log_usage(%{
          endpoint_uuid: endpoint.uuid,
          endpoint_name: endpoint.name,
          prompt_uuid: prompt_info[:prompt_uuid],
          prompt_name: prompt_info[:prompt_name],
          model: model,
          request_type: @cached_row_type[verb],
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          cost: Decimal.new(0),
          latency_ms: 0,
          status: "success",
          user_uuid: row.caller_context[:user_uuid],
          metadata: metadata
        })

      uuid =
        case logged do
          {:ok, %Request{uuid: uuid}} -> uuid
          _ -> nil
        end

      {:replace, hit_value(value, verb, uuid)}
    end
  end

  # What a hit hands back: the stored answer naming this hit's row, and —
  # for a result that carries one — this hit's cost, which is zero, not the
  # first call's.
  defp hit_value(value, verb, uuid) when is_map(value) do
    value = Map.put(value, request_uuid_key(verb), uuid)
    if Map.has_key?(value, :cost), do: Map.put(value, :cost, Decimal.new(0)), else: value
  end

  defp hit_value(value, _verb, _uuid), do: value

  # A hit's row must never fail the hit: a database error is logged and
  # read as "no row".
  defp safe_log_usage(attrs) do
    log_usage(attrs)
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] cache hit usage row not written: #{inspect(error.__struct__)}"
      )

      {:error, :not_written}
  end

  @doc """
  Counts the total number of requests.
  """
  @spec count_requests() :: non_neg_integer()
  def count_requests do
    repo().aggregate(Request, :count)
  end

  @doc """
  Sums the total tokens used across all requests.
  """
  @spec sum_tokens() :: non_neg_integer()
  def sum_tokens do
    repo().aggregate(Request, :sum, :total_tokens) || 0
  end

  defp apply_request_filters(query, opts) do
    query
    |> maybe_filter_by(:endpoint_uuid, Keyword.get(opts, :endpoint_uuid))
    |> maybe_filter_by(:user_uuid, Keyword.get(opts, :user_uuid))
    |> maybe_filter_by(:status, Keyword.get(opts, :status))
    |> maybe_filter_by(:model, Keyword.get(opts, :model))
    |> maybe_filter_by(:source, Keyword.get(opts, :source))
    |> maybe_filter_by(:source_prefix, Keyword.get(opts, :source_prefix))
    |> maybe_filter_by(:run, Guard.run_tag(Keyword.get(opts, :run)))
    |> maybe_filter_by(:step, Guard.run_tag(Keyword.get(opts, :step)))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_until(Keyword.get(opts, :until))
  end

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [r], r.inserted_at < ^until)

  defp maybe_filter_by(query, _field, nil), do: query

  defp maybe_filter_by(query, :endpoint_uuid, uuid) when is_binary(uuid) do
    where(query, [r], r.endpoint_uuid == ^uuid)
  end

  defp maybe_filter_by(query, :user_uuid, uuid) when is_binary(uuid) do
    where(query, [r], r.user_uuid == ^uuid)
  end

  # `"refused"` is not a stored status: the rows the guard refused (status
  # `"error"`, `metadata.refused`).
  defp maybe_filter_by(query, :status, "refused"),
    do: where(query, [r], fragment("(?->>'refused') = 'true'", r.metadata))

  defp maybe_filter_by(query, :status, status), do: where(query, [r], r.status == ^status)
  defp maybe_filter_by(query, :model, model), do: where(query, [r], r.model == ^model)

  defp maybe_filter_by(query, :source, source),
    do: where(query, [r], fragment("?->>'source' = ?", r.metadata, ^source))

  # The rows of one `run:` (and one `step:` of it), as tagged by the call.
  defp maybe_filter_by(query, :run, run) when is_binary(run),
    do: where(query, [r], fragment("?->>'run' = ?", r.metadata, ^run))

  defp maybe_filter_by(query, :step, step) when is_binary(step),
    do: where(query, [r], fragment("?->>'step' = ?", r.metadata, ^step))

  # Every source starting with the prefix ("MyApp." counts all of an app's
  # callers); LIKE metacharacters in the prefix are matched literally.
  defp maybe_filter_by(query, :source_prefix, ""), do: query

  defp maybe_filter_by(query, :source_prefix, prefix) when is_binary(prefix) do
    pattern = escape_like(prefix) <> "%"
    where(query, [r], fragment("?->>'source' LIKE ?", r.metadata, ^pattern))
  end

  # `images_as` changes the prompt, so it is part of the key — but only when
  # given, so existing cache entries keep their keys.
  defp caller_material(caller_key, opts) do
    base = {:caller_key, caller_key, opts[:schema], opts[:json] == true, opts[:fields]}
    base = if opts[:images_as], do: {base, opts[:images_as]}, else: base

    # Options that change the answer's shape: a cached answer without regions
    # or boxes must not serve a call that asks for them. Added only when set,
    # so existing caller keys keep their entries.
    case Keyword.take(opts, [:regions, :boxes, :box_format])
         |> Enum.reject(fn {_, v} -> v in [nil, false] end) do
      [] -> base
      shape -> {base, Enum.sort(shape)}
    end
  end

  defp escape_like(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, date), do: where(query, [r], r.inserted_at >= ^date)

  @doc """
  Returns filter options for requests (distinct endpoints, models, and sources).
  """
  @spec get_request_filter_options() :: map()
  def get_request_filter_options do
    endpoints_query =
      from(r in Request,
        where: not is_nil(r.endpoint_uuid) and not is_nil(r.endpoint_name),
        distinct: true,
        select: {r.endpoint_uuid, r.endpoint_name},
        order_by: r.endpoint_name
      )

    models_query =
      from(r in Request,
        where: not is_nil(r.model),
        distinct: r.model,
        select: r.model,
        order_by: r.model
      )

    # Query unique sources from metadata JSONB field
    sources_query =
      from(r in Request,
        where: not is_nil(fragment("?->>'source'", r.metadata)),
        distinct: fragment("?->>'source'", r.metadata),
        select: fragment("?->>'source'", r.metadata),
        order_by: fragment("?->>'source'", r.metadata)
      )

    %{
      endpoints: repo().all(endpoints_query),
      models: repo().all(models_query),
      statuses: Request.valid_statuses() ++ ["refused"],
      sources: repo().all(sources_query)
    }
  end

  # ===========================================
  # STATISTICS
  # ===========================================

  @doc """
  Gets aggregated usage statistics.

  This is the read side of attribution and the spend caps: what an
  endpoint, a user or a source spent since a point in time.

  ## Options
  - `:since` / `:until` - rows with `inserted_at` in `[since, until)`
  - `:endpoint_uuid`, `:user_uuid`, `:status`, `:model`, `:source`, `:source_prefix` - filters

  ## Returns
  Map with statistics including total_requests, total_tokens, success_rate, etc.
  """
  @spec get_usage_stats(keyword()) :: map()
  def get_usage_stats(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    total_requests = repo().aggregate(base_query, :count)
    total_tokens = repo().aggregate(base_query, :sum, :total_tokens) || 0
    # dollars, a Decimal (the sum of a numeric column)
    total_cost = repo().one(from(r in base_query, select: coalesce(sum(r.cost), 0)))

    avg_latency = repo().aggregate(base_query, :avg, :latency_ms)

    success_query = where(base_query, [r], r.status == "success")
    success_count = repo().aggregate(success_query, :count)

    success_rate =
      if total_requests > 0 do
        Float.round(success_count / total_requests * 100, 1)
      else
        0.0
      end

    %{
      total_requests: total_requests,
      total_tokens: total_tokens,
      total_cost: total_cost,
      success_count: success_count,
      error_count: total_requests - success_count,
      success_rate: success_rate,
      avg_latency_ms: decimal_to_int(avg_latency)
    }
  end

  # Convert Decimal or number to integer, handling nil
  defp decimal_to_int(nil), do: nil
  defp decimal_to_int(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp decimal_to_int(n) when is_float(n), do: round(n)
  defp decimal_to_int(n) when is_integer(n), do: n

  @doc """
  Gets dashboard statistics for display.

  Returns stats for the last 30 days plus all-time totals.
  """
  @spec get_dashboard_stats() :: map()
  def get_dashboard_stats do
    thirty_days_ago = UtilsDate.utc_now() |> DateTime.add(-30, :day)
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    all_time = get_usage_stats()
    last_30_days = get_usage_stats(since: thirty_days_ago)
    today = get_usage_stats(since: today_start)

    tokens_by_model = get_tokens_by_model(since: thirty_days_ago)
    requests_by_day = get_requests_by_day(since: thirty_days_ago)

    %{
      all_time: all_time,
      last_30_days: last_30_days,
      today: today,
      tokens_by_model: tokens_by_model,
      requests_by_day: requests_by_day
    }
  end

  @doc """
  Gets token usage grouped by model.
  """
  @spec get_tokens_by_model(keyword()) :: [map()]
  def get_tokens_by_model(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    query =
      from(r in subquery(base_query),
        where: not is_nil(r.model) and r.model != "",
        group_by: r.model,
        select: %{
          model: r.model,
          total_tokens: sum(r.total_tokens),
          request_count: count()
        },
        order_by: [desc: sum(r.total_tokens)]
      )

    repo().all(query)
  end

  @doc """
  Gets request counts grouped by day.
  """
  @spec get_requests_by_day(keyword()) :: [map()]
  def get_requests_by_day(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    query =
      from(r in subquery(base_query),
        group_by: fragment("DATE(?)", r.inserted_at),
        select: %{
          date: fragment("DATE(?)", r.inserted_at),
          count: count(),
          tokens: sum(r.total_tokens)
        },
        order_by: [asc: fragment("DATE(?)", r.inserted_at)]
      )

    repo().all(query)
  end

  # ===========================================
  # COMPLETION API
  # ===========================================

  alias PhoenixKitAI.Completion

  @doc """
  Makes a chat completion request using a configured endpoint.

  ## Parameters

  - `endpoint_uuid` - Endpoint UUID string or Endpoint struct
  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Optional parameter overrides

  ## Options

  All standard completion parameters plus:
  - `:source` - Override auto-detected source for request tracking
  - `:capture_request_content` - `false` keeps this call's content out of its
    usage row. It only narrows: `true` does not override a global
    `config :phoenix_kit_ai, capture_request_content: false`.
  - `:model` - send this model instead of the endpoint's. It is the model the
    guard checks, the cache keys and the usage row names and prices.
  - `:models` - OpenRouter only: fallback models tried in order when the
    first is down, rate-limited or refuses (OpenRouter's model routing); the
    model that answered is recorded as the row's `answered_model`. Each is
    checked by the guard like `:model`; one that does not fit refuses the call.

  ## Delivery options

  How the call is made, never part of the request cache key (also on
  `embed/3` and `speak/3`):

  - `:timeout` - receive/connect timeout in ms (default the app env
    `:timeout`, else 120 000).
  - `:retry` - `true` or `[max_attempts:, base_delay:, max_delay:,
    retry_timeouts:]` retries HTTP 408, 429 (not one about money: an
    exhausted balance or quota), 500, 502, 503, 504 and transport errors with
    exponential backoff, honouring `Retry-After` up to `max_delay`. Off unless asked for (or
    set in the app env `:retry`).
  - `:concurrency` - `[limit:, key:, wait:, max_waiting:, notify:]` or
    `false`; see `PhoenixKitAI.Limiter`.
  - `:log_cache_hit` - `false` writes no usage row for a cache hit.

  ## Examples

      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, [
        %{role: "user", content: "Hello!"}
      ])

      # With system message
      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "What is 2+2?"}
      ])

      # With parameter overrides
      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, messages,
        temperature: 0.5,
        max_tokens: 500
      )

      # With custom source for tracking
      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, messages,
        source: "MyModule"
      )

  ## Returns

  - `{:ok, response}` - Full API response including usage stats
  - `{:error, reason}` - Error atom or tagged tuple. See
    `PhoenixKitAI.Errors` for the vocabulary and translation.

  ## Tool calling

  `tools:` (OpenAI function-tools), `tool_choice:` and `parallel_tool_calls:`
  go into the request when given. Messages keep `tool_calls` (on `assistant`;
  `content` may be `nil`) and `tool_call_id` / `name` (on `tool`). Read the
  model's calls with `extract_tool_calls/1`. A call with `tools:` is never
  cached, whatever `cache:` says.

  ## Structured output

  `schema: %{"type" => "object", …}` requests the answer as that JSON
  object (the provider's `response_format` where supported, the schema in
  the prompt everywhere) and returns it parsed under `response["json"]`;
  `json: true` accepts any JSON object. See `PhoenixKitAI.StructuredOutput`.
  """
  @spec complete(String.t() | Endpoint.t(), list(map()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(endpoint_uuid, messages, opts \\ []) do
    opts = call_model_opts(opts)

    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         opts = fallbacks_for(endpoint, opts),
         {:ok, admission} <-
           authorize(endpoint, opts, :complete, Guard.implied_needs(:complete, opts, messages)) do
      # A call's `model:` is the model sent, checked, cached and logged.
      endpoint = with_call_model(endpoint, opts)
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])

      # A hard requirement on OpenRouter: only providers that take every
      # parameter, and the ones the model does not list left out.
      {merged_opts, stripped} =
        endpoint |> merge_endpoint_opts(opts) |> Guard.require_parameters(admission)

      guard =
        admission
        |> Guard.row_metadata(stripped)
        |> note_skipped_thinking(endpoint, merged_opts)

      # Extract prompt info if present (from ask_with_prompt, complete_with_system_prompt)
      # + the ATTRIBUTION payload (the projects work-ledger seam): an
      # opaque caller map recorded into request metadata — this package
      # never interprets it; usage sinks (handle_ai_usage/1) do.
      prompt_info = %{
        prompt_uuid: Keyword.get(opts, :prompt_uuid),
        prompt_name: Keyword.get(opts, :prompt_name),
        prompt_snapshot: Keyword.get(opts, :prompt_snapshot),
        attribution: normalize_attribution(Keyword.get(opts, :attribution)),
        unbound_placeholders: Keyword.get(opts, :unbound_placeholders, []),
        capture: Keyword.get(opts, :capture_request_content),
        guard: guard
      }

      {suffix, format} = StructuredOutput.request(opts)
      messages = StructuredOutput.attach(messages, suffix)

      result =
        with_cache(
          :complete,
          endpoint,
          cache_opts_for(opts),
          fn -> {messages, cacheable(merged_opts), format} end,
          %{
            source: source,
            caller_context: caller_context,
            prompt_info: prompt_info,
            guard: guard
          },
          fn ->
            run_complete(
              endpoint,
              messages,
              merged_opts,
              format,
              {source, stacktrace, caller_context, prompt_info}
            )
          end
        )

      case result do
        {:ok, response} ->
          {:ok, response}

        # The provider answered and its row is written; only the parse failed
        # (or the answer stopped at the output limit).
        {:error, {tag, _}} = error when tag in [:no_json_in_response, :output_truncated] ->
          error

        {:error, reason} ->
          log_failed_request(
            endpoint,
            messages,
            reason,
            source,
            stacktrace,
            caller_context,
            prompt_info
          )

          {:error, reason}
      end
    end
  end

  # A call with `tools:` is one round of a tool-calling turn: its answer
  # depends on tool results that are not in the key's material, and a
  # replayed `tool_calls` answer would skip running the tools. Never cached,
  # whatever `cache:` or the global default says.
  defp cache_opts_for(opts) do
    case Keyword.get(opts, :tools) do
      [_ | _] -> Keyword.put(opts, :cache, false)
      _ -> opts
    end
  end

  # The request-shaping options only: what the caller is tracked by
  # (source, attribution, idempotency, user, cache mode, content capture,
  # task) must not change the cache key.
  defp cacheable(opts) do
    opts
    |> Keyword.drop([
      :capture_request_content,
      :source,
      :attribution,
      :idempotency_key,
      :user_uuid,
      :cache,
      :prompt_uuid,
      :prompt_name,
      :prompt_snapshot,
      :unbound_placeholders,
      :verify,
      :task,
      :guard_admission,
      # bookkeeping tags: which run asked, not what is asked
      :run,
      :step,
      :fallback_models,
      # delivery options: how the call is made, not what is asked
      :retry,
      :timeout,
      :concurrency,
      :log_cache_hit
    ])
    |> Enum.sort()
  end

  # A JSON answer, when one was asked for, parsed onto the response as
  # "json"; unparsable text is an error even though the provider call
  # succeeded (the usage row is already written).
  defp attach_json(response, false), do: {:ok, response}

  # A round that ended in tool calls has no answer to parse yet: the caller
  # runs the tools and asks again. Without this the model's calls would be
  # reported as `:no_json_in_response` and lost with the error.
  defp attach_json(response, true) do
    case Completion.extract_tool_calls(response) do
      [] -> parse_json_answer(response)
      _calls -> {:ok, response}
    end
  end

  defp parse_json_answer(response) do
    text =
      case Completion.extract_content(response) do
        {:ok, text} when is_binary(text) -> text
        _ -> nil
      end

    # An answer that stopped at the output limit is no answer, even when the
    # part that came back parses.
    if Completion.truncated?(response) do
      {:error, {:output_truncated, text}}
    else
      with {:ok, json} <- StructuredOutput.parse(text, true) do
        {:ok, Map.put(response, "json", json)}
      end
    end
  end

  @doc """
  Simple helper for single-turn chat completion.

  ## Parameters

  - `endpoint_uuid` - Endpoint UUID string or Endpoint struct
  - `prompt` - User prompt string
  - `opts` - Optional parameter overrides and system message

  ## Options

  All options from `complete/3` plus:
  - `:system` - System message string
  - `:schema` / `:json` - Ask for a machine-readable answer, see `complete/3`
  - `:source` - Override auto-detected source for request tracking

  ## Examples

      # Simple question
      {:ok, response} = PhoenixKitAI.ask(endpoint_uuid, "What is the capital of France?")

      # With system message
      {:ok, response} = PhoenixKitAI.ask(endpoint_uuid, "Translate: Hello",
        system: "You are a translator. Translate to French."
      )

      # With custom source for tracking
      {:ok, response} = PhoenixKitAI.ask(endpoint_uuid, "Hello!",
        source: "Languages"
      )

      # Extract just the text content
      {:ok, response} = PhoenixKitAI.ask(endpoint_uuid, "Hello!")
      {:ok, text} = PhoenixKitAI.extract_content(response)

  ## Returns

  Same as `complete/3`
  """
  @spec ask(String.t() | Endpoint.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ask(endpoint_uuid, prompt, opts \\ []) when is_binary(prompt) do
    {system, opts} = Keyword.pop(opts, :system)

    messages =
      case system do
        nil -> [%{role: "user", content: prompt}]
        sys -> [%{role: "system", content: sys}, %{role: "user", content: prompt}]
      end

    complete(endpoint_uuid, messages, opts)
  end

  @typedoc """
  One input of `embed/3`: a text, or an image — `{:image, input}` /
  `%{image: input}` — optionally with a caption embedded with it
  (`{:image, input, text}` / `%{image: input, text: text}`). `input` is any
  `t:PhoenixKitAI.Images.input/0`.
  """
  @type embed_input ::
          String.t()
          | {:image, PhoenixKitAI.Images.input()}
          | {:image, PhoenixKitAI.Images.input(), String.t()}
          | %{required(:image) => PhoenixKitAI.Images.input(), optional(:text) => String.t()}

  @doc """
  Makes an embeddings request using a configured endpoint.

  ## Parameters

  - `endpoint_uuid` - Endpoint UUID string or Endpoint struct
  - `input` - Text, or a list of texts and images (see `t:embed_input/0`).
    Images need a multimodal embedding model on the endpoint (on
    OpenRouter e.g. `google/gemini-embedding-2`,
    `voyageai/voyage-multimodal-3.5`); they are checked like the image
    verbs' inputs (bytes are sent as a data URL, an http(s) URL is passed
    through after the host check), and a text model answers them with an error
  - `opts` - Optional parameter overrides

  ## Options

  - `:dimensions` - Override embedding dimensions
  - `:source` - Override auto-detected source for request tracking

  ## Examples

      # Single text
      {:ok, response} = PhoenixKitAI.embed(endpoint_uuid, "Hello, world!")

      # Multiple texts
      {:ok, response} = PhoenixKitAI.embed(endpoint_uuid, ["Hello", "World"])

      # With dimension override
      {:ok, response} = PhoenixKitAI.embed(endpoint_uuid, "Hello", dimensions: 512)

      # With custom source for tracking
      {:ok, response} = PhoenixKitAI.embed(endpoint_uuid, "Hello",
        source: "SemanticSearch"
      )

      # Images, and an image with its caption, in one call
      {:ok, %{"data" => [photo, captioned], "space" => space}} =
        PhoenixKitAI.embed(endpoint_uuid, [{:image, jpeg}, {:image, png, "red leather sofa"}])

  ## Returns

  - `{:ok, response}` - Response with embeddings, in the order given, plus
    `"space"` — `"<model>:<dimensions>"`: vectors are comparable only
    within one space, so store it next to them — and `"cost"`, the
    logged cost in dollars (a `Decimal`; nil when no price is known or
    under `request_log_mode: :async`, where the row is not written yet)
  - `{:error, reason}` - Error atom or tagged tuple.
  """
  @spec embed(String.t() | Endpoint.t(), embed_input() | [embed_input()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def embed(endpoint_uuid, input, opts \\ []) do
    # `models:` is an OpenRouter chat option; an embedding never sends it
    opts = opts |> call_model_opts() |> Keyword.delete(:models)

    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <- authorize(endpoint, opts, :embed, []),
         {:ok, input} <- prepare_embed_input(input, opts) do
      # A call's `model:` is the model sent, checked, cached and logged.
      endpoint = with_call_model(endpoint, opts)
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])

      merged_opts = merge_embedding_opts(endpoint, opts)
      guard = Guard.row_metadata(admission)

      result =
        with_cache(
          :embed,
          endpoint,
          opts,
          fn -> {input, cacheable(merged_opts)} end,
          %{source: source, caller_context: caller_context, guard: guard},
          fn ->
            run_embed(endpoint, input, merged_opts, {source, stacktrace, caller_context, guard})
          end
        )

      case result do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          log_failed_embedding_request(
            endpoint,
            reason,
            {source, stacktrace, caller_context, guard}
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Synthesizes speech from text through a configured AI endpoint.

  Returns the raw audio bytes alongside the format so the caller knows
  the file extension / MIME type without re-deriving it. Mirrors the
  `embed/3` path: endpoint resolution, credential validation, error
  mapping, and request logging are all shared.

  ## Options

  - `:voice` - Preset voice identifier (e.g. `"casual_male"`)
  - `:voice_id` - Saved/cloned voice id (Mistral hosted)
  - `:instructions` - Steering text for models that support it (e.g.
    `gpt-4o-mini-tts`'s accent/tone/pacing/language control). Only sent
    to models known to support it; silently dropped otherwise so a
    provider that hard-rejects an unrecognized field (Mistral) never
    sees it
  - `:with_timestamps` - **xAI only**, ignored elsewhere (no other
    provider offers anything equivalent). When `true`, the result
    includes character-level timing data — see `Returns` below. No
    price difference; adds latency for xAI's post-synthesis alignment
    pass.
  - `:response_format` - Audio format (default `"mp3"`)
  - `:source` - Request-tracking label (defaults to auto-detected caller)

  Only the voice option that is present is sent to the provider.

  ## Examples

      {:ok, %{audio: bytes, format: "mp3"}} =
        PhoenixKitAI.speak(endpoint_uuid, "Bonjour, comment ça va ?",
          voice: "casual_male",
          source: "SentenceAudio"
        )

  ## Returns

  - `{:ok, %{audio: binary(), format: String.t(), timestamps: [%{char:
    String.t(), start: float(), end: float()}] | nil}}` - `timestamps`
    is `nil` unless `:with_timestamps` was passed to an xAI endpoint and
    the response actually included them. Word boundaries aren't given
    directly — split on whitespace to derive them.
  - `{:error, reason}` - Error atom or tagged tuple.
  """
  @spec speak(String.t() | Endpoint.t(), String.t(), keyword()) ::
          {:ok,
           %{
             audio: binary(),
             format: String.t(),
             timestamps: [%{char: String.t(), start: float(), end: float()}] | nil
           }}
          | {:error, term()}
  def speak(endpoint_uuid, text, opts \\ []) when is_binary(text) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <- authorize(endpoint, opts, :speak, []) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])

      # Fall back to the endpoint's default voice (stored in
      # provider_settings by the endpoint form) when the caller didn't
      # pass one. TTS has no temperature/dimensions analog, so this is
      # the only endpoint-default merge.
      opts = maybe_put_default_voice(endpoint, opts)
      guard = Guard.row_metadata(admission)
      trace = {source, stacktrace, caller_context, guard}

      result =
        with_cache(
          :speak,
          endpoint,
          opts,
          fn -> {text, cacheable(opts)} end,
          %{source: source, caller_context: caller_context, guard: guard},
          fn -> run_speak(endpoint, text, opts, trace) end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_tts_request(endpoint, text, reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Generates image(s) from a text prompt via `Completion.generate_image/3`.

  Falls back to the endpoint's stored defaults when the caller omits
  them — same pattern `speak/3` uses for its stored default voice:

  - OpenAI / OpenRouter: `image_size` / `image_quality` columns → `:size` / `:quality`
  - xAI: `provider_settings["aspect_ratio"]` / `["resolution"]` →
    `:aspect_ratio` / `:resolution` (xAI does not accept OpenAI's size/quality fields)

  ## Options

  See `Completion.generate_image/3` for the full option list
  (`:n`, `:response_format`, `:size`, `:quality`, `:style`, `:background`,
  `:output_format`, `:aspect_ratio`, `:resolution`).

  ## Returns

  - `{:ok, %{images: [%{url: String.t() | nil, data: binary() | nil}]}}`
  - `{:error, reason}` - Error atom or tagged tuple.
  """
  @spec generate_image(String.t() | Endpoint.t(), String.t(), keyword()) ::
          {:ok, %{images: [%{url: String.t() | nil, data: binary() | nil}]}} | {:error, term()}
  def generate_image(endpoint_uuid, prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(endpoint, opts, :generate_image, Guard.implied_needs(:generate_image, opts)) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])

      trace = trace(source, stacktrace, caller_context, opts, Guard.row_metadata(admission))

      result =
        with_cache(
          :generate_image,
          endpoint,
          opts,
          fn -> {prompt, cacheable(opts)} end,
          image_row(trace),
          fn ->
            run_generate_image(endpoint, prompt, opts, trace)
          end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_image_op_request(endpoint, "image", prompt, [], reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Edits or restyles images via `Completion.edit_image/4` and logs the call
  as an `"image_edit"` request: tokens and cost when the provider reports
  them, latency, and input/output image counts and byte sizes. The image
  bytes themselves are never persisted in the log.

  See `Completion.edit_image/4` for the accepted input shapes and the
  options; the transport is the endpoint's `PhoenixKitAI.Provider`
  adapter. Options are sent as given — `process_image/4` is the verb that
  fits them to the model.

      {:ok, %{images: [%{data: png, content_type: "image/png"}]}} =
        PhoenixKitAI.edit_image(endpoint.uuid,
          "Restyle the first photo in the style of the second.",
          [%{data: room_jpeg, content_type: "image/jpeg"},
           %{data: reference_jpeg, content_type: "image/jpeg"}])
  """
  @spec edit_image(String.t() | Endpoint.t(), String.t(), [map() | String.t()], keyword()) ::
          {:ok,
           %{images: [map()], text: String.t() | nil, model: String.t() | nil, warnings: [term()]}}
          | {:error, term()}
  def edit_image(endpoint_uuid, prompt, images, opts \\ [])
      when is_binary(prompt) and is_list(images) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(endpoint, opts, :edit_image, Guard.implied_needs(:edit_image, opts)) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])

      trace = trace(source, stacktrace, caller_context, opts, Guard.row_metadata(admission))

      result =
        with_cache(
          :edit_image,
          endpoint,
          opts,
          fn -> {prompt, images, cacheable(opts)} end,
          image_row(trace),
          fn ->
            run_edit_image(endpoint, prompt, images, opts, trace)
          end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_unless_input_error(endpoint, "image_edit", prompt, images, reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Edits `images` with named operations — the generic, provider-neutral
  entry point for image processing. See `PhoenixKitAI.Images` for the
  operations, options and the fitting of options to the model.

      {:ok, %{images: [%{data: png}], warnings: []}} =
        PhoenixKitAI.process_image(endpoint_uuid, [photo],
          [:remove_reflections, {:clean_background, color: "white"}])

  Logged as an `"image_edit"` request with the operations, the model
  used and any option warnings in the metadata. With `verify:` the result
  is checked against the original by `compare_images/4` and the verdict
  comes back under `:verification` without changing the outcome — give it
  a vision-capable endpoint uuid (`verify: text_endpoint_uuid`); `true`
  uses the same endpoint, which works only when its model also answers
  in text (an image-only model returns a `:verification` error instead).
  """
  @spec process_image(
          String.t() | Endpoint.t(),
          [PhoenixKitAI.Images.input()],
          [term()],
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def process_image(endpoint_uuid, images, operations, opts \\ []) when is_list(images) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(
             endpoint,
             opts,
             :process_image,
             Guard.implied_needs(:process_image, opts),
             !Keyword.get(opts, :dry_run, false)
           ) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])
      {verify, opts} = Keyword.pop(opts, :verify, false)

      trace = trace(source, stacktrace, caller_context, opts, Guard.row_metadata(admission))

      # A dry run touches no provider, so it neither reads nor fills the cache.
      run = fn -> run_process_image(endpoint, images, operations, opts, trace) end
      material = fn -> {images, operations, cacheable(opts)} end
      row = image_row(trace)

      result =
        if opts[:dry_run],
          do: run.(),
          else: with_cache(:process_image, endpoint, opts, material, row, run)

      case result do
        {:ok, %{dry_run: true} = plan} ->
          {:ok, Map.take(plan, [:prompt, :operations, :warnings, :model, :options, :dry_run])}

        {:ok, result} ->
          {:ok, maybe_verify(result, endpoint, verify, images, opts)}

        {:error, reason} ->
          log_failed_unless_input_error(
            endpoint,
            "image_edit",
            inspect(operations),
            images,
            reason,
            trace
          )

          {:error, reason}
      end
    end
  end

  # A caller mistake (bad input, unknown operation) never reached a
  # provider, so it is not a request worth a usage row.
  defp input_error?(:empty_input), do: true
  defp input_error?(:invalid_image_input), do: true
  defp input_error?(:reference_image_required), do: true
  defp input_error?({:unknown_operation, _}), do: true
  defp input_error?({:missing_parameter, _, _}), do: true
  defp input_error?({:unsupported_option, _, _}), do: true
  defp input_error?({:too_many_images, _, _}), do: true
  defp input_error?({:image_too_large, _, _}), do: true
  defp input_error?({:unsafe_url, _}), do: true
  defp input_error?({:conflicting_operations, _, _}), do: true
  defp input_error?({:model_not_listed, _}), do: true
  defp input_error?({:capabilities_unavailable, _}), do: true
  defp input_error?(_reason), do: false

  # A prose answer to a JSON request is already logged, with its usage, by
  # `log_unparsed_answer/5`.
  defp log_failed_unless_input_error(
         _endpoint,
         _type,
         _prompt,
         _images,
         {tag, _},
         _trace
       )
       when tag in [:no_json_in_response, :output_truncated],
       do: :ok

  defp log_failed_unless_input_error(endpoint, type, prompt, images, reason, trace) do
    if input_error?(reason),
      do: :ok,
      else: log_failed_image_op_request(endpoint, type, prompt, images, reason, trace)
  end

  defp maybe_verify(result, _endpoint, false, _images, _opts), do: result

  defp maybe_verify(
         %{images: [%{data: data} | _]} = result,
         endpoint,
         verify,
         [original | _],
         opts
       )
       when is_binary(data) do
    checker = if verify == true, do: endpoint, else: verify
    intent = Enum.map_join(result.operations, ", ", &Atom.to_string/1)

    # The check is billed to whoever asked for the edit. The idempotency key
    # stays on the edit's own row: it names that call, not this one.
    check_opts = [
      intent: intent,
      source: opts[:source],
      user_uuid: opts[:user_uuid],
      capture_request_content: opts[:capture_request_content],
      task: opts[:task],
      run: opts[:run],
      step: opts[:step]
    ]

    case compare_images(checker, original, data, check_opts) do
      {:ok, verdict} -> Map.put(result, :verification, verdict)
      {:error, reason} -> Map.put(result, :verification, %{error: reason})
    end
  end

  defp maybe_verify(result, _endpoint, _verify, _images, _opts), do: result

  @doc """
  Asks a vision-capable endpoint about `images`: free text, or a parsed
  JSON object with `schema:` / `json: true`. See `PhoenixKitAI.Images.describe/3`.
  Logged as a `"vision"` request.

  The result carries `truncated: true` when the answer stopped at the output
  limit (`max_tokens`); a JSON request whose answer was cut off is
  `{:error, {:output_truncated, text}}` instead — billed, logged, never a
  half answer.

  `fallback_models: [model, ...]` tries the next model when a call fails for
  a reason another model could avoid: a safety block (`{:content_policy, _}`),
  an answer that is not the JSON asked for or was cut off, a provider outage
  (5xx, timeout, rate limit), or a model or parameters the provider cannot
  serve. Each attempt is a full call (gate, cache, usage row) with `model:`
  set to that model; a refusal (caps, limits, blocks, an unfit model), a bad
  key or balance, or a caller's input error never falls back. The answer
  lists the failed attempts in `:fallbacks` (`[%{model, error}]`, the error
  as its tag only).
  """
  @spec describe_image(
          String.t() | Endpoint.t(),
          [PhoenixKitAI.Images.input()] | PhoenixKitAI.Images.input(),
          keyword()
        ) ::
          {:ok,
           %{
             required(:text) => String.t() | nil,
             required(:json) => map() | list() | nil,
             required(:model) => String.t() | nil,
             optional(:truncated) => boolean(),
             optional(:regions) => [map()],
             optional(:dropped_regions) => non_neg_integer(),
             optional(:request_uuid) => String.t() | nil,
             optional(:cost) => Decimal.t() | nil,
             optional(:fallbacks) => [%{model: String.t() | nil, error: atom()}]
           }}
          | {:error, term()}
  def describe_image(endpoint_uuid, images, opts \\ []),
    do: with_fallback_models(endpoint_uuid, opts, &do_describe_image(endpoint_uuid, images, &1))

  defp do_describe_image(endpoint_uuid, images, opts) do
    images = List.wrap(images)

    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(endpoint, opts, :describe_image, Guard.implied_needs(:describe_image, opts)) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])
      prompt = opts[:prompt] || opts[:question] || PhoenixKitAI.Images.default_question()
      {opts, stripped} = Guard.require_parameters(opts, admission)

      trace =
        trace(
          source,
          stacktrace,
          caller_context,
          opts,
          admission |> Guard.row_metadata(stripped) |> note_skipped_thinking(endpoint, opts)
        )

      result =
        with_cache(
          :describe_image,
          endpoint,
          opts,
          fn -> {images, cacheable(opts)} end,
          image_row(trace),
          fn ->
            run_describe_image(endpoint, images, opts, prompt, trace)
          end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_unless_input_error(endpoint, "vision", prompt, images, reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Reads the text in one or more images with a vision endpoint — a label,
  a receipt, a sign, a document page — and returns it transcribed in
  reading order with typed blocks, the language, a legibility score and
  any named `fields:` the caller asked for. See
  `PhoenixKitAI.Images.extract_text/3` for the options. Logged as a
  `"vision"` request; `cache:` and the spend caps apply. A cut-off answer
  is `{:error, {:output_truncated, text}}`; `fallback_models:` works as on
  `describe_image/3`.

      {:ok, %{text: text, fields: %{"ean" => ean}}} =
        PhoenixKitAI.extract_text(endpoint_uuid, label_jpeg,
          fields: %{"ean" => "the barcode digits", "best_before" => "expiry date as YYYY-MM-DD"})
  """
  @spec extract_text(
          String.t() | Endpoint.t(),
          [PhoenixKitAI.Images.input()] | PhoenixKitAI.Images.input(),
          keyword()
        ) ::
          {:ok,
           %{
             optional(:request_uuid) => String.t() | nil,
             optional(:cost) => Decimal.t() | nil,
             optional(:fallbacks) => [%{model: String.t() | nil, error: atom()}],
             text: String.t(),
             blocks: [map()],
             language: String.t() | nil,
             confidence: number() | nil,
             has_illegible_text: boolean(),
             fields: map(),
             json: map(),
             model: String.t() | nil
           }}
          | {:error, term()}
  def extract_text(endpoint_uuid, images, opts \\ []),
    do: with_fallback_models(endpoint_uuid, opts, &do_extract_text(endpoint_uuid, images, &1))

  defp do_extract_text(endpoint_uuid, images, opts) do
    images = List.wrap(images)

    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(endpoint, opts, :extract_text, Guard.implied_needs(:extract_text, opts)) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])
      prompt = "extract_text"
      {opts, stripped} = Guard.require_parameters(opts, admission)

      trace =
        trace(
          source,
          stacktrace,
          caller_context,
          opts,
          admission |> Guard.row_metadata(stripped) |> note_skipped_thinking(endpoint, opts)
        )

      result =
        with_cache(
          :extract_text,
          endpoint,
          opts,
          fn -> {images, cacheable(opts)} end,
          image_row(trace),
          fn ->
            run_extract_text(endpoint, images, opts, prompt, trace)
          end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_unless_input_error(endpoint, "vision", prompt, images, reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Checks an edited image against its original with a vision endpoint:
  same subject, text and logos intact, unwanted changes. See
  `PhoenixKitAI.Images.compare/4`. Logged as a `"vision"` request.
  """
  @spec compare_images(
          String.t() | Endpoint.t(),
          PhoenixKitAI.Images.input(),
          PhoenixKitAI.Images.input(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def compare_images(endpoint_uuid, before, after_image, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, admission} <-
           authorize(endpoint, opts, :compare_images, Guard.implied_needs(:compare_images, opts)) do
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      source = Keyword.get(opts, :source) || auto_source
      caller_context = Map.put(caller_context, :user_uuid, opts[:user_uuid])
      prompt = "compare: " <> to_string(opts[:intent] || "an edit")
      {opts, stripped} = Guard.require_parameters(opts, admission)

      trace =
        trace(source, stacktrace, caller_context, opts, Guard.row_metadata(admission, stripped))

      images = [before, after_image]

      result =
        with_cache(
          :compare_images,
          endpoint,
          opts,
          fn -> {before, after_image, cacheable(opts)} end,
          image_row(trace),
          fn ->
            run_compare_images(endpoint, before, after_image, opts, prompt, trace)
          end
        )

      case result do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          log_failed_unless_input_error(endpoint, "vision", prompt, images, reason, trace)
          {:error, reason}
      end
    end
  end

  @doc """
  Finds things in images and says where they are: every visible instance of
  each of `labels` (a list of words — `["logo", "price tag"]`, a person's
  name, a part of a car — or `nil` for every notable thing), each with a
  `PhoenixKitAI.Box`. Options go fourth: a keyword list passed as `labels`
  is refused with `{:error, :labels_look_like_options}`.

      {:ok, %{regions: [%{label: "logo", box: box, image: 1} | _]}} =
        PhoenixKitAI.detect_regions(endpoint_uuid, photo, ["logo"])

  Returns `{:ok, %{regions: [%{label, description, box, image, confidence}],
  dropped_regions, model, request_uuid, cost}}`. `image` is which image the
  region is on (1 = the first). An empty list is a valid answer. Entries
  whose box the model got wrong in shape are left out and counted in
  `dropped_regions`. The boxes are read in the format the answering model
  writes (`PhoenixKitAI.Box.format_for/2`; a call's `box_format:` wins).

  It is `describe_image/3` with its own prompt and schema, so it takes the
  same options (`model:`, `task:`, `user_uuid:`, `cache:`, `run:`, `step:`,
  sampling) plus `instructions:` — extra wording for the prompt. Logged as a
  `"vision"` request. How exact the boxes are depends a lot on the model:
  some place them well, others answer with boxes that are nowhere near the
  thing, so check a model on your own images before relying on it.
  """
  @spec detect_regions(
          String.t() | Endpoint.t(),
          [PhoenixKitAI.Images.input()] | PhoenixKitAI.Images.input(),
          [String.t() | atom()] | String.t() | nil,
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def detect_regions(endpoint_uuid, images, labels \\ nil, opts \\ []) do
    images = List.wrap(images)

    with {:ok, labels} <- region_labels(labels) do
      describe_opts =
        opts
        |> Keyword.drop([:instructions, :regions, :question, :json, :schema])
        |> Keyword.put(
          :prompt,
          Regions.detect_prompt(labels, length(images), opts[:instructions])
        )
        |> Keyword.put(:schema, Regions.detect_schema(labels))

      with {:ok, result} <- describe_image(endpoint_uuid, images, describe_opts) do
        {regions, dropped} =
          Regions.parse_regions(
            (result.json || %{})["regions"],
            result.model,
            length(images),
            opts
          )

        {:ok,
         %{
           regions: regions,
           dropped_regions: dropped,
           model: result.model,
           request_uuid: result[:request_uuid],
           cost: result[:cost]
         }
         |> put_fallbacks(result)}
      end
    end
  end

  defp put_fallbacks(map, %{fallbacks: f}), do: Map.put(map, :fallbacks, f)
  defp put_fallbacks(map, _result), do: map

  defp region_labels(nil), do: {:ok, nil}
  defp region_labels([{key, _} | _]) when is_atom(key), do: {:error, :labels_look_like_options}
  defp region_labels(label) when is_binary(label), do: region_labels([label])

  defp region_labels(labels) when is_list(labels) do
    if Enum.all?(labels, &(is_binary(&1) or (is_atom(&1) and not is_nil(&1)))),
      do: {:ok, labels |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()},
      else: {:error, :invalid_labels}
  end

  defp region_labels(_labels), do: {:error, :invalid_labels}

  @doc """
  Checks statements against images: for each one, do the images support
  it, contradict it, or not show enough to say? Use it to check text
  written about a picture before it is published — a product listing
  against its photos, an AI-written description against its image, a
  report against the photos attached to it.

      {:ok, %{results: [%{verdict: :contradicted, evidence: evidence} | _]}} =
        PhoenixKitAI.check_statements(endpoint_uuid, ["The sofa is red leather"], photo)

  `statements` is a list of texts, or of `%{id: id, text: text}` /
  `{id, text}` to keep your own ids (else the 1-based position is the id).

  Returns `{:ok, %{results: [%{id, statement, verdict, evidence, image, box,
  answered}], counts: %{supported, contradicted, insufficient}, model,
  request_uuid, cost}}` with `verdict` one of `:supported`, `:contradicted`,
  `:insufficient`; `image` and `box` point at the deciding detail (nil for
  insufficient). A statement the model skipped is `:insufficient` with
  `answered: false`.

  The prompt tells the model to judge substance, not wording, because a
  strict model otherwise rejects true statements over technicalities. A
  verdict is still a model's reading: treat `:contradicted` as "look at
  this", not as proof. Options as `describe_image/3`, plus
  `instructions:`. Logged as a `"vision"` request.

  A `:contradicted` verdict must name the image that shows it; one that
  names none is reported as `:insufficient` with `downgraded:
  :no_evidence_image`. A single check can flip a true statement, so
  `confirm:` asks again about every contradicted statement — `true` on the
  same images, or a list of other images — and keeps the verdict only when
  the second check agrees (`confirmed: true`); otherwise it becomes
  `:insufficient` with `unconfirmed: true`. Both checks' evidence is kept
  (`evidence`, `confirm_evidence`), `cost` is the sum, the second call's row
  is `confirm_request_uuid`. The second check bypasses the cache, and a
  downgraded verdict is not asked again. When the second check fails,
  every contradicted verdict becomes unconfirmed `:insufficient`,
  `confirm_error` names the kind of failure, and any billed cost is still
  added. Any other `confirm:` value is `{:error, :invalid_confirm}`.
  Planted false statements are a cheap way to see
  whether a model is honest enough before trusting its `:supported`.
  """
  @spec check_statements(
          String.t() | Endpoint.t(),
          [String.t() | {term(), String.t()} | %{id: term(), text: String.t()}],
          [PhoenixKitAI.Images.input()] | PhoenixKitAI.Images.input(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def check_statements(endpoint_uuid, statements, images, opts \\ []) do
    {confirm, opts} = Keyword.pop(opts, :confirm)

    with :ok <- valid_confirm(confirm),
         {:ok, first} <- do_check_statements(endpoint_uuid, statements, images, opts) do
      confirm_contradictions(endpoint_uuid, first, images, confirm, opts)
    end
  end

  # `confirm:` — a contradiction stands only when a second, independent check
  # agrees: `true` asks again on the same images, a list of images asks on
  # those. One that the second check does not contradict becomes
  # `:insufficient` with `unconfirmed: true`; one it does gets `confirmed: true`.
  defp confirm_contradictions(_endpoint_uuid, first, _images, confirm, _opts)
       when confirm in [nil, false],
       do: {:ok, first}

  defp confirm_contradictions(endpoint_uuid, first, images, confirm, opts) do
    contradicted =
      first.results
      |> Enum.with_index()
      |> Enum.filter(fn {r, _} -> r.verdict == :contradicted end)

    confirm_images = if confirm == true, do: images, else: confirm

    if contradicted == [] do
      {:ok, first}
    else
      # Re-asked by position (ids may repeat), and never from the cache: an
      # identical second request would otherwise be the first answer again.
      again = Enum.map(contradicted, fn {r, i} -> %{id: i, text: r.statement} end)
      opts = Keyword.put(opts, :cache, false)
      before = Process.get(@unparsed_cost_key)

      case do_check_statements(endpoint_uuid, again, confirm_images, opts) do
        {:ok, second} ->
          {:ok, merge_confirmation(first, second)}

        # The second check failed: nothing is confirmed, so nothing stays
        # contradicted; an unusable answer it was billed for still counts.
        {:error, reason} ->
          {:ok,
           first
           |> drop_unconfirmed(reason)
           |> Map.update(:cost, nil, &add_costs(&1, unparsed_cost_since(before)))}
      end
    end
  end

  defp merge_confirmation(first, second) do
    # `second`'s ids are the positions of the re-asked statements in `first`.
    by_index = Map.new(second.results, &{&1.id, &1})

    results =
      first.results
      |> Enum.with_index()
      |> Enum.map(fn {r, i} -> confirm_one(r, by_index[i]) end)

    Map.merge(first, %{
      results: results,
      counts: verdict_counts(results),
      cost: add_costs(first[:cost], second[:cost]),
      confirm_request_uuid: second[:request_uuid]
    })
  end

  defp confirm_one(%{verdict: :contradicted} = r, %{verdict: :contradicted} = s),
    do: Map.merge(r, %{confirmed: true, confirm_evidence: s.evidence})

  defp confirm_one(%{verdict: :contradicted} = r, s),
    do:
      Map.merge(r, %{verdict: :insufficient, unconfirmed: true, confirm_evidence: s && s.evidence})

  defp confirm_one(r, _s), do: r

  defp drop_unconfirmed(first, reason) do
    results =
      Enum.map(first.results, fn
        %{verdict: :contradicted} = r ->
          Map.merge(r, %{verdict: :insufficient, unconfirmed: true})

        r ->
          r
      end)

    # Only the kind of failure: a provider's text can paraphrase the request.
    Map.merge(first, %{
      results: results,
      counts: verdict_counts(results),
      confirm_error: fallback_tag(reason)
    })
  end

  defp valid_confirm(c) when c in [nil, false, true], do: :ok
  defp valid_confirm([_ | _]), do: :ok
  defp valid_confirm(_other), do: {:error, :invalid_confirm}

  defp add_costs(nil, b), do: b
  defp add_costs(a, nil), do: a
  defp add_costs(a, b), do: Decimal.add(a, b)

  defp do_check_statements(endpoint_uuid, statements, images, opts) do
    images = List.wrap(images)

    with {:ok, statements} <- normalize_statements(statements) do
      describe_opts =
        opts
        |> Keyword.drop([:instructions, :regions, :question, :json, :schema])
        |> Keyword.put(
          :prompt,
          Regions.statements_prompt(
            Enum.map(statements, & &1.text),
            length(images),
            opts[:instructions]
          )
        )
        |> Keyword.put(:schema, Regions.statements_schema())

      with {:ok, result} <- describe_image(endpoint_uuid, images, describe_opts) do
        results =
          Regions.parse_statements(result.json, statements, result.model, length(images), opts)

        counts = verdict_counts(results)

        {:ok,
         %{
           results: results,
           counts: counts,
           model: result.model,
           request_uuid: result[:request_uuid],
           cost: result[:cost]
         }
         |> put_fallbacks(result)}
      end
    end
  end

  defp verdict_counts(results) do
    Enum.reduce(results, %{supported: 0, contradicted: 0, insufficient: 0}, fn r, acc ->
      Map.update!(acc, r.verdict, &(&1 + 1))
    end)
  end

  defp normalize_statements([]), do: {:error, :empty_input}

  defp normalize_statements(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn
      {text, i}, {:ok, acc} when is_binary(text) and text != "" ->
        {:cont, {:ok, [%{id: i, text: text} | acc]}}

      {{id, text}, _i}, {:ok, acc} when is_binary(text) and text != "" ->
        {:cont, {:ok, [%{id: id, text: text} | acc]}}

      {%{text: text} = s, i}, {:ok, acc} when is_binary(text) and text != "" ->
        {:cont, {:ok, [%{id: Map.get(s, :id, i), text: text} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid_statements}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp normalize_statements(_other), do: {:error, :invalid_statements}

  @doc """
  Runs one vision verb over many items — describing, reading or locating
  a folder of product photos, the pages of an import, a night's uploads —
  with a result per item. See `PhoenixKitAI.VisionBatch` for how it stops.

      {:ok, %{items: items, cost: cost, stopped: nil}} =
        PhoenixKitAI.vision_batch(endpoint_uuid, [%{id: 1, images: jpeg}, %{id: 2, images: png}],
          verb: :extract_text, concurrency: 8, budget: "2.00")

  An item is `%{id: id, images: images}` (plus an item's own `:prompt` —
  the prompt for `:describe_image`, extra `instructions:` for the other
  verbs — `:labels` for `:detect_regions`, `:statements` for
  `:check_statements`, `:opts` for that call), `{id, images}`, or the
  images alone (id = its index).

  Options: `verb:` — `:describe_image` (default), `:extract_text`,
  `:detect_regions` or `:check_statements`; `concurrency:` (default 4, at
  most 32); `budget:` — dollars (`Decimal` or decimal string) after which
  no new item starts; `item_timeout:` (ms, default 300 000); `labels:` for
  `:detect_regions`; `run:` / `step:` tags; `group:` (2–8, `:describe_image`
  only) — ask that many items in one call, so the prompt travels once: the
  answer has one entry per item (the item's `schema:`, or text), the call's
  cost is shared equally, an item the answer leaves out (or answers twice,
  or in the wrong shape) is `{:error, :missing_in_group}` and keeps its
  share, a group closes early rather than carry more image bytes than one
  call may, and items with their own `prompt:` or
  `opts:` still run alone; every other option is passed to each call
  (`prompt:`, `schema:`, `model:`, `fallback_models:`, `task:`,
  `user_uuid:`, …). `concurrency:` is the batch's own, so the
  `PhoenixKitAI.Limiter` option of that name cannot be passed through; set
  the limiter per provider in config. A caller `cache: [key: …]` is one key
  for every item, so every item would get the first item's answer: leave
  the key to the default, which hashes each item's images.

  Returns `{:ok, %{run, verb, items: [%{id, status, result, error, cost}],
  cost, counts: %{ok, error, unparsed, skipped}, stopped}}`: `status` is
  `:ok`, `:error`, `:unparsed` (the model answered without valid JSON —
  billed, no result) or `:skipped` (not started after the batch stopped);
  `stopped` is nil, `:budget`, or `{:error, reason}` for a refusal every
  later item would hit. `cost` sums the items' costs, unparsed answers and
  billed fallback attempts included; `run_costs/2` on `run` totals the
  journal rows. A call that times out (`item_timeout:`) may still be billed
  by the provider: its cost is unknown here, and the provider's own row, if
  any, is the only record.
  """
  @spec vision_batch(String.t() | Endpoint.t(), list(), keyword()) ::
          {:ok, PhoenixKitAI.VisionBatch.t()} | {:error, term()}
  def vision_batch(endpoint_uuid, items, opts \\ []),
    do: PhoenixKitAI.VisionBatch.run(endpoint_uuid, items, opts)

  @doc """
  What one run cost: the totals of every usage row tagged with `run:` —
  in all, per `step:` and per model. See `PhoenixKitAI.Runs.costs/2`.

      {:ok, %{total: %{cost: cost, calls: calls}, by_step: steps}} =
        PhoenixKitAI.run_costs("import-2026-10-27", since: started_at)
  """
  @spec run_costs(term(), keyword()) :: {:ok, PhoenixKitAI.Runs.t()} | {:error, :invalid_run}
  def run_costs(run, opts \\ []), do: PhoenixKitAI.Runs.costs(run, opts)

  @doc """
  The image models the endpoint's provider offers, with what each accepts
  (`PhoenixKitAI.Images.ImageModel`). `{:error, :not_supported}` when the
  provider publishes no listing. `refresh: true` bypasses the cache.
  """
  @spec image_models(String.t() | Endpoint.t(), keyword()) ::
          {:ok, [ImageModel.t()]} | {:error, term()}
  def image_models(endpoint_uuid, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid) do
      ImageModels.list(endpoint, opts)
    end
  end

  @doc "The endpoint's own model's capabilities, or nil when the provider publishes none."
  @spec image_model(String.t() | Endpoint.t()) :: ImageModel.t() | nil
  def image_model(endpoint_uuid) do
    case resolve_endpoint(endpoint_uuid) do
      {:ok, endpoint} -> ImageModels.get(endpoint, endpoint.model)
      _ -> nil
    end
  end

  @doc "The option names an endpoint's adapter can send when no model listing exists."
  @spec image_options(String.t() | Endpoint.t()) :: [atom()]
  def image_options(endpoint_uuid) do
    case resolve_endpoint(endpoint_uuid) do
      {:ok, endpoint} -> Provider.for_endpoint(endpoint).image_options(endpoint)
      _ -> []
    end
  end

  @doc "Every image operation `process_image/4` understands (built-ins plus the host's)."
  @spec image_operations() :: %{atom() => map()}
  def image_operations, do: Operations.all()

  # What every image row records about the call itself: who asked (source,
  # stacktrace, caller context), when it started, the caller's idempotency
  # key if any, and — on failures — the model override that was in play.
  # Also the call's attribution and the guard's fields for the row (`guard`,
  # from `Guard.row_metadata/2`: the task, warnings, stripped parameters).
  defp trace(source, stacktrace, ctx, opts, guard) do
    %{
      source: source,
      stacktrace: stacktrace,
      ctx: ctx,
      started: System.monotonic_time(:millisecond),
      idempotency_key: opts[:idempotency_key],
      model: opts[:model],
      user_uuid: opts[:user_uuid],
      capture: opts[:capture_request_content],
      attribution: normalize_attribution(opts[:attribution]),
      guard: guard
    }
  end

  # What a cache hit of an image verb writes its row with.
  defp image_row(trace),
    do: %{
      source: trace.source,
      caller_context: trace.ctx,
      attribution: trace.attribution,
      guard: trace.guard
    }

  defp trace_metadata(trace) do
    meta =
      %{source: trace.source, stacktrace: trace.stacktrace, caller_context: trace.ctx}
      |> maybe_put_attribution(trace[:attribution])
      |> Map.merge(trace[:guard] || %{})

    if trace[:idempotency_key],
      do: Map.put(meta, :idempotency_key, trace.idempotency_key),
      else: meta
  end

  # One row per image verb (`image`, `image_edit`, `vision`): tokens, the
  # cost (`image_op_cost/5`), latency, counts and byte sizes of
  # the images — never the image bytes; prompt and any text under the PII
  # gate. `trace` comes from `trace/4`.
  defp log_image_op_request(endpoint, type, prompt, images, result, extra, trace) do
    capture_content = capture_request_content?(trace[:capture])
    usage = result[:usage] || %{}
    outputs = result[:images] || []
    prompt = to_string(prompt)
    emit_image_telemetry(type, endpoint, result, extra, trace, images, outputs, :ok)

    base_metadata =
      extra
      |> Map.delete(:warning_tags)
      |> Map.merge(%{
        input_chars: String.length(prompt),
        input_image_count: length(images),
        input_bytes: image_input_bytes(images),
        output_image_count: length(outputs),
        output_bytes: Enum.reduce(outputs, 0, &(&2 + byte_size(&1[:data] || ""))),
        provider: endpoint.provider
      })
      |> Map.merge(trace_metadata(trace))

    {cost, cost_metadata} = image_op_cost(type, endpoint, result, usage, trace)

    metadata =
      base_metadata
      |> maybe_add_content(:input, capture_content, fn -> prompt end)
      |> maybe_add_content(:response, capture_content, fn -> result[:text] end)
      |> Map.merge(cost_metadata)

    log_usage(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: result[:model] || trace[:model] || endpoint.model,
      request_type: type,
      input_tokens: usage[:prompt_tokens] || 0,
      output_tokens: usage[:completion_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      cost: cost,
      latency_ms: result[:latency_ms],
      status: "success",
      user_uuid: trace[:user_uuid],
      metadata: metadata
    })
  end

  # A vision call is a chat call with images, priced like one (`CallCost`):
  # the model the answer names, else the one sent — the call's `model:`,
  # else the endpoint's (a manual price is its own model's, so it does not
  # price a call sent to another). Making or editing images is priced per
  # image or per call, which a price per token does not fit: there only the
  # provider's own cost counts.
  defp image_op_cost("vision", endpoint, result, usage, trace) do
    CallCost.for_call(
      %{endpoint | model: trace[:model] || endpoint.model},
      result[:model],
      usage[:cost],
      usage[:prompt_tokens],
      usage[:completion_tokens]
    )
  end

  defp image_op_cost(_type, _endpoint, _result, usage, _trace),
    do: {Money.round_cost(usage[:cost]), %{}}

  defp log_failed_image_op_request(endpoint, type, prompt, images, reason, trace) do
    capture_content = capture_request_content?(trace[:capture])
    prompt = to_string(prompt)
    emit_image_telemetry(type, endpoint, %{}, %{error: reason}, trace, images, [], :error)

    # The reason's shape is always recorded; its payload (a refusal's
    # prose about the user's image, say) only under the PII gate.
    base_metadata =
      %{
        error_reason: if(capture_content, do: inspect(reason), else: inspect(error_tag(reason))),
        input_chars: String.length(prompt),
        input_image_count: length(images),
        input_bytes: image_input_bytes(images),
        provider: endpoint.provider
      }
      |> Map.merge(trace_metadata(trace))

    %{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: trace[:model] || endpoint.model,
      request_type: type,
      latency_ms: System.monotonic_time(:millisecond) - trace.started,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      status: "error",
      user_uuid: trace[:user_uuid],
      error_message: PhoenixKitAI.Errors.message(reason),
      metadata: base_metadata |> maybe_add_content(:input, capture_content, fn -> prompt end)
    }
    |> with_provider_error()
    |> log_usage()
  end

  # `[:phoenix_kit_ai, :image, :request]` — one event per provider call the
  # image verbs make, with sizes and timing in the measurements and only
  # tags (no prompts, no bytes) in the metadata.
  defp emit_image_telemetry(type, endpoint, result, extra, trace, images, outputs, outcome) do
    :telemetry.execute(
      [:phoenix_kit_ai, :image, :request],
      %{
        latency_ms: result[:latency_ms] || System.monotonic_time(:millisecond) - trace.started,
        input_bytes: image_input_bytes(images),
        output_bytes: Enum.reduce(outputs, 0, &(&2 + byte_size(&1[:data] || ""))),
        input_images: length(images),
        output_images: length(outputs)
      },
      %{
        type: type,
        outcome: outcome,
        provider: endpoint.provider,
        model: result[:model] || trace[:model] || endpoint.model,
        endpoint_uuid: endpoint.uuid,
        operations: extra[:operations] || [],
        warnings: extra[:warning_tags] || [],
        error: extra[:error] && error_tag(extra[:error]),
        source: trace.source
      }
    )
  rescue
    _ -> :ok
  end

  # The shape of an error without its payload (a refusal's prose, a URL).
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error_tag(_reason), do: :unknown

  defp image_input_bytes(images) do
    Enum.reduce(images, 0, fn
      %{data: data}, acc when is_binary(data) -> acc + byte_size(data)
      "data:" <> _, acc -> acc
      "http" <> _, acc -> acc
      bytes, acc when is_binary(bytes) -> acc + byte_size(bytes)
      _other, acc -> acc
    end)
  end

  @doc """
  Extracts the text content from a completion response.

  ## Examples

      {:ok, response} = PhoenixKitAI.ask(endpoint_uuid, "Hello!")
      {:ok, text} = PhoenixKitAI.extract_content(response)
      # => "Hello! How can I help you today?"
  """
  defdelegate extract_content(response), to: Completion

  @doc """
  The tool calls the model asked for in a chat completion response, as the
  provider sent them; `[]` when there are none. See
  `PhoenixKitAI.Completion.extract_tool_calls/1`.
  """
  defdelegate extract_tool_calls(response), to: Completion

  @doc """
  Extracts usage information from a response.

  ## Examples

      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, messages)
      usage = PhoenixKitAI.extract_usage(response)
      # => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25}
  """
  defdelegate extract_usage(response), to: Completion

  # Private helpers for completion API

  # The verbs that send a call's `model:` instead of the endpoint's model.
  @model_override_verbs [
    :complete,
    :embed,
    :describe_image,
    :extract_text,
    :compare_images,
    :generate_image,
    :edit_image,
    :process_image
  ]

  # A `model:` that names no model (empty, not a string) is no override, and
  # `models:` keeps only names: either would otherwise reach the provider
  # while the guard, the cache and the row went by another model.
  defp call_model_opts(opts) do
    opts =
      case opts[:model] do
        model when is_binary(model) and model != "" -> opts
        _ -> Keyword.delete(opts, :model)
      end

    case opts[:models] do
      models when is_list(models) ->
        Keyword.put(opts, :models, Enum.filter(models, &(is_binary(&1) and &1 != "")))

      _ ->
        Keyword.delete(opts, :models)
    end
  end

  # `models:` is OpenRouter's model routing; no other provider is sent it, so
  # elsewhere it is dropped before the guard checks it or the cache keys on it.
  defp fallbacks_for(endpoint, opts) do
    if Endpoint.openrouter?(endpoint), do: opts, else: Keyword.delete(opts, :models)
  end

  # Every OpenRouter fallback in `models:` may answer the call, so each is
  # checked as the call's own model is; the first that does not fit refuses
  # the call.
  defp check_fallbacks(endpoint, opts, task, implied) do
    sent = opts[:model] || endpoint.model

    (opts[:models] || [])
    |> Enum.reject(&(&1 == sent))
    |> Enum.find_value(:ok, fn model ->
      case Guard.check(endpoint, Keyword.put(opts, :model, model), task, implied) do
        {:ok, _admission} -> nil
        {:error, _reason} = refused -> refused
      end
    end)
  end

  # Chat and embeddings send a call's `model:` instead of the endpoint's; the
  # endpoint then stands for that model everywhere after the guard (the
  # request body's provider rules, the cache key, the usage row, the price).
  defp with_call_model(endpoint, opts) do
    case opts[:model] do
      model when is_binary(model) and model != "" -> %{endpoint | model: model}
      _ -> endpoint
    end
  end

  defp sent_model(endpoint, opts, verb) do
    if verb in @model_override_verbs, do: opts[:model] || endpoint.model, else: endpoint.model
  end

  # Every provider-calling verb passes here, in this order: the endpoint
  # must be usable; the user must not be blocked from the task's group
  # (`GuardBlocks.check/2`, skipped for a call that holds an admission of
  # `Guard.admit/4`, which checked it); the model must fit what the call
  # and its task need
  # (`Guard.check/4`, `implied` being what the call itself shows); the
  # task's own limits (`TaskLimits.check/3`, skipped for a call that holds
  # an admission of `Guard.admit/4` for its task and user); when caps are
  # set, the last 24 hours of spend must leave room — a refusal there is
  # also a guard event (`GuardEvents.budget_refused/4`). The request cache
  # comes after, then HTTP.
  #
  # `spends?` is false only for a `process_image/4` dry run, the one verb
  # that honours `dry_run:` — reading the option here let every other verb
  # skip the cap and still call the provider. A dry run still has its
  # fitness checked; it skips the spend caps, the task's limits and its
  # blocks.
  #
  # A refusal after the endpoint check is written as a usage row by
  # `refuse/4`; an unusable endpoint is not (that is a configuration error,
  # not a call that was turned away).
  defp authorize(endpoint, opts, verb, implied, spends? \\ true) do
    with {:ok, endpoint} <- validate_endpoint(endpoint) do
      # The model checked (and named on a refusal row) is the one the verb
      # sends: speech always sends the endpoint's; chat, embeddings and the
      # image verbs send a call's `model:` when it names one.
      opts = if verb in @model_override_verbs, do: opts, else: Keyword.delete(opts, :model)

      case admit(endpoint, opts, implied, spends?) do
        {:ok, _admission} = admitted -> admitted
        {:error, reason} -> refuse(endpoint, opts, verb, reason)
      end
    end
  end

  defp admit(endpoint, opts, implied, spends?) do
    task = Tasks.for_call(opts[:task])

    with :ok <- money_ready(endpoint),
         # A switched-off module's task refuses every call, a dry run too.
         :ok <- Tasks.check_enabled(task),
         :ok <- if(spends?, do: blocks(task, opts), else: :ok),
         {:ok, admission} <- Guard.check(endpoint, opts, task, implied),
         :ok <- check_fallbacks(endpoint, opts, task, implied),
         :ok <- if(spends?, do: task_limits(task, opts), else: :ok),
         :ok <- if(spends?, do: budget(endpoint, opts), else: :ok) do
      {:ok, admission}
    end
  end

  # Money is dollars from core's V223 and this module's V4 on: before both
  # have run (the `cost` column missing, or an endpoint's manual price still
  # in millionths), no call is made — a cap or a price read in the wrong unit
  # would be off by a million.
  defp money_ready(endpoint) do
    if Money.ready?() and not ManualPrice.legacy?(endpoint),
      do: :ok,
      else: {:error, :money_migration_required}
  end

  defp blocks(nil, _opts), do: :ok

  defp blocks(task, opts) do
    if Guard.admitted?(opts[:guard_admission], task.key, opts[:user_uuid]),
      do: :ok,
      else: GuardBlocks.check(task, opts[:user_uuid])
  end

  defp task_limits(nil, _opts), do: :ok

  defp task_limits(task, opts) do
    if Guard.admitted?(opts[:guard_admission], task.key, opts[:user_uuid]),
      do: :ok,
      else: TaskLimits.check(task, opts)
  end

  defp budget(endpoint, opts) do
    with {:error, {:budget_exceeded, scope}} = refusal <- Budget.check(endpoint, opts) do
      GuardEvents.budget_refused(scope, endpoint, opts)
      refusal
    end
  end

  # One row per refused call, before any HTTP: status "error", the reason,
  # who asked (caller info, user, attribution) and the task, marked
  # `refused: true` so usage sinks leave it out (`dispatch_usage_sinks/1`)
  # and spend never counts it.
  defp refuse(endpoint, opts, verb, reason) do
    {auto_source, stacktrace, caller_context} = capture_caller_info()

    metadata =
      %{
        refused: true,
        error_reason: inspect(reason),
        source: Keyword.get(opts, :source) || auto_source,
        stacktrace: stacktrace,
        caller_context: Map.put(caller_context, :user_uuid, opts[:user_uuid])
      }
      |> Map.merge(Guard.task_metadata(opts))
      |> maybe_put_attribution(normalize_attribution(opts[:attribution]))

    log_usage(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      prompt_uuid: opts[:prompt_uuid],
      prompt_name: opts[:prompt_name],
      model: opts[:model] || endpoint.model,
      request_type: @cached_row_type[verb],
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      latency_ms: 0,
      status: "error",
      user_uuid: opts[:user_uuid],
      error_message: error_reason_to_string(reason),
      metadata: metadata
    })

    {:error, reason}
  end

  defp validate_endpoint(endpoint) do
    cond do
      endpoint.model == nil or endpoint.model == "" ->
        {:error, :endpoint_no_model}

      endpoint.enabled == false ->
        {:error, :endpoint_disabled}

      true ->
        case endpoint_credential_status(endpoint) do
          :ok -> {:ok, endpoint}
          {:error, _} = err -> err
        end
    end
  end

  # Mirrors the lookup ladder that `OpenRouterClient.resolve_api_key/1`
  # walks at request time so validation can't disagree with the actual
  # credential resolution: integration_uuid first, then the legacy
  # `provider` column (which carried a uuid pre-V107), then the legacy
  # `api_key` column. Validation only fails when ALL three sources are
  # empty — same as the request path. The error reason distinguishes
  # between "you pinned an integration that was deleted" (orphan) and
  # "you never wired anything up" so the user-facing message is honest.
  #
  # **Intentional behaviour change vs pre-strict-UUID** (PR #6 review
  # finding #2): the old shape short-circuited on
  # `not Integrations.connected?(endpoint.provider)` — an integration
  # with stored credentials but in a not-`"connected"` state would
  # fail validation pre-API. The new ladder does NOT consult
  # `connected?/1`: as long as a credential exists in any of the
  # three sources, we let the upstream provider be the source of
  # truth on whether the key actually authenticates. This matches
  # how the request path resolves credentials — validation only
  # disagrees with the eventual request when one of the three
  # sources changes between validate and dispatch, which is a
  # narrower window than the old shape's "stale `connected?` state"
  # window. A row that's `"error"` or `"configured"` (creds present,
  # never validated) now reaches the upstream API and gets a real
  # 401/403 instead of a pre-emptive `:integration_not_configured`.
  # If a caller specifically wants "is this key healthy right now",
  # they should call `PhoenixKit.Integrations.validate_connection/2`
  # directly — `endpoint_credential_status/1` is the
  # `is this endpoint dispatchable` check, not a health check.
  defp endpoint_credential_status(endpoint) do
    cond do
      match?({:ok, _}, lookup_credentials(endpoint.integration_uuid)) ->
        :ok

      match?({:ok, _}, lookup_credentials(endpoint.provider)) ->
        :ok

      is_binary(endpoint.api_key) and endpoint.api_key != "" ->
        :ok

      is_binary(endpoint.integration_uuid) and endpoint.integration_uuid != "" ->
        {:error, :integration_deleted}

      true ->
        {:error, :integration_not_configured}
    end
  end

  defp lookup_credentials(nil), do: {:error, :not_configured}
  defp lookup_credentials(""), do: {:error, :not_configured}

  defp lookup_credentials(key) when is_binary(key) do
    PhoenixKitAI.Cache.credentials(key, fn -> PhoenixKit.Integrations.get_credentials(key) end)
  end

  defp merge_endpoint_opts(endpoint, opts) do
    # Endpoint defaults, then user overrides
    base_opts = [
      temperature: endpoint.temperature,
      max_tokens: endpoint.max_tokens,
      top_p: endpoint.top_p,
      top_k: endpoint.top_k,
      frequency_penalty: endpoint.frequency_penalty,
      presence_penalty: endpoint.presence_penalty,
      repetition_penalty: endpoint.repetition_penalty,
      stop: endpoint.stop,
      seed: endpoint.seed,
      # Reasoning/thinking parameters (for models like DeepSeek R1, Qwen QwQ)
      reasoning_enabled: endpoint.reasoning_enabled,
      reasoning_effort: endpoint.reasoning_effort,
      reasoning_max_tokens: endpoint.reasoning_max_tokens,
      reasoning_exclude: endpoint.reasoning_exclude
    ]

    # Filter out nil values and merge with user opts
    base_opts
    |> Keyword.drop(caller_only_options(endpoint))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  # Anthropic's OpenAI-compatible layer answers 400 to a `temperature`,
  # `top_p` or `top_k` its newer models do not take, and ignores the
  # penalties and `seed`: the endpoint's stored sampling values (the
  # schema's 0.7 default among them) are not sent there. A caller's own
  # `temperature:` / `top_p:` / `top_k:` still is, except that `Completion`
  # never sends `temperature` and `top_p` together, nor either of them to a
  # model from Claude Opus 4.7 on.
  defp caller_only_options(endpoint) do
    if Completion.anthropic?(endpoint),
      do: [
        :temperature,
        :top_p,
        :top_k,
        :frequency_penalty,
        :presence_penalty,
        :repetition_penalty,
        :seed
      ],
      else: []
  end

  defp merge_embedding_opts(endpoint, opts) do
    base_opts = [dimensions: endpoint.dimensions]

    base_opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  # ===========================================
  # CALLER INFO CAPTURE (for source tracking & debugging)
  # ===========================================

  @doc false
  # Captures full debug context: source, stacktrace, and caller context.
  #
  # Memory capture is opt-in via `config :phoenix_kit_ai, capture_request_memory: true`
  # to avoid bloating JSONB metadata on every request.
  defp capture_caller_info do
    keys =
      if Application.get_env(:phoenix_kit_ai, :capture_request_memory, false) do
        [:current_stacktrace, :memory]
      else
        [:current_stacktrace]
      end

    info = Process.info(self(), keys)
    stack = Keyword.fetch!(info, :current_stacktrace)
    memory = Keyword.get(info, :memory)

    # Format stacktrace for storage
    formatted_stack = format_stacktrace(stack)

    # Extract clean source from first non-internal caller
    source = extract_source(stack)

    # Build caller context with additional debug info
    caller_context = build_caller_context(memory)

    {source, formatted_stack, caller_context}
  end

  defp format_stacktrace(stack) do
    stack
    # Limit depth for storage
    |> Enum.take(20)
    |> Enum.map(fn {mod, fun, arity, location} ->
      mod_str = Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
      file = Keyword.get(location, :file, ~c"unknown") |> to_string()
      line = Keyword.get(location, :line, 0)
      "#{mod_str}.#{fun}/#{arity} (#{file}:#{line})"
    end)
  end

  defp extract_source(stack) do
    # Modules to skip (PhoenixKitAI internals, Elixir/Erlang core)
    skip_prefixes = ["PhoenixKitAI", "Elixir.PhoenixKitAI"]
    skip_modules = [Process, :proc_lib, :gen_server, :gen, :elixir, :erl_eval]

    caller =
      Enum.find(stack, fn {mod, _fun, _arity, _loc} ->
        mod_str = Atom.to_string(mod)

        not Enum.any?(skip_prefixes, &String.starts_with?(mod_str, &1)) and
          mod not in skip_modules
      end)

    case caller do
      {mod, fun, _arity, _loc} ->
        mod_str = Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
        "#{mod_str}.#{fun}"

      nil ->
        nil
    end
  end

  defp build_caller_context(memory) do
    # Get Phoenix request_id from Logger metadata (if in request context)
    logger_meta = Logger.metadata()

    base = %{
      request_id: Keyword.get(logger_meta, :request_id),
      node: node() |> Atom.to_string(),
      pid: self() |> inspect()
    }

    if is_integer(memory), do: Map.put(base, :memory_bytes, memory), else: base
  end

  # ===========================================
  # REQUEST LOGGING
  # ===========================================

  defp log_request(endpoint, messages, response, source, stacktrace, caller_context, prompt_info) do
    usage = Completion.extract_usage(response)

    # Extract response content
    response_content =
      case Completion.extract_content(response) do
        {:ok, content} -> content
        _ -> nil
      end

    # Reasoning models (DeepSeek-R1, Mistral Magistral, OpenAI o-series,
    # Anthropic extended thinking) return the chain-of-thought alongside
    # the final answer in a `reasoning` / `reasoning_content` /
    # `thinking` field. Capture it next to `response` so the request
    # detail page can surface it later — currently dropped on the floor
    # when only `content` is extracted. Subject to the same
    # `capture_request_content?` gate as `response` (see below) — when
    # content capture is off, reasoning is dropped too. Reasoning can
    # contain anything the prompt mentioned, so it's PII-equivalent.
    response_reasoning = Completion.extract_reasoning(response)

    # User-content persistence is opt-out. Default `true` preserves the
    # debugging shape we've shipped so far; deployments with PII or
    # data-retention obligations can flip it off via
    # `config :phoenix_kit_ai, capture_request_content: false`. Token
    # counts, latency, model, and cost are always recorded.
    capture_content = capture_request_content?(prompt_info[:capture])
    normalized = if capture_content, do: normalize_messages(messages), else: nil

    base_metadata =
      %{
        temperature: endpoint.temperature,
        max_tokens: endpoint.max_tokens,
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
      |> maybe_put_attribution(prompt_info[:attribution])
      |> maybe_put_prompt_snapshot(prompt_info[:prompt_snapshot])
      |> maybe_put_unbound_placeholders(prompt_info[:unbound_placeholders])
      |> Map.merge(prompt_info[:guard] || %{})
      |> maybe_put_answered_model(endpoint.model, response["model"])

    metadata =
      if capture_content do
        request_payload = %{
          model: endpoint.model,
          messages: normalized,
          temperature: endpoint.temperature,
          max_tokens: endpoint.max_tokens
        }

        base_metadata
        |> Map.merge(%{
          messages: normalized,
          response: response_content,
          response_reasoning: response_reasoning,
          request_payload: request_payload
        })
        |> maybe_put_tool_calls(Completion.extract_tool_calls(response))
      else
        Map.put(base_metadata, :content_redacted, true)
      end

    # The provider's cost, else a catalogue, manual or table price for the
    # model the answer names (`CallCost`).
    {cost, cost_metadata} = call_cost(endpoint, response, usage, usage.completion_tokens)

    log_usage(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      prompt_uuid: prompt_info[:prompt_uuid],
      prompt_name: prompt_info[:prompt_name],
      model: endpoint.model,
      request_type: "chat",
      input_tokens: usage.prompt_tokens,
      output_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      cost: cost,
      latency_ms: response["latency_ms"],
      status: "success",
      user_uuid: caller_context[:user_uuid],
      metadata: Map.merge(metadata, cost_metadata)
    })
  end

  defp log_failed_request(
         endpoint,
         messages,
         reason,
         source,
         stacktrace,
         caller_context,
         prompt_info
       ) do
    capture_content = capture_request_content?(prompt_info[:capture])

    metadata =
      %{
        # Original reason atom/tuple — preserved alongside the
        # human-readable error_message so callers can still filter on
        # the machine-readable shape.
        error_reason: inspect(reason),
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
      # §9.4 fix: this branch used to build `metadata` without ever
      # merging `attribution` — the success branch (`log_request/7`,
      # above) did, so a request that failed came out unattributable in
      # the usage/diagnostics panel. A caller can't tell which resource a
      # timeout belonged to on exactly the runs where knowing that
      # matters most.
      |> maybe_put_attribution(prompt_info[:attribution])
      |> maybe_put_unbound_placeholders(prompt_info[:unbound_placeholders])
      |> Map.merge(prompt_info[:guard] || %{})
      |> maybe_add_content(:messages, capture_content, fn -> normalize_messages(messages) end)

    %{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      prompt_uuid: prompt_info[:prompt_uuid],
      prompt_name: prompt_info[:prompt_name],
      model: endpoint.model,
      request_type: "chat",
      status: "error",
      user_uuid: caller_context[:user_uuid],
      error_message: error_reason_to_string(reason),
      metadata: metadata
    }
    |> with_provider_error()
    |> log_usage()
  end

  # What the provider said on the call that just failed
  # (`PhoenixKitAI.ProviderError`): its words after the module's text in
  # `error_message`, and its status, code, message and Retry-After under
  # `provider_error` in the metadata.
  defp with_provider_error(%{error_message: text, metadata: metadata} = attrs) do
    case ProviderError.take() do
      nil ->
        attrs

      note ->
        %{
          attrs
          | error_message: ProviderError.describe(text, note),
            metadata: Map.put(metadata, :provider_error, note)
        }
    end
  end

  # The model the provider says answered, where it is not the one asked
  # for (a provider may route a request to another model;
  # `Request.other_model/2`); `model` keeps the one asked for.
  defp maybe_put_answered_model(metadata, asked, answered) do
    case Request.other_model(asked, answered) do
      nil -> metadata
      other -> Map.put(metadata, :answered_model, other)
    end
  end

  defp maybe_add_content(metadata, _key, false, _build),
    do: Map.put(metadata, :content_redacted, true)

  defp maybe_add_content(metadata, key, true, build), do: Map.put(metadata, key, build.())

  # Render a `{:error, reason}` value into a string suitable for the
  # `error_message` :string column. `Errors.message/1` is total — atoms,
  # tagged tuples, and strings all collapse to a translated string.
  defp error_reason_to_string(reason), do: PhoenixKitAI.Errors.message(reason)

  # Whether to persist user/assistant message content to request metadata.
  # Defaults to `true` for parity with the shipped behaviour. Deployments
  # with retention or PII concerns set
  # `config :phoenix_kit_ai, capture_request_content: false`.
  defp capture_request_content? do
    Application.get_env(:phoenix_kit_ai, :capture_request_content, true)
  end

  # What a tool-calling round answered with: no text, so `response` is nil and
  # the calls (names and JSON arguments, user content) are what the row keeps.
  defp maybe_put_tool_calls(metadata, []), do: metadata
  defp maybe_put_tool_calls(metadata, calls), do: Map.put(metadata, :response_tool_calls, calls)

  # A call's own `capture_request_content: false` switches capture off for
  # that call; it never switches it on — the global setting is the
  # operator's PII/retention switch. Anything else leaves it to the setting.
  defp capture_request_content?(false), do: false
  defp capture_request_content?(_override), do: capture_request_content?()

  # Messages as stored with the usage row: what was sent, tool fields included.
  defp normalize_messages(messages), do: Enum.map(messages, &Completion.normalize_message/1)

  defp log_embedding_request(
         endpoint,
         input,
         response,
         {source, stacktrace, caller_context, guard}
       ) do
    usage = Completion.extract_usage(response)
    input_count = if is_list(input), do: length(input), else: 1
    image_count = if is_list(input), do: Enum.count(input, &embed_image_item?/1), else: 0

    {cost, cost_metadata} = call_cost(endpoint, response, usage, 0)

    log_usage(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      input_tokens: usage.prompt_tokens,
      total_tokens: usage.total_tokens,
      cost: cost,
      latency_ms: response["latency_ms"],
      status: "success",
      user_uuid: caller_context[:user_uuid],
      metadata:
        Map.merge(
          %{
            input_count: input_count,
            dimensions: endpoint.dimensions,
            image_count: image_count,
            # Debug context (source tracking)
            source: source,
            stacktrace: stacktrace,
            caller_context: caller_context
          }
          |> maybe_put_answered_model(endpoint.model, response["model"]),
          Map.merge(guard, cost_metadata)
        )
    })
  end

  # A call's cost from `CallCost`. An answer without `usage` says nothing
  # about the call's size: no cost, rather than a priced $0.
  defp call_cost(endpoint, %{"usage" => %{}} = response, usage, output_tokens) do
    CallCost.for_call(
      endpoint,
      response["model"],
      usage.cost,
      usage.prompt_tokens,
      output_tokens
    )
  end

  defp call_cost(_endpoint, _response, _usage, _output_tokens), do: {nil, %{}}

  defp log_failed_embedding_request(endpoint, reason, {source, stacktrace, caller_context, guard}) do
    %{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      status: "error",
      user_uuid: caller_context[:user_uuid],
      error_message: error_reason_to_string(reason),
      metadata:
        Map.merge(
          %{
            error_reason: inspect(reason),
            # Debug context (source tracking)
            source: source,
            stacktrace: stacktrace,
            caller_context: caller_context
          },
          guard
        )
    }
    |> with_provider_error()
    |> log_usage()
  end

  # TTS responses carry no token usage — billing is per-character (or per-token with
  # no usage object to read back, for OpenAI) — so input_tokens/output_tokens/
  # total_tokens stay unset, same as before. cost is now estimated from a
  # hand-maintained rate table (see TtsPricing) instead of staying unset, since no
  # TTS provider self-reports cost the way OpenRouter's chat completions do. The input
  # text is gated by `capture_request_content?/0` like chat/embedding.
  defp log_tts_request(endpoint, text, result, {source, stacktrace, caller_context, guard}) do
    capture_content = capture_request_content?()
    input_chars = String.length(text)
    audio_bytes = byte_size(result[:audio])

    base_metadata = %{
      input_chars: input_chars,
      audio_format: result[:format],
      audio_bytes: audio_bytes,
      has_timestamps: is_list(result[:timestamps]),
      # Debug context (source tracking)
      source: source,
      stacktrace: stacktrace,
      caller_context: caller_context
    }

    log_usage(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "tts",
      latency_ms: result[:latency_ms],
      status: "success",
      user_uuid: caller_context[:user_uuid],
      cost: TtsPricing.cost(endpoint.provider, input_chars, audio_bytes),
      metadata:
        base_metadata
        |> Map.merge(guard)
        |> maybe_add_content(:input, capture_content, fn -> text end)
    })
  end

  # When the caller passed neither :voice nor :voice_id, fall back to a
  # per-endpoint default voice persisted in provider_settings["voice"].
  # An explicit caller value always wins, and a blank/absent default is
  # a no-op (Completion sends no voice field at all in that case).
  defp maybe_put_default_voice(endpoint, opts) do
    if Keyword.has_key?(opts, :voice) or Keyword.has_key?(opts, :voice_id) do
      opts
    else
      case endpoint.provider_settings || %{} do
        %{"voice" => voice} when is_binary(voice) and voice != "" ->
          Keyword.put(opts, voice_field_for(endpoint), voice)

        _ ->
          opts
      end
    end
  end

  # Which request field carries the stored default voice. Mistral's
  # /audio/speech documents `voice_id`, and the voices catalogue the
  # picker reads is Mistral-specific, so a stored voice is always a
  # Mistral slug → send `voice_id`. xAI's batch /v1/tts also uses
  # `voice_id` (see `Completion.xai_text_to_speech/3`). OpenRouter /
  # OSS vLLM use `voice` (e.g. "casual_male"). An explicit
  # caller-supplied :voice / :voice_id is never overridden — this only
  # governs the endpoint's stored default.
  #
  # The provider column may hold the bare key ("mistral") or a named
  # connection string ("mistral:my-key") for legacy / pre-V107 rows,
  # so match on the base key rather than an exact string.
  defp voice_field_for(%{provider: provider}) when is_binary(provider) do
    case Endpoint.base_provider(provider) do
      "mistral" -> :voice_id
      "xai" -> :voice_id
      _ -> :voice
    end
  end

  defp voice_field_for(_), do: :voice

  defp log_failed_tts_request(endpoint, text, reason, {source, stacktrace, caller_context, guard}) do
    capture_content = capture_request_content?()

    base_metadata = %{
      error_reason: inspect(reason),
      input_chars: String.length(text),
      # Debug context (source tracking)
      source: source,
      stacktrace: stacktrace,
      caller_context: caller_context
    }

    %{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "tts",
      status: "error",
      user_uuid: caller_context[:user_uuid],
      error_message: error_reason_to_string(reason),
      metadata:
        base_metadata
        |> Map.merge(guard)
        |> maybe_add_content(:input, capture_content, fn -> text end)
    }
    |> with_provider_error()
    |> log_usage()
  end
end
