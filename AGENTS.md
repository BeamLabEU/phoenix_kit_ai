# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit AI module — provides AI endpoint management, prompt templates, completions (via OpenRouter), and usage tracking. Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

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
- `req` (via phoenix_kit) — HTTP client for OpenRouter API calls
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
7. API keys are managed centrally via `PhoenixKit.Integrations`. Each endpoint stores an integration connection key in its `provider` field. The module declares `required_integrations: ["openrouter"]`.

### Key Modules

- **`PhoenixKitAI`** (`lib/phoenix_kit_ai.ex`) — Main module implementing `PhoenixKit.Module` behaviour AND serving as the context module for all AI operations (endpoints, prompts, requests, completions).

- **`PhoenixKitAI.Endpoint`** (`lib/phoenix_kit_ai/endpoint.ex`) — Ecto schema for AI endpoint configurations (provider credentials, model, generation parameters).

- **`PhoenixKitAI.Prompt`** (`lib/phoenix_kit_ai/prompt.ex`) — Ecto schema for reusable prompt templates with `{{Variable}}` substitution.

- **`PhoenixKitAI.Request`** (`lib/phoenix_kit_ai/request.ex`) — Ecto schema for request logging (tokens, cost, latency, status).

- **`PhoenixKitAI.Errors`** (`lib/phoenix_kit_ai/errors.ex`) — Maps error atoms returned from the API layer (`:endpoint_not_found`, `:invalid_api_key`, etc.) to translated strings via gettext. UI surfaces errors via `Errors.message/1` so business logic stays locale-agnostic.

- **`PhoenixKitAI.Completion`** (`lib/phoenix_kit_ai/completion.ex`) — HTTP client for OpenRouter chat completions and embeddings.

- **`PhoenixKitAI.OpenRouterClient`** (`lib/phoenix_kit_ai/openrouter_client.ex`) — API key validation, model discovery, header building. API keys are resolved from `PhoenixKit.Integrations` via the endpoint's `provider` field (a UUID referencing an integration connection).

- **`PhoenixKitAI.AIModel`** (`lib/phoenix_kit_ai/ai_model.ex`) — Normalized struct for OpenRouter model data.

- **`PhoenixKitAI.Routes`** (`lib/phoenix_kit_ai/routes.ex`) — Route module providing admin sub-routes (new/edit forms, usage page). Auto-discovered and compiled into PhoenixKit's `live_session :phoenix_kit_admin` — never hand-register these routes in the parent app's `router.ex`. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative admin routing reference.

- **`PhoenixKitAI.Web.*`** (`lib/phoenix_kit_ai/web/`) — Admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground.

### Activity Logging Pattern

Every mutating context function logs via `PhoenixKit.Activity.log/1`, guarded with `Code.ensure_loaded?/1` + `rescue` so logging failures never crash the primary operation. Mutating functions accept an `opts \\ []` keyword list; LiveViews extract the current user UUID via a private `actor_opts/1` helper.

```elixir
defp log_activity(action, resource, opts, extra \\ %{}) do
  if Code.ensure_loaded?(PhoenixKit.Activity) do
    PhoenixKit.Activity.log(%{
      action: action,
      module: "ai",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: resource_type(resource),
      resource_uuid: resource.uuid,
      metadata: Map.merge(%{"actor_role" => Keyword.get(opts, :actor_role, "user")}, extra)
    })
  end
rescue
  _ -> :activity_log_failed
end
```

Current logged actions:

| Action | When |
|--------|------|
| `endpoint.created` | `create_endpoint/2` |
| `endpoint.updated` | `update_endpoint/3` |
| `endpoint.deleted` | `delete_endpoint/2` |
| `endpoint.enabled` / `endpoint.disabled` | `update_endpoint/3` with a flipped `enabled` field |
| `prompt.created` | `create_prompt/2` |
| `prompt.updated` | `update_prompt/3` |
| `prompt.deleted` | `delete_prompt/2` |
| `prompt.enabled` / `prompt.disabled` | `update_prompt/3` with a flipped `enabled` field |

Individual AI completion requests are **not** logged to Activity; they already have dedicated rows in `phoenix_kit_ai_requests` for usage tracking.

### Settings Keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `ai_enabled` | boolean | `false` | Module enable/disable toggle |

Application env (not Settings table):

| Key | Default | Purpose |
|-----|---------|---------|
| `config :phoenix_kit_ai, :capture_request_memory` | `false` | Opt-in `:memory` capture per request. Keep off unless actively debugging memory issues; every request otherwise carries the memory snapshot in its JSONB metadata. |
| `config :phoenix_kit_ai, :embedding_models` | `[]` | User-contributed embedding models appended to the built-in list in `OpenRouterClient.fetch_embedding_models/2`. |

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

## Migrating from legacy `endpoint.api_key`

Endpoints created before the Integrations migration (PR #3) stored the OpenRouter API key directly in the `api_key` column. New endpoints leave that column blank and point `provider` at a `PhoenixKit.Integrations` connection key (e.g. `"openrouter"` or `"openrouter:my-key"`).

When `OpenRouterClient.resolve_api_key/2` has to fall back to the legacy column, it logs a `Logger.warning` identifying the endpoint by name + UUID so the noise is actionable. To clear it for a given endpoint:

1. Open Settings → Integrations and add an OpenRouter connection (if one doesn't already exist). The default connection key is `openrouter`.
2. Edit the endpoint in the AI admin UI and select that connection from the `integration_picker`. The `provider` field will be set to the connection's lookup key.
3. Save. The legacy warning stops firing on the next request.

The `api_key` column is retained so pre-migration deployments keep working without forced downtime, and is flagged **Deprecated** in `PhoenixKitAI.Endpoint` — planned for removal in a future major version.

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

1. **Unit tests** (`test/phoenix_kit_ai/{completion,errors,prompt,ai_model}_test.exs`) — Pure logic, no DB required, always run.
2. **Integration tests** (`test/phoenix_kit_ai/{endpoint,request,openrouter_client}_test.exs`, LiveView tests) — Real PostgreSQL via Ecto sandbox; auto-excluded when the DB is unavailable.

The test DB (`phoenix_kit_ai_test`) uses an embedded `PhoenixKitAI.Test.Repo` in `test/support/test_repo.ex`. Schema setup happens in `test/test_helper.exs` (it loads the schemas via raw DDL so no separate migration files are needed). Tests using `PhoenixKitAI.DataCase` are **automatically tagged `:integration`** and excluded when the DB is unavailable.

LiveView tests need a minimal test Endpoint + Router + Layouts + LiveCase — see `test/support/`. The router scopes at `/en/admin/ai/…` so admin paths receive the default locale. `lazy_html` is a `:test`-only dep for rendered-HTML assertions.

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
