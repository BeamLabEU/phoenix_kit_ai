# PhoenixKitAI

AI module for PhoenixKit — provides endpoint management, prompt templates, completions via OpenRouter, and usage tracking.

## Features

- **Endpoint Management** — Create and manage AI endpoint configurations (provider credentials, model selection, generation parameters)
- **Prompt Templates** — Reusable prompts with `{{Variable}}` substitution syntax
- **Completions API** — Simple single-turn (`ask/3`), multi-turn (`complete/3`), and embeddings (`embed/3`)
- **Usage Tracking** — Every API call logged with tokens, cost (nanodollars), latency, and status
- **Admin UI** — 5 LiveView pages: Endpoints, Endpoint Form, Prompts, Prompt Form, Playground
- **Real-time Updates** — PubSub broadcasts for endpoint/prompt/request changes

## Quick start

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_ai, path: "../phoenix_kit_ai"}
```

Run `mix deps.get` and start the server. The module appears in:

- **Admin sidebar** (under Modules section) — AI with subtabs for Endpoints, Prompts, Playground, Usage
- **Admin > Modules** — toggle it on/off
- **Admin > Roles** — grant/revoke access per role

## Installation

### Local development

```elixir
{:phoenix_kit_ai, path: "../phoenix_kit_ai"}
```

### Git dependency

```elixir
{:phoenix_kit_ai, git: "https://github.com/BeamLabEU/phoenix_kit_ai.git"}
```

### Hex package

```elixir
{:phoenix_kit_ai, "~> 0.1.0"}
```

## Usage

```elixir
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

# Simple completion
{:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Hello!")
{:ok, text} = PhoenixKitAI.extract_content(response)

# Multi-turn conversation
messages = [
  %{role: "system", content: "You are a helpful assistant."},
  %{role: "user", content: "What is Elixir?"}
]
{:ok, response} = PhoenixKitAI.complete(endpoint.uuid, messages)

# Prompt templates
{:ok, prompt} = PhoenixKitAI.create_prompt(%{
  name: "Translator",
  content: "Translate to {{Language}}: {{Text}}"
})
{:ok, response} = PhoenixKitAI.ask_with_prompt(
  endpoint.uuid,
  prompt.uuid,
  %{"Language" => "French", "Text" => "Hello!"}
)

# Embeddings
{:ok, response} = PhoenixKitAI.embed(endpoint.uuid, "Hello world")
```

## Project structure

```
lib/
  phoenix_kit_ai.ex                    # Main module (behaviour + context)
  phoenix_kit_ai/
    endpoint.ex                        # Endpoint schema
    prompt.ex                          # Prompt template schema
    request.ex                         # Request logging schema
    completion.ex                      # OpenRouter HTTP client
    openrouter_client.ex               # API key validation & model discovery
    ai_model.ex                        # Normalized model struct
    routes.ex                          # Admin sub-routes (new/edit forms)
    migrations/
      v1.ex                            # Migration module (called by parent app)
    web/
      endpoints.ex/.heex               # Endpoints list + usage page
      endpoint_form.ex/.heex           # Create/edit endpoint
      prompts.ex/.heex                 # Prompts list
      prompt_form.ex/.heex             # Create/edit prompt
      playground.ex/.heex              # Interactive testing
test/
  phoenix_kit_ai_test.exs             # Behaviour compliance tests
  phoenix_kit_ai/
    prompt_test.exs                    # Prompt template tests
```

## Database tables

All tables use UUIDv7 primary keys and timestamptz columns.

- **`phoenix_kit_ai_endpoints`** — Endpoint configurations (28 columns)
- **`phoenix_kit_ai_prompts`** — Prompt templates (14 columns)
- **`phoenix_kit_ai_requests`** — Request logs (18 columns, FK to endpoints/prompts/users)

Database tables and migrations are managed by the parent PhoenixKit project. This repo provides `PhoenixKitAI.Migrations.V1` as a library module that the parent app's migrations call — there are no migrations to run in this repo directly.

## Admin pages

| Page | Path | Description |
|------|------|-------------|
| Endpoints | `/admin/ai/endpoints` | List, create, edit, delete, validate endpoints |
| Endpoint Form | `/admin/ai/endpoints/new`, `.../edit` | Create/edit endpoint with model selection |
| Prompts | `/admin/ai/prompts` | List, create, edit, delete, reorder prompts |
| Prompt Form | `/admin/ai/prompts/new`, `.../edit` | Create/edit with variable extraction |
| Playground | `/admin/ai/playground` | Interactive testing with live variable substitution |
| Usage | `/admin/ai/usage` | Dashboard stats and request history |

## Supported providers

Currently supports **OpenRouter** (100+ models from Anthropic, OpenAI, Google, Meta, Mistral, and more).

## Callbacks implemented

| Callback | Value |
|----------|-------|
| `module_key/0` | `"ai"` |
| `module_name/0` | `"AI"` |
| `enabled?/0` | DB-backed boolean with rescue fallback |
| `enable_system/0` | Persists via Settings API |
| `disable_system/0` | Persists via Settings API |
| `version/0` | `"0.1.1"` |
| `permission_metadata/0` | key: `"ai"`, icon: `hero-sparkles` |
| `admin_tabs/0` | 5 tabs (parent + 4 subtabs) |
| `css_sources/0` | `[:phoenix_kit_ai]` |
| `route_module/0` | `PhoenixKitAI.Routes` |
| `get_config/0` | Endpoint count, request count, token totals |

## Development

```bash
mix deps.get          # Install dependencies
mix test              # Run all tests
mix format            # Format code
mix credo --strict    # Linting
mix dialyzer          # Type checking
mix quality           # Format + Credo + Dialyzer
```

## Testing

```bash
# Unit tests (always work, no DB needed)
mix test

# Integration tests (need PostgreSQL)
createdb phoenix_kit_ai_test
mix test
```

> **Note:** This repo has no database migrations. All tables and migrations are managed by the parent PhoenixKit project. The test helper creates necessary DB functions directly when a test database is available.
