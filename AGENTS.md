# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PhoenixKit AI module — provides AI endpoint management, prompt templates, completions (via OpenRouter), and usage tracking. Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

## Common Commands

```bash
mix deps.get          # Install dependencies
mix test              # Run all tests
mix test test/phoenix_kit_ai_test.exs  # Run specific test file
mix test --only tag   # Run tests matching a tag
mix format            # Format code (imports Phoenix LiveView rules)
mix credo             # Static analysis / linting
mix dialyzer          # Type checking
mix docs              # Generate documentation
```

## Architecture

This is a **library** (not a standalone Phoenix app) that provides AI capabilities as a PhoenixKit plugin module.

### Key Modules

- **`PhoenixKitAI`** (`lib/phoenix_kit_ai.ex`) — Main module implementing `PhoenixKit.Module` behaviour AND serving as the context module for all AI operations (endpoints, prompts, requests, completions).

- **`PhoenixKitAI.Endpoint`** (`lib/phoenix_kit_ai/endpoint.ex`) — Ecto schema for AI endpoint configurations (provider credentials, model, generation parameters).

- **`PhoenixKitAI.Prompt`** (`lib/phoenix_kit_ai/prompt.ex`) — Ecto schema for reusable prompt templates with `{{Variable}}` substitution.

- **`PhoenixKitAI.Request`** (`lib/phoenix_kit_ai/request.ex`) — Ecto schema for request logging (tokens, cost, latency, status).

- **`PhoenixKitAI.Completion`** (`lib/phoenix_kit_ai/completion.ex`) — HTTP client for OpenRouter chat completions and embeddings.

- **`PhoenixKitAI.OpenRouterClient`** (`lib/phoenix_kit_ai/openrouter_client.ex`) — API key validation, model discovery, header building.

- **`PhoenixKitAI.AIModel`** (`lib/phoenix_kit_ai/ai_model.ex`) — Normalized struct for OpenRouter model data.

- **`PhoenixKitAI.Routes`** (`lib/phoenix_kit_ai/routes.ex`) — Route module providing admin sub-routes (new/edit forms, usage page).

- **`PhoenixKitAI.Web.*`** (`lib/phoenix_kit_ai/web/`) — Admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional admin routes (new/edit/usage) via `admin_routes/0`
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Database Tables

- `phoenix_kit_ai_endpoints` — Endpoint configurations (UUIDv7 PK)
- `phoenix_kit_ai_prompts` — Prompt templates (UUIDv7 PK)
- `phoenix_kit_ai_requests` — Request logs for usage tracking (UUIDv7 PK)

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"ai"`
- **Tab IDs**: prefixed with `:admin_ai_` (e.g., `:admin_ai_endpoints`)
- **URL paths**: use hyphens, not underscores (`"ai/endpoints"`)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **LiveViews use `PhoenixKitWeb` macros** — use `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView` directly)
- **JavaScript hooks**: must be inline `<script>` tags; register on `window.PhoenixKitHooks`
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Cost precision**: Costs stored in nanodollars (1/1,000,000 USD) in the `cost_cents` field for precision with cheap API calls

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_ai]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **Req** (via PhoenixKit) — HTTP client for OpenRouter API calls
- **Jason** (via PhoenixKit) — JSON encoding/decoding
