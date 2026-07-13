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

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Reorder
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Prompt
  alias PhoenixKitAI.Request

  # ===========================================
  # PUBSUB TOPICS
  # ===========================================

  @endpoints_topic "phoenix_kit:ai:endpoints"
  @prompts_topic "phoenix_kit:ai:prompts"
  @requests_topic "phoenix_kit:ai:requests"

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
  """
  @spec subscribe_endpoints() :: :ok | {:error, term()}
  def subscribe_endpoints do
    PubSub.subscribe(@endpoints_topic)
  end

  @doc """
  Subscribes the current process to AI prompt changes.
  """
  @spec subscribe_prompts() :: :ok | {:error, term()}
  def subscribe_prompts do
    PubSub.subscribe(@prompts_topic)
  end

  @doc """
  Subscribes the current process to AI request/usage changes.
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

  defp broadcast_endpoint_change(result, event) do
    case result do
      {:ok, endpoint} ->
        PubSub.broadcast(@endpoints_topic, {event, endpoint})
        {:ok, endpoint}

      error ->
        error
    end
  end

  defp broadcast_prompt_change(result, event) do
    case result do
      {:ok, prompt} ->
        PubSub.broadcast(@prompts_topic, {event, prompt})
        {:ok, prompt}

      error ->
        error
    end
  end

  defp broadcast_request_change(result, event) do
    case result do
      {:ok, request} ->
        PubSub.broadcast(@requests_topic, {event, request})
        {:ok, request}

      error ->
        error
    end
  end

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

  # Unified logger — guarded by Code.ensure_loaded?/1 and rescued so
  # activity failures never crash the primary operation. No-op on hosts
  # without PhoenixKit.Activity available.
  #
  # The `:undefined_table` case is silently skipped: hosts that haven't
  # run the core PhoenixKit migrations yet simply don't have the
  # `phoenix_kit_activities` table, so logging would be noise on every
  # mutation. Any other failure is logged so real bugs aren't hidden.
  defp log_activity(action, resource_type, resource_uuid, opts, extra) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      metadata =
        %{"actor_role" => Keyword.get(opts, :actor_role, "user")}
        |> Map.merge(extra)

      PhoenixKit.Activity.log(%{
        action: action,
        module: "ai",
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        metadata: metadata
      })
    end
  rescue
    e in Postgrex.Error ->
      if Map.get(e.postgres || %{}, :code) == :undefined_table do
        # Host hasn't run the core activity migration yet — silent no-op.
        :activity_log_unavailable
      else
        log_activity_failure(action, e)
      end

    e ->
      log_activity_failure(action, e)
  end

  defp log_activity_failure(action, exception) do
    require Logger

    Logger.warning(
      "[PhoenixKitAI] activity log failed for #{action}: #{Exception.message(exception)}"
    )

    :activity_log_failed
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

  The legacy `api_key` column is NEVER cleared — it stays on each row
  as a safety net. `OpenRouterClient.resolve_api_key/2` prefers
  Integrations, so post-migration endpoints stop firing the legacy
  warning; if Integrations later breaks for any reason, the column
  still has the value and the fallback path keeps working.

  ## Idempotency guards (any one short-circuits)

  - The `ai_legacy_api_key_migration_completed_at` setting is set →
    already ran, skip.
  - ANY `integration:openrouter:*` key already exists in
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

  defp legacy_api_key_migration_completed? do
    Settings.get_setting("ai_legacy_api_key_migration_completed_at", nil) != nil
  rescue
    # Settings table missing in this environment — treat as not completed
    # but the next guard (any_openrouter_integration_exists?) will trip
    # on the same missing infra and we'll skip safely.
    _ -> false
  end

  defp any_openrouter_integration_exists? do
    query =
      from(s in "phoenix_kit_settings",
        where: like(s.key, "integration:openrouter:%"),
        select: count(s.uuid)
      )

    repo().one(query) > 0
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
      "ai_legacy_api_key_migration_completed_at",
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

  Runs both legacy data transitions for AI:

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

  Both kinds log to `PhoenixKit.Activity` per migrated record / group
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

    summary = %{
      credentials_migration: credentials_result,
      reference_migration: references_result
    }

    # Surface inner sweep failures at the outer return shape so the
    # orchestrator (`PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`)
    # can pattern-match on `{:ok, _}` to decide "ran cleanly". Wrapping
    # `:error` inside `{:ok, %{reference_migration: :error}}` would
    # silently swallow the failure for any caller that doesn't drill
    # into the map.
    case references_result do
      :error -> {:error, {:sweep_failed, summary}}
      _ -> {:ok, summary}
    end
  rescue
    e ->
      require Logger

      Logger.warning("[PhoenixKitAI] migrate_legacy/0 raised: #{Exception.message(e)}")

      {:error, e}
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

  defp log_migration_activity(action_atom, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "integration.legacy_migrated",
        module: module_key(),
        mode: "auto",
        resource_type: "endpoint",
        metadata:
          Map.merge(metadata, %{
            "migration_kind" => Atom.to_string(action_atom),
            "actor_role" => "system"
          })
      })
    end

    :ok
  rescue
    _ -> :ok
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
      description: "AI endpoints, prompts, and usage tracking"
    }
  end

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
        redirect_to_first_subtab: true
      },
      %Tab{
        id: :admin_ai_endpoints,
        label: "Endpoints",
        icon: "hero-server-stack",
        path: "ai/endpoints",
        priority: 641,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai
      },
      %Tab{
        id: :admin_ai_prompts,
        label: "Prompts",
        icon: "hero-document-text",
        path: "ai/prompts",
        priority: 642,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai
      },
      %Tab{
        id: :admin_ai_playground,
        label: "Playground",
        icon: "hero-beaker",
        path: "ai/playground",
        priority: 643,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai
      },
      %Tab{
        id: :admin_ai_usage,
        label: "Usage",
        icon: "hero-chart-bar",
        path: "ai/usage",
        priority: 644,
        level: :admin,
        permission: module_key(),
        parent: :admin_ai
      }
    ]
  end

  @impl PhoenixKit.Module
  @dialyzer {:nowarn_function, css_sources: 0}
  @spec css_sources() :: [atom()]
  def css_sources, do: [:phoenix_kit_ai]

  @impl PhoenixKit.Module
  @spec required_integrations() :: [String.t()]
  def required_integrations, do: ["openrouter"]

  @impl PhoenixKit.Module
  @spec version() :: String.t()
  def version, do: "0.11.1"

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
        select: %{endpoint_uuid: r.endpoint_uuid, total: coalesce(sum(r.cost_cents), 0)}
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

  Returns a map of endpoint_uuid => %{request_count, total_tokens, total_cost, last_used_at}
  """
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
            total_cost: coalesce(sum(r.cost_cents), 0),
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
  Resolves an endpoint from an ID (UUID string) or Endpoint struct.

  ## Examples

      {:ok, endpoint} = PhoenixKitAI.resolve_endpoint("019abc12-3456-7def-8901-234567890abc")
      {:ok, endpoint} = PhoenixKitAI.resolve_endpoint(endpoint)
  """
  @spec resolve_endpoint(term()) ::
          {:ok, Endpoint.t()}
          | {:error, :endpoint_not_found | :invalid_endpoint_identifier}
  def resolve_endpoint(id) when is_binary(id) do
    case get_endpoint(id) do
      nil -> {:error, :endpoint_not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  def resolve_endpoint(%Endpoint{} = endpoint), do: {:ok, endpoint}

  def resolve_endpoint(_), do: {:error, :invalid_endpoint_identifier}

  @doc """
  Creates a new AI endpoint.

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
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> repo().insert()
    |> broadcast_endpoint_change(:endpoint_created)
    |> log_endpoint_activity("endpoint.created", opts)
    |> log_failed_endpoint_mutation("endpoint.created", opts)
  end

  @doc """
  Updates an existing AI endpoint.

  Accepts an `:actor_uuid` option so the mutation can be attributed in
  the activity feed. If the change toggles the `enabled` flag an
  additional `endpoint.enabled` / `endpoint.disabled` entry is logged.
  """
  @spec update_endpoint(Endpoint.t(), map(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def update_endpoint(%Endpoint{} = endpoint, attrs, opts \\ []) do
    was_enabled = endpoint.enabled
    changeset = Endpoint.changeset(endpoint, attrs)
    # Skip the activity row when the update is a no-op (no field actually
    # changed). The toggle log keeps its own guard so an enable/disable
    # via a bare `%{enabled: x}` still attributes correctly.
    has_changes = changeset.changes != %{}

    changeset
    |> repo().update()
    |> broadcast_endpoint_change(:endpoint_updated)
    |> maybe_log_endpoint_update(has_changes, opts)
    |> maybe_log_endpoint_toggle(was_enabled, opts)
    |> log_failed_endpoint_mutation("endpoint.updated", opts)
  end

  defp maybe_log_endpoint_update({:ok, _} = result, true, opts) do
    log_endpoint_activity(result, "endpoint.updated", opts)
  end

  defp maybe_log_endpoint_update(result, _has_changes, _opts), do: result

  @doc """
  Deletes an AI endpoint.
  """
  @spec delete_endpoint(Endpoint.t(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def delete_endpoint(%Endpoint{} = endpoint, opts \\ []) do
    repo().delete(endpoint)
    |> broadcast_endpoint_change(:endpoint_deleted)
    |> log_endpoint_activity("endpoint.deleted", opts)
    |> log_failed_endpoint_mutation("endpoint.deleted", opts)
  end

  @doc """
  Returns an endpoint changeset for use in forms.
  """
  @spec change_endpoint(Endpoint.t(), map()) :: Ecto.Changeset.t()
  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
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
    %Prompt{}
    |> Prompt.changeset(attrs)
    |> repo().insert()
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

    changeset
    |> repo().update()
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
  def render_prompt(prompt_uuid, variables \\ %{}) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      Prompt.render(prompt, variables)
    end
  end

  @doc """
  Increments the usage count for a prompt and updates last_used_at.
  """
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
  def ask_with_prompt(endpoint_uuid, prompt_uuid, variables \\ %{}, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, rendered} <- Prompt.render(prompt, variables),
         {:ok, system_prompt} <- Prompt.render_system_prompt(prompt, variables) do
      # Pass prompt info to ask for request logging
      opts_with_prompt =
        opts
        |> Keyword.put(:prompt_uuid, prompt.uuid)
        |> Keyword.put(:prompt_name, prompt.name)

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

  @doc """
  Makes an AI completion with a prompt template as the system message.

  The prompt is rendered and used as the system message, with the user_message
  as the user message.
  """
  def complete_with_system_prompt(endpoint_uuid, prompt_uuid, variables, user_message, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, system_prompt} <- Prompt.render(prompt, variables) do
      # Build messages with system prompt
      messages = [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_message}
      ]

      # Pass prompt info to complete for request logging
      opts_with_prompt =
        opts
        |> Keyword.put(:prompt_uuid, prompt.uuid)
        |> Keyword.put(:prompt_name, prompt.name)

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
  """
  @spec duplicate_prompt(String.t(), String.t()) :: {:ok, Prompt.t()} | {:error, term()}
  def duplicate_prompt(prompt_uuid, new_name) when is_binary(new_name) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      create_prompt(%{
        name: new_name,
        description: prompt.description,
        content: prompt.content,
        enabled: prompt.enabled,
        sort_order: prompt.sort_order,
        metadata: prompt.metadata
      })
    end
  end

  @doc """
  Enables a prompt.
  """
  @spec enable_prompt(String.t()) :: {:ok, Prompt.t()} | {:error, term()}
  def enable_prompt(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      update_prompt(prompt, %{enabled: true})
    end
  end

  @doc """
  Disables a prompt.
  """
  @spec disable_prompt(String.t()) :: {:ok, Prompt.t()} | {:error, term()}
  def disable_prompt(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      update_prompt(prompt, %{enabled: false})
    end
  end

  @doc """
  Gets the variables defined in a prompt.
  """
  def get_prompt_variables(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      {:ok, prompt.variables || []}
    end
  end

  @doc """
  Previews a rendered prompt without making an AI call.
  """
  def preview_prompt(prompt_uuid, variables \\ %{}) do
    render_prompt(prompt_uuid, variables)
  end

  @doc """
  Validates that all required variables are provided for a prompt.
  """
  def validate_prompt_variables(prompt_uuid, variables) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      Prompt.validate_variables(prompt, variables)
    end
  end

  @doc """
  Searches prompts by name, description, or content.
  """
  def search_prompts(query, opts \\ []) when is_binary(query) do
    pattern = "%#{query}%"
    limit = Keyword.get(opts, :limit, 50)

    base_query =
      from(p in Prompt,
        where:
          ilike(p.name, ^pattern) or
            ilike(p.description, ^pattern) or
            ilike(p.content, ^pattern),
        order_by: [asc: p.sort_order, desc: p.inserted_at],
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
  def get_prompts_with_variable(variable_name) when is_binary(variable_name) do
    query =
      from(p in Prompt,
        where: ^variable_name in p.variables,
        order_by: [asc: p.sort_order, desc: p.inserted_at]
      )

    repo().all(query)
  end

  @doc """
  Validates that the content has valid variable syntax.
  """
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
  Resets the usage statistics for a prompt.
  """
  def reset_prompt_usage(prompt_uuid) do
    with {:ok, prompt} <- resolve_prompt(prompt_uuid) do
      prompt
      |> Ecto.Changeset.change(%{usage_count: 0, last_used_at: nil})
      |> repo().update()
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
  updated count + first uuid so the audit feed records the
  drag-to-reorder action without per-row noise. `opts` is forwarded to
  `log_activity/5` so callers can thread `actor_uuid` / `actor_role`.
  """
  @spec reorder_prompts([String.t()], keyword()) :: :ok | {:error, :too_many_uuids}
  def reorder_prompts(ordered_ids, opts \\ []) when is_list(ordered_ids) do
    case Reorder.reorder(Prompt, ordered_ids, :sort_order, repo: repo()) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        first_uuid = Enum.find(ordered_ids, &is_binary/1)

        log_activity(
          "prompt.reordered",
          "prompt",
          first_uuid,
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

  @doc """
  Reorders endpoints based on a list of UUIDs in their new display order.

  Delegates to `PhoenixKit.Utils.Reorder.reorder/4` for the shared
  two-phase index-rewrite primitive. Returns `:ok` on success or
  `{:error, :too_many_uuids}` when the payload exceeds the cap.

  On success, logs one `endpoint.reordered` activity row with the
  actual updated count + first uuid so the audit feed records the
  drag-to-reorder action without per-row noise. `opts` is forwarded
  to `log_activity/5` so callers can thread `actor_uuid` / `mode`.
  """
  @spec reorder_endpoints([String.t()], keyword()) :: :ok | {:error, :too_many_uuids}
  def reorder_endpoints(ordered_ids, opts \\ []) when is_list(ordered_ids) do
    case Reorder.reorder(Endpoint, ordered_ids, :sort_order, repo: repo()) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        first_uuid = Enum.find(ordered_ids, &is_binary/1)

        log_activity(
          "endpoint.reordered",
          "endpoint",
          first_uuid,
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
  - `:since` - Filter by date (requests after this date)
  - `:preload` - Associations to preload

  ## Returns
  `{requests, total_count}`
  """
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
              :cost_cents,
              :status,
              :endpoint_name
            ] do
    order_by(query, [r], [{^dir, field(r, ^field)}])
  end

  defp apply_request_sorting(query, _field, _dir) do
    order_by(query, [r], desc: r.inserted_at)
  end

  @doc """
  Gets a single request by UUID.
  """
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
  def get_request(id) when is_binary(id) do
    if textual_uuid?(id) do
      repo().get_by(Request, uuid: id)
    else
      nil
    end
  end

  def get_request(_), do: nil

  @doc """
  Creates a new AI request record.

  Used to log every AI API call for tracking and statistics.
  """
  def create_request(attrs) do
    %Request{}
    |> Request.changeset(attrs)
    |> repo().insert()
    |> broadcast_request_change(:request_created)
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
    |> maybe_filter_since(Keyword.get(opts, :since))
  end

  defp maybe_filter_by(query, _field, nil), do: query

  defp maybe_filter_by(query, :endpoint_uuid, uuid) when is_binary(uuid) do
    where(query, [r], r.endpoint_uuid == ^uuid)
  end

  defp maybe_filter_by(query, :user_uuid, uuid) when is_binary(uuid) do
    where(query, [r], r.user_uuid == ^uuid)
  end

  defp maybe_filter_by(query, :status, status), do: where(query, [r], r.status == ^status)
  defp maybe_filter_by(query, :model, model), do: where(query, [r], r.model == ^model)

  defp maybe_filter_by(query, :source, source),
    do: where(query, [r], fragment("?->>'source' = ?", r.metadata, ^source))

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, date), do: where(query, [r], r.inserted_at >= ^date)

  @doc """
  Returns filter options for requests (distinct endpoints, models, and sources).
  """
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
      statuses: Request.valid_statuses(),
      sources: repo().all(sources_query)
    }
  end

  # ===========================================
  # STATISTICS
  # ===========================================

  @doc """
  Gets aggregated usage statistics.

  ## Options
  - `:since` - Start date for statistics
  - `:until` - End date for statistics
  - `:endpoint_uuid` - Filter by endpoint

  ## Returns
  Map with statistics including total_requests, total_tokens, success_rate, etc.
  """
  def get_usage_stats(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    total_requests = repo().aggregate(base_query, :count)
    total_tokens = repo().aggregate(base_query, :sum, :total_tokens) || 0
    total_cost = repo().aggregate(base_query, :sum, :cost_cents) || 0
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
      total_cost_cents: total_cost,
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
  """
  @spec complete(String.t() | Endpoint.t(), list(map()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(endpoint_uuid, messages, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, _} <- validate_endpoint(endpoint) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source

      # Extract prompt info if present (from ask_with_prompt, complete_with_system_prompt)
      prompt_info = %{
        prompt_uuid: Keyword.get(opts, :prompt_uuid),
        prompt_name: Keyword.get(opts, :prompt_name)
      }

      merged_opts = merge_endpoint_opts(endpoint, opts)

      case Completion.chat_completion(endpoint, messages, merged_opts) do
        {:ok, response} ->
          log_request(
            endpoint,
            messages,
            response,
            source,
            stacktrace,
            caller_context,
            prompt_info
          )

          {:ok, response}

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

  @doc """
  Simple helper for single-turn chat completion.

  ## Parameters

  - `endpoint_uuid` - Endpoint UUID string or Endpoint struct
  - `prompt` - User prompt string
  - `opts` - Optional parameter overrides and system message

  ## Options

  All options from `complete/3` plus:
  - `:system` - System message string
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

  @doc """
  Makes an embeddings request using a configured endpoint.

  ## Parameters

  - `endpoint_uuid` - Endpoint UUID string or Endpoint struct
  - `input` - Text or list of texts to embed
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

  ## Returns

  - `{:ok, response}` - Response with embeddings
  - `{:error, reason}` - Error atom or tagged tuple.
  """
  @spec embed(String.t() | Endpoint.t(), String.t() | list(String.t()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def embed(endpoint_uuid, input, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, _} <- validate_endpoint(endpoint) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source

      merged_opts = merge_embedding_opts(endpoint, opts)

      case Completion.embeddings(endpoint, input, merged_opts) do
        {:ok, response} ->
          log_embedding_request(endpoint, input, response, source, stacktrace, caller_context)
          {:ok, response}

        {:error, reason} ->
          log_failed_embedding_request(endpoint, reason, source, stacktrace, caller_context)
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

  - `{:ok, %{audio: binary(), format: String.t()}}`
  - `{:error, reason}` - Error atom or tagged tuple.
  """
  @spec speak(String.t() | Endpoint.t(), String.t(), keyword()) ::
          {:ok, %{audio: binary(), format: String.t()}} | {:error, term()}
  def speak(endpoint_uuid, text, opts \\ []) when is_binary(text) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
         {:ok, _} <- validate_endpoint(endpoint) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source

      # Fall back to the endpoint's default voice (stored in
      # provider_settings by the endpoint form) when the caller didn't
      # pass one. TTS has no temperature/dimensions analog, so this is
      # the only endpoint-default merge.
      opts = maybe_put_default_voice(endpoint, opts)

      case Completion.text_to_speech(endpoint, text, opts) do
        {:ok, result} ->
          log_tts_request(endpoint, text, result, source, stacktrace, caller_context)
          {:ok, Map.take(result, [:audio, :format])}

        {:error, reason} ->
          log_failed_tts_request(endpoint, text, reason, source, stacktrace, caller_context)
          {:error, reason}
      end
    end
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
  Extracts usage information from a response.

  ## Examples

      {:ok, response} = PhoenixKitAI.complete(endpoint_uuid, messages)
      usage = PhoenixKitAI.extract_usage(response)
      # => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25}
  """
  defdelegate extract_usage(response), to: Completion

  # Private helpers for completion API

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
    PhoenixKit.Integrations.get_credentials(key)
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
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
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
    capture_content = capture_request_content?()
    normalized = if capture_content, do: normalize_messages(messages), else: nil

    base_metadata = %{
      temperature: endpoint.temperature,
      max_tokens: endpoint.max_tokens,
      # Debug context (source tracking)
      source: source,
      stacktrace: stacktrace,
      caller_context: caller_context
    }

    metadata =
      if capture_content do
        request_payload = %{
          model: endpoint.model,
          messages: normalized,
          temperature: endpoint.temperature,
          max_tokens: endpoint.max_tokens
        }

        Map.merge(base_metadata, %{
          messages: normalized,
          response: response_content,
          response_reasoning: response_reasoning,
          request_payload: request_payload
        })
      else
        Map.put(base_metadata, :content_redacted, true)
      end

    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      prompt_uuid: prompt_info[:prompt_uuid],
      prompt_name: prompt_info[:prompt_name],
      model: endpoint.model,
      request_type: "chat",
      input_tokens: usage.prompt_tokens,
      output_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      cost_cents: usage.cost_cents,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: metadata
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
    capture_content = capture_request_content?()

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
      |> maybe_add_content(:messages, capture_content, fn -> normalize_messages(messages) end)

    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      prompt_uuid: prompt_info[:prompt_uuid],
      prompt_name: prompt_info[:prompt_name],
      model: endpoint.model,
      request_type: "chat",
      status: "error",
      error_message: error_reason_to_string(reason),
      metadata: metadata
    })
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

  # Normalize messages to ensure consistent format for storage
  defp normalize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"]),
        "content" => msg[:content] || msg["content"]
      }
    end)
  end

  defp log_embedding_request(endpoint, input, response, source, stacktrace, caller_context) do
    usage = Completion.extract_usage(response)
    input_count = if is_list(input), do: length(input), else: 1

    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      input_tokens: usage.prompt_tokens,
      total_tokens: usage.total_tokens,
      cost_cents: usage.cost_cents,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: %{
        input_count: input_count,
        dimensions: endpoint.dimensions,
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end

  defp log_failed_embedding_request(endpoint, reason, source, stacktrace, caller_context) do
    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      status: "error",
      error_message: error_reason_to_string(reason),
      metadata: %{
        error_reason: inspect(reason),
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end

  # TTS responses carry no token usage — billing is per-character — so
  # input_tokens/output_tokens/total_tokens/cost_cents stay unset. The
  # host can derive cost from input_chars app-side if needed. The input
  # text is gated by `capture_request_content?/0` like chat/embedding.
  defp log_tts_request(endpoint, text, result, source, stacktrace, caller_context) do
    capture_content = capture_request_content?()

    base_metadata = %{
      input_chars: String.length(text),
      audio_format: result[:format],
      audio_bytes: byte_size(result[:audio]),
      # Debug context (source tracking)
      source: source,
      stacktrace: stacktrace,
      caller_context: caller_context
    }

    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "tts",
      latency_ms: result[:latency_ms],
      status: "success",
      metadata: maybe_add_content(base_metadata, :input, capture_content, fn -> text end)
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
  # Mistral slug → send `voice_id`. OpenRouter / OSS vLLM use `voice`
  # (e.g. "casual_male"), so every other provider stays on `voice`. An
  # explicit caller-supplied :voice / :voice_id is never overridden —
  # this only governs the endpoint's stored default.
  #
  # The provider column may hold the bare key ("mistral") or a named
  # connection string ("mistral:my-key") for legacy / pre-V107 rows,
  # so match on the prefix rather than an exact string.
  defp voice_field_for(%{provider: provider}) when is_binary(provider) do
    if String.starts_with?(provider, "mistral"), do: :voice_id, else: :voice
  end

  defp voice_field_for(_), do: :voice

  defp log_failed_tts_request(endpoint, text, reason, source, stacktrace, caller_context) do
    capture_content = capture_request_content?()

    base_metadata = %{
      error_reason: inspect(reason),
      input_chars: String.length(text),
      # Debug context (source tracking)
      source: source,
      stacktrace: stacktrace,
      caller_context: caller_context
    }

    create_request(%{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "tts",
      status: "error",
      error_message: error_reason_to_string(reason),
      metadata: maybe_add_content(base_metadata, :input, capture_content, fn -> text end)
    })
  end
end
