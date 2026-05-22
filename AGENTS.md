# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit AI module — provides AI endpoint management, prompt templates, completions, and usage tracking via three OpenAI-compatible providers (OpenRouter, Mistral, DeepSeek). Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

The provider list lives in `Endpoint.provider_options/0` (form dropdown), `Endpoint.default_base_url/1` (per-provider URL defaults), and `Endpoint.@valid_providers` (changeset's `validate_inclusion`). Adding a fourth provider is a 4-line edit + a core providers.ex entry. See "Multi-provider support" below for the current shape.

## What This Module Does NOT Have (by design)

The omissions below are deliberate so consumers and future contributors don't expect them.

- **No DB migrations of its own** — every table this module owns (`phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts`, `phoenix_kit_ai_requests`) is created by versioned migrations in core `phoenix_kit` (V40+ for `uuid_generate_v7()`, V57+ for the AI tables). Adding a column is a core migration first, then schema + changeset edits here.
- **No per-completion activity logging** — `PhoenixKit.Activity.log/1` is invoked only on endpoint/prompt CRUD + enable/disable toggles. Per-request usage already lives in `phoenix_kit_ai_requests` with token/cost/latency columns; mirroring it into `phoenix_kit_activities` would double-write the same audit trail.
- **No forced data migration for legacy `endpoint.api_key`** — `OpenRouterClient.resolve_api_key/1` keeps pre-Integrations endpoints working via a 3-tier fallback chain (`integration_uuid` → legacy `provider` string → raw `api_key` column) with a per-call `Logger.warning` only when it actually falls all the way through to the column. Operators can migrate at their own pace through the UI (an explicit save with an integration picked atomically clears the legacy column), OR opt in to the orchestrated migrators by calling `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from `Application.start/2`. The orchestrator invokes `migrate_legacy/0` on every registered module — for AI that runs both the api_key→Integration credentials migration (atomic clear of the legacy column on success) AND the provider-string→integration_uuid reference sweep, with activity-log emissions per migrated record. See "Migrating from legacy `endpoint.api_key`" below.
- **No public HTTP / API surface** — AI is admin-only. No JSON endpoints, no webhook receivers, no socket forwards. Consumers wire AI completions into their own host code via the `PhoenixKitAI` context module.
- **No background jobs (Oban)** — completions run synchronously from the calling LiveView (`Playground.handle_info(:do_send, …)`) so the user sees the response inline. Long-running batch generation belongs in the consumer app, not here.
- **No streaming responses** — `Completion` returns the full `{:ok, response}` shape; OpenRouter's SSE streaming endpoint isn't surfaced. The Playground UI is request/response, not chat-stream.
- **No Errors-module truncation helper** — error messages from the OpenRouter API come back as short JSON strings, so `Errors.message/1` doesn't include a `truncate_for_log/2` style cap. The few Logger calls that take API response bodies (`completion.ex`, `openrouter_client.ex`) format them inline; if a future provider returns multi-KB error blobs, add a truncation helper then.

## Common Commands

### Setup & Dependencies

```bash
mix deps.get                # Install dependencies
```

### Testing

```bash
mix test                                            # Run all tests
mix test test/phoenix_kit_ai_test.exs               # Specific file
mix test test/phoenix_kit_ai/completion_test.exs:25 # Specific test by line
createdb phoenix_kit_ai_test                        # Create test DB (first time)
```

Without the test database, integration tests (anything using `PhoenixKitAI.DataCase`) are automatically excluded and unit tests still run.

### Code Quality

```bash
mix format                  # Format code (imports Phoenix LiveView rules)
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
mix docs                    # Generate documentation
```

## Dependencies

This is a **library** (not a standalone Phoenix app) — in production the host app provides the endpoint and router. The `config/` directory exists only for test infrastructure (`config/test.exs` wires up `PhoenixKitAI.Test.Repo` and `PhoenixKitAI.Test.Endpoint`). The full dependency chain:

- `phoenix_kit` (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Activity logging, Integrations
- `phoenix_live_view` — Web framework (LiveView UI)
- `req` (via phoenix_kit) — HTTP client for chat completions, embeddings, and `/models` discovery across all three providers
- `jason` (via phoenix_kit) — JSON encoding/decoding
- `lazy_html` (`:test` only) — HTML assertions in `Phoenix.LiveViewTest`

## Architecture

This is a **PhoenixKit module** that implements the `PhoenixKit.Module` behaviour. It depends on the host PhoenixKit app for Repo, Endpoint, and Settings.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional admin routes (new/edit/usage) via `admin_routes/0`
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`
7. API keys are managed centrally via `PhoenixKit.Integrations`. Each endpoint pins to a specific integration row by uuid in `endpoint.integration_uuid` (added in core's V107 migration with backfill from the legacy `provider` string column). The form's picker filters connections to whichever provider is currently selected on the dropdown — see "Multi-provider support" below. The module declares `required_integrations: ["openrouter"]` because the original wired provider was OpenRouter; Mistral / DeepSeek are additionally supported but not required for the module to run.

### Key Modules

- **`PhoenixKitAI`** (`lib/phoenix_kit_ai.ex`) — Main module implementing `PhoenixKit.Module` behaviour AND serving as the context module for all AI operations (endpoints, prompts, requests, completions).

- **`PhoenixKitAI.Endpoint`** (`lib/phoenix_kit_ai/endpoint.ex`) — Ecto schema for AI endpoint configurations (provider credentials, model, generation parameters).

- **`PhoenixKitAI.Prompt`** (`lib/phoenix_kit_ai/prompt.ex`) — Ecto schema for reusable prompt templates with `{{Variable}}` substitution.

- **`PhoenixKitAI.Request`** (`lib/phoenix_kit_ai/request.ex`) — Ecto schema for request logging (tokens, cost, latency, status).

- **`PhoenixKitAI.Errors`** (`lib/phoenix_kit_ai/errors.ex`) — Maps error atoms returned from the API layer (`:endpoint_not_found`, `:invalid_api_key`, etc.) to translated strings via gettext. UI surfaces errors via `Errors.message/1` so business logic stays locale-agnostic.

- **`PhoenixKitAI.Completion`** (`lib/phoenix_kit_ai/completion.ex`) — HTTP client for chat completions and embeddings. Provider-agnostic: builds `<endpoint.base_url>/chat/completions` and `<endpoint.base_url>/embeddings` URLs, so OpenRouter / Mistral / DeepSeek all flow through the same path. When `endpoint.base_url` is missing it falls back through `Endpoint.default_base_url(endpoint.provider)` rather than a hardcoded OpenRouter URL — silent misrouting of Mistral / DeepSeek traffic to openrouter.ai is a real failure mode for legacy rows persisted before the changeset gained `maybe_set_default_base_url`. If neither resolves, raises `ArgumentError` instead of misrouting. Also exposes `extract_content/1` and `extract_reasoning/1` for parsing responses (the latter normalises three known field names — `reasoning`, `reasoning_content`, `thinking` — into one return value).

- **`PhoenixKitAI.OpenRouterClient`** (`lib/phoenix_kit_ai/openrouter_client.ex`) — API key validation, model discovery, header building. Despite the name (kept for git-history continuity) the module is now generic across OpenRouter / Mistral / DeepSeek: `fetch_models/2` and `fetch_models_grouped/2` accept a `:base_url` opt that overrides the OpenRouter default, and a `:fallback_provider` opt that groups slash-less model IDs (Mistral's `mistral-large-latest`, DeepSeek's `deepseek-chat`) under a single key. Credentials are resolved from `PhoenixKit.Integrations` via the endpoint's `integration_uuid` field with a 3-tier fallback ladder (uuid → legacy `provider` → legacy `api_key` column) — see "Migrating from legacy `endpoint.api_key`" below.

- **`PhoenixKitAI.AIModel`** (`lib/phoenix_kit_ai/ai_model.ex`) — Normalized struct for OpenRouter model data.

- **`PhoenixKitAI.Routes`** (`lib/phoenix_kit_ai/routes.ex`) — Route module providing admin sub-routes (new/edit forms, usage page). Auto-discovered and compiled into PhoenixKit's `live_session :phoenix_kit_admin` — never hand-register these routes in the parent app's `router.ex`. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative admin routing reference.

- **`PhoenixKitAI.Web.*`** (`lib/phoenix_kit_ai/web/`) — Admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground.

### Activity Logging Pattern

Every mutating context function logs via `PhoenixKit.Activity.log/1`, guarded with `Code.ensure_loaded?/1` + `rescue` so logging failures never crash the primary operation. Mutating functions accept an `opts \\ []` keyword list; LiveViews extract the current user UUID via a private `actor_opts/1` helper.

The internal helper takes resource type + UUID directly (rather than a struct) so both success-path callers (with a saved `Endpoint`/`Prompt`) and failure-path callers (with only an `Ecto.Changeset`) can share the same logger:

```elixir
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
  e in Postgrex.Error -> ...    # silent on :undefined_table; Logger.warning otherwise
  e -> log_activity_failure(...)
end
```

Current logged actions (success path AND failure path — both branches log so an admin click survives a DB outage / validation rejection in the audit feed):

| Action | When | Failure-branch metadata |
|--------|------|-------------------------|
| `endpoint.created` | `create_endpoint/2` | `db_pending: true`, `error_keys: [...]` |
| `endpoint.updated` | `update_endpoint/3` (skipped on no-op `changeset.changes == %{}`) | `db_pending: true`, `error_keys: [...]` |
| `endpoint.deleted` | `delete_endpoint/2` | `db_pending: true`, `error_keys: [...]` |
| `endpoint.enabled` / `endpoint.disabled` | `update_endpoint/3` with a flipped `enabled` field | n/a (toggle has its own guard) |
| `prompt.created` | `create_prompt/2` | `db_pending: true`, `error_keys: [...]` |
| `prompt.updated` | `update_prompt/3` (skipped on no-op `changeset.changes == %{}`) | `db_pending: true`, `error_keys: [...]` |
| `prompt.deleted` | `delete_prompt/2` | `db_pending: true`, `error_keys: [...]` |
| `prompt.enabled` / `prompt.disabled` | `update_prompt/3` with a flipped `enabled` field | n/a |

Failure-branch logging is wired via `log_failed_endpoint_mutation/3` and `log_failed_prompt_mutation/3` pipe-step helpers — they no-op on `{:ok, _}` and write a `db_pending: true` audit row with PII-safe metadata (`error_keys` is the list of failed validation key NAMES, never the rejected values).

Individual AI completion requests are **not** logged to Activity; they already have dedicated rows in `phoenix_kit_ai_requests` for usage tracking.

### Settings Keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `ai_enabled` | boolean | `false` | Module enable/disable toggle |

Application env (not Settings table):

| Key | Default | Purpose |
|-----|---------|---------|
| `config :phoenix_kit_ai, :capture_request_content` | `true` | Persist user message + assistant response content in request `metadata` JSONB. Default preserves the shipped debugging shape; deployments with PII / data-retention obligations can set to `false`, which writes `metadata.content_redacted: true` in place of `messages` / `response` / `request_payload`. Token counts, latency, model, and cost are still recorded. |
| `config :phoenix_kit_ai, :capture_request_memory` | `false` | Opt-in `:memory` capture per request. Keep off unless actively debugging memory issues; every request otherwise carries the memory snapshot in its JSONB metadata. |
| `config :phoenix_kit_ai, :allow_internal_endpoint_urls` | `false` | Bypass the SSRF guard on `Endpoint.base_url` (which rejects loopback / RFC1918 / link-local / `*.local` / non-http(s)). Required for self-hosted Ollama / intranet inference; off in production by default. |
| `config :phoenix_kit_ai, :embedding_models` | `[]` | User-contributed embedding models appended to the built-in list in `OpenRouterClient.fetch_embedding_models/2`. Non-list values log a warning and are ignored. |
| `config :phoenix_kit_ai, :req_options` | `[]` | Optional `Req` opts appended to every HTTP call site (`OpenRouterClient.http_get/2`, `Completion.http_post/3`). Used by tests to route HTTP through `Req.Test` plug stubs (`plug: {Req.Test, MyStub}`); production default is `[]`, behaviour unchanged. |

### File Layout

```
lib/phoenix_kit_ai.ex                    # Main module (behaviour + context)
lib/phoenix_kit_ai/
├── ai_model.ex                          # Normalised OpenRouter model struct
├── completion.ex                        # OpenRouter HTTP client
├── endpoint.ex                          # Endpoint schema
├── errors.ex                            # Atom → translated error string
├── openrouter_client.ex                 # API key + model discovery
├── prompt.ex                            # Prompt template schema
├── request.ex                           # Request logging schema
├── routes.ex                            # Admin sub-routes
└── web/
    ├── endpoint_form.ex / .heex         # Create/edit endpoint
    ├── endpoints.ex / .heex             # List + usage dashboard
    ├── playground.ex / .heex            # Live testing
    ├── prompt_form.ex / .heex           # Create/edit prompt
    └── prompts.ex / .heex               # Prompt list
```

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"ai"`
- **Tab IDs**: prefixed with `:admin_ai_` (e.g., `:admin_ai_endpoints`)
- **URL paths**: use hyphens, not underscores (`"ai/endpoints"`)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **LiveViews use `PhoenixKitWeb` macros** — use `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView` directly); this also imports Gettext automatically
- **JavaScript hooks**: must be inline `<script>` tags; register on `window.PhoenixKitHooks`
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Cost precision**: Costs stored in nanodollars (1/1,000,000 USD) in the `cost_cents` field for precision with cheap API calls
- **Error returns**: public functions return atoms or `{atom, detail}` tuples, not raw strings. UI surfaces them via `PhoenixKitAI.Errors.message/1`. See README for the full atom set.
- **Translatable strings**: every user-visible string goes through `gettext(...)`. Feature modules never own `.po` files — translations live in core `phoenix_kit`.

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Routing: Single Page vs Multi-Page

> ⚠️ **Never hand-register plugin LiveView routes in the parent app's `router.ex`.** PhoenixKit injects module routes into its own `live_session :phoenix_kit_admin` automatically. A hand-written route sits outside that session, which (a) loses the admin layout — `:phoenix_kit_ensure_admin` only applies it inside the session — and (b) crashes the socket on navigation between admin pages.

The AI module uses the **multi-page route-module pattern**: `route_module/0` returns `PhoenixKitAI.Routes`, which defines `admin_routes/0` and `admin_locale_routes/0`. Sub-routes like `/endpoints/new`, `/endpoints/:uuid/edit`, and `/prompts/:uuid/edit` live there.

Top-level tabs (Endpoints, Prompts, Playground, Usage) are declared in `admin_tabs/0` in `lib/phoenix_kit_ai.ex`. Each tab targets a LiveView via `live_view: {Module, :action}`.

### How route discovery works

Module routes are auto-discovered at compile time — no manual registration needed:

1. `use PhoenixKit.Module` persists a `@phoenix_kit_module` marker in the `.beam` file
2. PhoenixKit's `ModuleDiscovery` scans beam files of deps that depend on `:phoenix_kit`
3. Admin routes (`admin_routes/0`, `admin_locale_routes/0`) and tab routes are compiled into the host router via the `phoenix_kit_routes()` macro
4. The host router auto-recompiles when module deps are added or removed

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_ai]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Database & Migrations

This module has **no migrations of its own**. All three tables are created by the parent `phoenix_kit` project as versioned migrations (see `phoenix_kit/lib/phoenix_kit/migrations/postgres/` in core).

Tables owned by this module:

- `phoenix_kit_ai_endpoints` — Endpoint configurations (UUIDv7 PK)
- `phoenix_kit_ai_prompts` — Prompt templates (UUIDv7 PK)
- `phoenix_kit_ai_requests` — Request logs for usage tracking (UUIDv7 PK, FK to endpoints/prompts/users)

## Multi-provider support

Three OpenAI-compatible providers wired into the endpoint form:

| Provider key | Default base URL | `provider_label/1` | Notes |
|---|---|---|---|
| `"openrouter"` | `https://openrouter.ai/api/v1` | "OpenRouter" | Aggregator; ~100 chat models with rich pricing/modality metadata. `/models` does NOT include embeddings — see curated list in `OpenRouterClient.builtin_embedding_models/0` |
| `"mistral"` | `https://api.mistral.ai/v1` | "Mistral" | Native Mistral API. `/v1/models` returns chat AND embedding models in one list (`mistral-embed`, `codestral-embed`); operators pick the right id manually |
| `"deepseek"` | `https://api.deepseek.com/v1` | "DeepSeek" | Native DeepSeek API. `/models` returns chat models (`deepseek-chat`, `deepseek-reasoner`). Reasoner emits chain-of-thought — see "Reasoning capture" below |

**Provider definitions** live in core's `PhoenixKit.Integrations.Providers`
registry (built-in: `google`, `microsoft`, `openrouter`, `mistral`,
`deepseek`). Each entry declares its auth_type (all three AI providers
are `:api_key`), validation URL (used by Settings → Integrations'
"Test Connection" button), setup_fields, and instruction copy for the
collapsible "Setup Instructions" panel.

**Adding a fourth AI provider** requires four edits in this module
(plus a core providers.ex entry):

1. `Endpoint.@valid_providers ~w(openrouter mistral deepseek <new>)`
2. `Endpoint.provider_options/0` — append `{"<Display>", "<key>"}` tuple
3. `Endpoint.default_base_url/1` — clause returning the provider's
   `<base>/v1` URL
4. `Endpoint.provider_label/1` — clause returning brand name (kept
   un-translated by design — see the doc on that function)

The form's picker filter, model fetcher, base_url resolution, and
chat completion path are all already provider-agnostic. The fourth
provider works without further code changes provided its API is
OpenAI-compatible at `<base_url>/chat/completions` and `/models`.

### Form picker — reflects current provider, never auto-picks

The picker filters connections to whichever provider is currently
selected on the dropdown. Switching providers (e.g. OpenRouter →
Mistral) clears any selected integration, the model list, the
`selected_model` assign, the `model` form param, AND empties
`base_url` so the changeset's `maybe_set_default_base_url/1` picks up
the new provider's default URL. Both `model` and `base_url` are
cleared with `""` rather than `nil` because the form template's
fallback (`@form.params["model"] || @endpoint.model`) treats `nil`
as "no intent" and falls through to the saved value — `""` is truthy
in Elixir, so the `||` short-circuits there and the display reflects
the cleared state. The picker NEVER auto-selects a single available
connection — even when only one exists, the operator must pick
explicitly so the form's display matches the endpoint's actual
stored state. See "Picker reflects state, never auto-picks" below
for the policy rationale.

### Dynamic model selector

`OpenRouterClient.fetch_models_grouped/2` accepts two opts that make
it provider-agnostic:

- `:base_url` — overrides the hardcoded OpenRouter URL when set. Lets
  the same fetch logic hit Mistral / DeepSeek `/models` endpoints
  without forking the code.
- `:fallback_provider` — group key for IDs that don't follow
  OpenRouter's `provider/model` slash convention. Mistral's
  `"mistral-large-latest"` and DeepSeek's `"deepseek-chat"` lack the
  slash; without this, each model would land in its own one-off group
  (the picker would render dozens of single-model groups).

`Web.EndpointForm.current_models_base_url/1` resolves the URL: prefers
the saved endpoint's `base_url` (in case the operator overrode it),
falls back to the schema default for the currently-selected provider,
then to OpenRouter's URL as a last resort. Necessary because new
endpoints don't have a saved `base_url` yet — the form-side
`current_provider` assign is the source of truth.

`OpenRouterClient.@timeout` is 15s for `/models` and `/auth/key`
traffic — both are lightweight metadata endpoints. Chat completions
have their own 120s budget in `Completion.chat_completion/3`.

### Loading-state UX

`Web.EndpointForm` tracks four assigns through the model-fetch
lifecycle: `models_loading`, `models_loading_slow`, `models_error`,
and `model_fetch_slow_timer`. Two private helpers
(`start_model_fetch_indicators/1`, `stop_model_fetch_indicators/1`)
consolidate the lifecycle plumbing across all five entry points
that initiate or complete a fetch.

- 10s after the fetch starts, a `:model_fetch_slow` `handle_info`
  fires and flips `models_loading_slow` so the spinner gains a
  "(taking longer than usual — the provider may be slow)" hint. The
  handler is idempotent — if the fetch already completed it's a
  no-op.
- On failure, the error pane gets a Retry button (the new
  `"retry_model_fetch"` event) when the integration is still
  connected. Re-fires `:fetch_models_from_integration` with the same
  active connection so the operator can recover from a transient
  upstream error (5xx, timeout, rate-limit) without re-picking.

### Reasoning capture

Reasoning models (DeepSeek-R1, Mistral Magistral, OpenAI o-series,
Anthropic extended thinking) return their chain-of-thought alongside
the final answer. `Completion.extract_reasoning/1` walks three known
field-name shapes and returns the first non-empty binary it finds:

| Provider / shape | Field on `message` |
|---|---|
| OpenRouter (and what it proxies) | `reasoning` |
| DeepSeek native API | `reasoning_content` |
| Some others | `thinking` |

The extracted trace is persisted to
`phoenix_kit_ai_requests.metadata.response_reasoning` (in
`PhoenixKitAI.log_request/7`) and rendered in the admin Usage page's
request-details modal as a collapsible "Reasoning" section
(collapsed by default — chains-of-thought routinely run 5-50× the
length of the answer).

Subject to the same `capture_request_content?/0` privacy gate as
`response` content — when content capture is off, reasoning is
dropped too. Reasoning can mirror prompt content and is
PII-equivalent.

## Pinning endpoints to a specific integration

Each AI endpoint references a specific `PhoenixKit.Integrations`
connection by uuid via the `integration_uuid` column (added in core's
V107 with backfill from existing `provider` strings). The form's
`integration_picker` writes the chosen connection's uuid into
`integration_uuid` on save; `OpenRouterClient.resolve_api_key/1` looks
up credentials by that uuid at request time — no guessing, no
per-provider fallback.

Provider-string-or-uuid resolution converges on
`PhoenixKit.Integrations.resolve_to_uuid/1` (core primitive added in
the strict-UUID flip). Both `OpenRouterClient.lookup_uuid_for_provider/1`
(lazy on-read promotion) and `PhoenixKitAI.resolve_provider_to_uuid/1`
(V107 migration sweep) delegate to it — single regex + dispatch +
provider:name split lives in core, no duplication in this module.

Renaming or re-validating the integration on the admin side doesn't
break the endpoint's reference: uuids are stable across renames
(`PhoenixKit.Integrations.rename_connection/3` updates the storage
row's `key` column in place).

## Migrating from legacy `endpoint.api_key`

Endpoints created before V107 / PR #3 stored the OpenRouter API key
directly in the `api_key` column and used the bare `provider` field
(`"openrouter"`) without a specific connection reference. V107's
backfill stamps `integration_uuid` for any endpoint whose `provider`
matches a `PhoenixKit.Integrations` row (exact match for
`"openrouter:my-key"` shapes, most-recently-validated row for bare
`"openrouter"` strings). Endpoints with no resolvable integration get
NULL — `resolve_api_key/1` falls back to the legacy `api_key` column
and logs a `Logger.warning` identifying the endpoint by name + UUID.

### Recovery card for stuck migrations

When the legacy `api_key` is populated but `integration_uuid` is
still NULL (V107 couldn't match, or `migrate_legacy/0` didn't reach
this endpoint), the endpoint edit form renders a "Legacy API key
(recovery)" card under the integration picker. Read-only, with a
copy button. Lets the operator recover the key and paste it into a
new Integration without bouncing back to OpenRouter. The card
disappears once an integration is selected and saved.

### Picker reflects state, never auto-picks

The integration picker is a status display, not a convenience
shortcut. `load_endpoint/2` and `reload_connections/1` only set
`active_connection` to a uuid the endpoint is actually pinned to —
either via `integration_uuid` or via the legacy `provider` field
when it carried the uuid pre-V107. If nothing is pinned, the picker
shows no selection, even when only one connection exists. This
keeps the form honest: an operator scanning a new endpoint sees
"no integration set" and knows to pick one, instead of being misled
by a single available connection rendering as already-selected.

When `integration_uuid` is set but doesn't resolve to a current
connection (the integration was deleted since the endpoint was
wired up), the orphaned uuid flows through `:selected_uuids` to the
picker, which renders its "Integration deleted — Missing" warning
card. The operator has to explicitly pick a new connection. The
same logic protects `reload_connections/1` against silently
rebinding endpoints when integrations are added or removed via
PubSub.

### Endpoints list — connection-health badges + integration row

The endpoint card surfaces three independent signals:

1. **Enabled badge** (`Active` / `Disabled`) — config state, derived
   from `endpoint.enabled`.
2. **Health badge** — derived from `integration_uuid` lookup against
   the per-render `integrations_by_uuid` map. Surfaces:
   - `Integration missing` (red) — uuid set but doesn't resolve
   - `Integration error` (red) — resolves with `status="error"`
   - `Not connected` (yellow) — resolves but never reached `connected`
   - `No integration` (yellow) — `integration_uuid` is nil
   - (no badge) — connected and healthy
3. **Integration + key row** — `🔗 Integration: <name>  🔑 Key: sk-or-v1…abcd`.
   Mask format is first-8 + last-4 via
   `PhoenixKitAI.Web.Endpoints.mask_api_key/1`. Short keys (< 14
   chars) fully mask to `•••` to avoid leaking most of a short
   secret. For orphaned endpoints the row reads "Integration:
   Deleted, Key: —"; for endpoints with `integration_uuid: nil`,
   it reads "Integration: none, Key: —".

The `integrations_by_uuid` map is loaded once per render in
`reload_endpoints/1` so per-endpoint rendering doesn't N+1 on
`Integrations.connected?/1` or `get_credentials/1`.

### Manual cleanup flow

To clear the legacy warning for a stuck endpoint:

1. Open Settings → Integrations and add an OpenRouter connection (or
   reuse the legacy key copied from the recovery card).
2. Edit the endpoint in the AI admin UI and select the connection
   from the `integration_picker`. The form writes the connection's
   uuid into `integration_uuid`.
3. Save. `Endpoint.changeset/2`'s `maybe_clear_legacy_api_key/1`
   wipes the legacy `api_key` column to `""` in the same DB write
   (atomic with the integration_uuid set). The warning stops, the
   recovery card disappears, and stays gone.

The `api_key` column is retained in the schema so a manual DB
recovery is still possible if something goes catastrophically wrong;
the *value* is cleared post-migration. The column is flagged
**Deprecated** in `PhoenixKitAI.Endpoint` — planned for removal in a
future major version.

### Auto-migrating at host-app boot

The recommended boot-time entry point is the orchestrator:

```elixir
# In your host app's Application.start/2, after the Repo + supervisor children
def start(_type, _args) do
  children = [...]
  result = Supervisor.start_link(children, opts)

  # Walks every registered PhoenixKit.Module and calls its
  # `migrate_legacy/0` callback. Idempotent — safe every boot.
  # Per-module errors are caught + logged; never crashes boot.
  PhoenixKit.ModuleRegistry.run_all_legacy_migrations()

  result
end
```

For AI specifically, `PhoenixKitAI.migrate_legacy/0` is the callback. It runs both kinds of legacy data migration AI may need:

1. **Credentials migration** (`run_legacy_api_key_migration/0` underneath) — folds pre-Integrations endpoints' api_keys into named `PhoenixKit.Integrations` connections AND stamps `endpoint.integration_uuid` to point at the new row.
2. **Reference sweep** (`provider`-string → `integration_uuid`) — endpoints whose `provider` field is already a `provider:name` reference (form-saves between PR #3 and V107, or new endpoints created against an older form) get their `integration_uuid` resolved and persisted.

Both kinds emit `PhoenixKit.Activity` entries with `action: "integration.legacy_migrated"`, `mode: "auto"`, and PII-safe metadata (uuid, count, kind — never api_key values).

Calling the underlying functions directly is still supported for ad-hoc operations, but the orchestrator is the single entry point that future-proofs against new modules adding their own `migrate_legacy/0` callbacks.

What the credentials pass does:

- Finds endpoints with `provider == "openrouter"` (the bare default — never named connections like `"openrouter:my-key"`) AND a non-empty `api_key`.
- Groups them by api_key value (so endpoints sharing a key share one connection — dedup).
- For each group: creates a `PhoenixKit.Integrations` connection via `add_connection/3`, writes the key into the integration row via `save_setup(uuid, attrs)`, then atomically updates each endpoint's `provider`, `integration_uuid`, AND clears `api_key` to `""` in a single `Repo.update_all`. Naming: `"openrouter:default"` for single-key deployments; `"openrouter:imported-1"`, `"openrouter:imported-2"` for multi-key deployments.
- **Clears the legacy `api_key` column atomically with linking** — once the credential is in the integration row and the endpoint references it by uuid, the duplicate column would only rot. The runtime resolver (`OpenRouterClient.build_headers_from_endpoint/1`) takes the `integration_uuid` path; with `api_key = ""` the legacy fallback tier returns `:not_configured`, so a broken integration surfaces a loud error instead of silently coasting on a stale key.
- *Un*-migrated endpoints (skipped by the where-clause filter, or skipped because of an idempotency gate) keep their `api_key` populated as a safety net until they're explicitly handled.

Idempotency guards (any one short-circuits):

- The `ai_legacy_api_key_migration_completed_at` setting is set → skip.
- ANY `integration:openrouter:*` key already exists in `phoenix_kit_settings` (operator already set up Integrations manually) → mark complete and skip.
- No endpoints need migrating → mark complete and skip.
- Plus the where-clause filter (`api_key != ""`) makes re-runs safe — already-migrated endpoints have an empty `api_key` and are invisible to subsequent passes.

Failure modes are contained: a top-level `try/rescue/catch :exit` shell ensures the migration never crashes host-app boot. Per-key-group operations are isolated — one bad group doesn't abort others. Partial migration is safe because un-migrated endpoints still have their `api_key` populated and resolve via the legacy fallback path; only successfully-migrated endpoints have the fallback removed.

The migration is opt-in (you must call it explicitly). Operators who prefer to migrate manually via the admin UI can simply not call the function — the resolver's legacy fallback path keeps existing endpoints working indefinitely.

## Testing

### Running tests

```bash
mix test                                        # All tests
mix test test/phoenix_kit_ai_test.exs           # Behaviour-compliance
mix test test/phoenix_kit_ai/                   # Unit + integration
mix test test/phoenix_kit_ai/web/               # LiveView tests
```

### Test infrastructure

Two levels of tests:

1. **Unit tests** — Pure logic, no DB required, always run. Examples: `errors_test.exs`, `prompt_test.exs` (extract/render helpers), `completion_test.exs` (HTTP error parsers).
2. **Integration tests** — Real PostgreSQL via Ecto sandbox; auto-excluded when the DB is unavailable. Tests using `PhoenixKitAI.DataCase` or `PhoenixKitAI.LiveCase` are **automatically tagged `:integration`**. Examples: `endpoint_test.exs`, `request_test.exs`, `openrouter_client_coverage_test.exs`, `activity_logging_test.exs`, `legacy_api_key_migration_test.exs`, all `web/*_test.exs` files.

The test DB (`phoenix_kit_ai_test`) uses an embedded `PhoenixKitAI.Test.Repo` in `test/support/test_repo.ex`. Schema setup happens in `test/test_helper.exs` by running core's versioned migrations directly (`Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, all: true, log: false)`) — same call the host app makes in production. No module-owned DDL anywhere.

LiveView tests need a minimal test Endpoint + Router + Layouts + LiveCase — see `test/support/`:

- `test/support/test_endpoint.ex`, `test_router.ex`, `test_layouts.ex` — minimal Phoenix endpoint/router/layout stack for `Phoenix.LiveViewTest.live/2`
- `test/support/live_case.ex` — `PhoenixKitAI.LiveCase` with `fixture_endpoint/1`, `fixture_prompt/1`, `seed_openrouter_connection/2`, `fake_scope/1`, `put_test_scope/2`
- `test/support/data_case.ex` — `PhoenixKitAI.DataCase` (`:integration` auto-tag, sandbox setup)
- `test/support/hooks.ex` — `:assign_scope` `on_mount` hook so tests can inject a `phoenix_kit_current_scope` / `phoenix_kit_current_user` via session
- `test/support/activity_log_assertions.ex` — `assert_activity_logged/2` / `refute_activity_logged/2` querying `phoenix_kit_activities` directly

The router scopes at `/en/admin/ai/…` so admin paths receive the default locale. `lazy_html` is a `:test`-only dep for rendered-HTML assertions.

Destructive rescue tests (DROP-TABLE-in-sandbox to exercise rescue branches) live in `test/phoenix_kit_ai/destructive_rescue_test.exs` (`async: false`). They use `:integration` like every other DB-bound test; the LV-mounted save_endpoint rescue test is additionally tagged `:destructive` and is opt-in via `--include destructive` because it mounts a LiveView and drops a table mid-handler.

### Version compliance test

`test/phoenix_kit_ai_test.exs` verifies `module_key/0`, `module_name/0`, `version/0`, `permission_metadata/0`, `admin_tabs/0`, and `css_sources/0` return expected types/shapes.

## Versioning & Releases

This project follows [Semantic Versioning](https://semver.org/).

### Version locations

The version must be updated in **three places** when bumping:

1. `mix.exs` — `@version` module attribute
2. `lib/phoenix_kit_ai.ex` — `def version, do: "x.y.z"`
3. `test/phoenix_kit_ai_test.exs` — version compliance test

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-24" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_ai.ex` (`version/0`), and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pre-commit Commands

Always run before git commit:

```bash
mix precommit   # compile + format + credo --strict + dialyzer
```

## Pull Requests

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `PINCER_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

`FOLLOW_UP.md` is added to every PR folder once the review has been triaged — even PRs with no findings get a stub so an absence of `FOLLOW_UP.md` in a PR folder means "not triaged yet".

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Activity logging, Integrations
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **Req** (via PhoenixKit) — HTTP client for OpenRouter API calls
- **Jason** (via PhoenixKit) — JSON encoding/decoding
- **lazy_html** (`:test` only) — Rendered-HTML assertions in LiveView tests

## Two Module Types

- **Full-featured** (this module): Admin tabs, routes, UI, settings, LiveViews, real DB tables (migrations live in core `phoenix_kit`, not here)
- **Headless**: Functions/API only, no UI — still gets auto-discovery, toggles, and permissions

`phoenix_kit_ai` is full-featured.

## Future refactor opportunities

Items deliberately deferred — surface them when an unrelated refactor naturally touches the same code, not as standalone work.

### `metadata.error_reason` shape

`log_failed_request/7` and `log_failed_embedding_request/5` (`lib/phoenix_kit_ai.ex`) currently store the failure reason in `metadata.error_reason` via `inspect/1`. So a tagged tuple like `{:connection_error, :nxdomain}` lands in the JSONB column as the string `"{:connection_error, :nxdomain}"`. The original `error_message` column still holds the human-readable, gettext-rendered message via `Errors.message/1` — this is just the machine-readable shadow.

The string form works for ad-hoc grep, but consumers that want to filter by error type have to do string parsing (`metadata->>'error_reason' LIKE '%connection_error%'`). A cleaner shape would be:

```elixir
# Today
metadata: %{error_reason: inspect(reason)}
# → "{:connection_error, :nxdomain}"

# Future
metadata: %{error_reason: reason}
# → ["connection_error", "nxdomain"] (Jason coerces tuples to lists, atoms to strings)
# Filter via JSONB: metadata->'error_reason'->>0 = 'connection_error'
```

**Why deferred**: no consumer currently filters on `error_reason`. The string form is workable for the only current reader (the activity log UI). A consumer-driven refactor is the right time — the structured shape should match the consumer's filter needs (split kind/data vs. raw list, atoms-as-strings vs. coerced).

**When you do refactor**: also update the assertion in `test/phoenix_kit_ai/completion_coverage_test.exs:~240` that currently pins the inspect-string literal `"{:connection_error, :nxdomain}"`.

### AI translation protocol — extract from `phoenix_kit_projects` + `phoenix_kit_publishing`

Each module that wants AI-driven translation currently rolls its own Oban worker, enqueue facade, broadcast event shape, progress UI, and host integration. Only the raw AI call + structured `---FIELD---` parser is shared (`PhoenixKit.Modules.AI.Translation` in core); everything around that is duplicated. Surfaced 2026-05-22 during the PR #13 retrospective.

**Duplication today** (N=2 consumers — `phoenix_kit_publishing` and `phoenix_kit_projects`):

| Concern | Shared today | Duplicated |
| --- | --- | --- |
| AI call + structured parser | ✅ core `Modules.AI.Translation` | — |
| Oban worker (load → translate → persist → broadcast → retry) | — | `TranslatePostWorker` (publishing) + `TranslateResourceWorker` (projects) |
| Enqueue facade | — | `TranslatePostWorker.enqueue/3` vs `PhoenixKitProjects.Translations.enqueue/1` |
| Progress UI state | — | inline in publishing's `editor.ex` vs projects' `AITranslateFormHelpers` |
| UI components (button/modal/progress bar) | — | both hand-rolled, different shapes |
| Broadcast event shape | — | publishing `{:translation_progress, ...}` ≠ projects `{:projects, :translation_completed, %{...}}` |

**Proposed shape** — lives in core's `Modules.AI.*` namespace alongside the existing `Translation`:

```text
PhoenixKit.Modules.AI.TranslatableResource     # @callback load/persist/translatable_fields/pubsub_topics
PhoenixKit.Modules.AI.TranslationWorker        # generic Oban worker; takes :resource_module in args
PhoenixKit.Modules.AI.Translations             # enqueue/1, enqueue_all_missing/2, list endpoints/prompts
PhoenixKit.Modules.AI.TranslationLive          # `use`-able mixin: assigns + handle_info + bumpers
PhoenixKitWeb.Components.AITranslate.{Button, Modal, Progress}
```

A consumer would implement the behaviour for its resource schema(s); the worker, UI, and broadcasts come for free.

**Why deferred**:
- N=2 implementations is thin evidence — "rule of three" applies. Designing the abstraction from only publishing + projects risks codifying coincidental shape (their broadcast contracts already differ in non-trivial ways).
- Publishing's translate worker is ~1000 lines and stable; migrating it is its own multi-session project with release coordination across phoenix_kit + phoenix_kit_publishing.
- Projects' translation infra was stabilized in PR #13 (2026-05-22 — race fix + atomic merge + UI lock + progress UI). Refactoring it to fit a shared abstraction immediately afterward would risk regressing those fixes for no immediate user-visible win.

**When you do refactor** — natural triggers:
- A third consumer appears (entities, newsletters, hello-world-as-template, a future "translate help articles") that would force the abstraction. Three concrete impls is enough to design from.
- A protocol-level bug that needs fixing in both places (e.g. another race like the projects FOR UPDATE one) — at that point the cost of fixing twice outweighs the cost of extracting.

**Path forward** when triggered (suggested, not committed):
1. **Phase 1 — core**: introduce the behaviour + generic worker + facade + LV mixin + UI components. Tests against a synthetic in-memory `TestResource`. Ship as a phoenix_kit release.
2. **Phase 2 — projects**: implement the behaviour for `Project` / `Task` / `Assignment`. Delete `TranslateResourceWorker`, `PhoenixKitProjects.Translations`, `AITranslateFormHelpers`, `ai_translate_bar.ex`. Form LVs become thin shells over the mixin.
3. **Phase 3 — publishing**: implement the behaviour for `PublishingPost`. Bigger change; broadcast contract changes; needs its own planning + host-side coordination because publishing's existing `{:translation_progress, ...}` broadcasts are consumed by the editor LV.

**Design questions to settle before any code lands**:
- **Broadcast namespace.** `{PhoenixKitAI.Translation, :started|:completed|:failed, payload}` or `{:ai_translation, :verb, payload}` or something else? Pattern-match-able and set-in-stone once shipped.
- **Worker concurrency knob.** Hard-code `period: :infinity` + per-resource-uuid uniqueness, or let the resource module override? Projects always wants `:infinity`; publishing may want a window.
- **UI components — single per-module or shared?** Default opinionated components in core, OR primitive building blocks that hosts compose into their own shape? Projects' compact-button + slim-progress design works well; whether that's the universal default is a judgment call.
- **Activity log shape.** Generic worker emits `core.ai_translation.<verb>` with `module: <consumer>` metadata. Loses per-module action names (`projects.translation_added`, `publishing.translation.added`) but unifies the audit trail. Worth deciding which convention wins.

**Anchors** — current code to study when picking this up:
- `phoenix_kit/lib/modules/ai/translation.ex` — the existing shared piece + the optional-plugin guard pattern to copy
- `phoenix_kit_projects/lib/phoenix_kit_projects/workers/translate_resource_worker.ex` — the cleaner worker shape post-PR #13 (Repo.transaction + FOR UPDATE, retry classification, atomic JSONB merge)
- `phoenix_kit_projects/lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` — the LV-mixin shape (mount assigns + start/completed bumpers + duplicate-event guard)
- `phoenix_kit_projects/lib/phoenix_kit_projects/web/components/ai_translate_bar.ex` — the UI components (button/modal/progress, daisyUI-themed, theme-safe contrast)
- `phoenix_kit_publishing/lib/phoenix_kit_publishing/workers/translate_post_worker.ex` — the older shape (different broadcast contract, inline progress UI in editor.ex, retry attempt counter)
