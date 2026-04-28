# PhoenixKitAI

AI module for PhoenixKit — provides endpoint management, prompt templates,
completions via OpenRouter, and usage tracking. Implements the
`PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix
application.

## Features

- **Endpoint Management** — Unified configuration combining provider
  credentials, model selection, and generation parameters
- **Prompt Templates** — Reusable prompts with `{{Variable}}` substitution
  syntax, live preview, and variable validation
- **Completions API** — Single-turn (`ask/3`), multi-turn (`complete/3`),
  and embeddings (`embed/3`)
- **Usage Tracking** — Every API call logged with tokens, cost
  (nanodollars), latency, status, and full caller context
- **Admin UI** — LiveView pages for Endpoints, Prompts, Usage, and a live
  Playground
- **Real-time Updates** — PubSub broadcasts for endpoint/prompt/request
  changes
- **Integrations-backed credentials** — API keys resolved via
  `PhoenixKit.Integrations` (OpenRouter connection), not stored per
  endpoint

## Quick start

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_ai, "~> 0.1"}
```

Run `mix deps.get` and start the server. The module appears in:

- **Admin sidebar** — AI with subtabs for Endpoints, Prompts, Playground,
  and Usage
- **Admin → Modules** — toggle on/off
- **Admin → Roles** — grant/revoke access per role
- **Admin → Settings → Integrations** — set up the OpenRouter connection

## Installation

### Local development

```elixir
{:phoenix_kit_ai, path: "../phoenix_kit_ai"}
```

### Hex package

```elixir
{:phoenix_kit_ai, "~> 0.1"}
```

## API usage

### Simple chat completion

```elixir
{:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "What is 2+2?")
{:ok, text} = PhoenixKitAI.extract_content(response)
# => "4"
```

### With system message

```elixir
{:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Hello",
  system: "You are a pirate. Always respond like a pirate."
)
```

### Multi-turn conversation

```elixir
{:ok, response} = PhoenixKitAI.complete(endpoint.uuid, [
  %{role: "system", content: "You are a helpful assistant."},
  %{role: "user", content: "What's the weather like?"},
  %{role: "assistant", content: "I don't have real-time weather data..."},
  %{role: "user", content: "That's okay, just make something up."}
])
```

### Parameter overrides

```elixir
{:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Write a creative poem",
  temperature: 1.5,
  max_tokens: 500
)
```

### Embeddings

```elixir
# Single text
{:ok, response} = PhoenixKitAI.embed(endpoint.uuid, "Hello, world!")

# Batch
{:ok, response} = PhoenixKitAI.embed(endpoint.uuid, ["Text 1", "Text 2"])

# With dimension override
{:ok, response} = PhoenixKitAI.embed(endpoint.uuid, "Hello", dimensions: 512)
```

### Extracting response data

```elixir
{:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Hello!")

# Text content
{:ok, text} = PhoenixKitAI.extract_content(response)

# Usage statistics (cost in nanodollars)
usage = PhoenixKitAI.extract_usage(response)
# => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25, cost_cents: 30}

# Full response includes latency
response["latency_ms"] # => 850
```

## Prompt templates

Prompts are reusable templates with `{{VariableName}}` substitution.
Variable names must start with a letter or underscore.

```elixir
{:ok, prompt} = PhoenixKitAI.create_prompt(%{
  name: "Email Writer",
  content: "Write a professional email about {{Topic}} to {{Recipient}}."
})

{:ok, response} = PhoenixKitAI.ask_with_prompt(
  endpoint.uuid,
  "email-writer",                 # accepts uuid, slug, or struct
  %{"Topic" => "Q4 results", "Recipient" => "stakeholders"}
)
```

Other helpers: `get_prompt_variables/1`, `preview_prompt/2`,
`validate_prompt_variables/2`, `search_prompts/2`,
`get_prompts_with_variable/1`, `list_prompts/0`, `list_enabled_prompts/0`,
`enable_prompt/1`, `disable_prompt/1`, `duplicate_prompt/2`,
`delete_prompt/1`, `get_prompt_usage_stats/0`, `reset_prompt_usage/1`.

## Endpoint management

```elixir
# Create
{:ok, endpoint} = PhoenixKitAI.create_endpoint(%{
  name: "Claude Fast",
  provider: "openrouter",        # integration connection key
  model: "anthropic/claude-3-haiku",
  temperature: 0.7
})

# List with filters and sorting
PhoenixKitAI.list_endpoints(
  provider: "openrouter",
  enabled: true,
  sort_by: :usage,
  sort_dir: :desc
)

# Update / toggle / delete
{:ok, updated} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 0.5})
{:ok, _}       = PhoenixKitAI.update_endpoint(endpoint, %{enabled: false})
{:ok, _}       = PhoenixKitAI.delete_endpoint(endpoint)
```

> **API keys are managed via Integrations.** New endpoints should leave
> `api_key` blank and point `provider` at an OpenRouter connection
> (default key `"openrouter"`). The legacy `api_key` field is still read
> for pre-Integrations rows — see [Migrating from legacy
> `endpoint.api_key`](#migrating-from-legacy-endpointapi_key).

## Source tracking & debugging

Every request automatically captures:

- **Source** — clean caller identifier (e.g.
  `"MyApp.ContentGenerator.summarize"`), auto-extracted from the
  stacktrace. Override via `source: "CustomLabel"`.
- **Stacktrace** — up to 20 frames.
- **Caller context** — `request_id` (Phoenix Logger metadata), `node`,
  `pid`.
- **Memory snapshot** (opt-in) — enable with
  `config :phoenix_kit_ai, :capture_request_memory, true` when you need
  per-request memory data; off by default to keep JSONB metadata small.

All of this is stored in `phoenix_kit_ai_requests.metadata` (JSONB) and
surfaced in the admin Usage page's request-details modal.

## Migrating from legacy `endpoint.api_key`

Endpoints created before the Integrations migration stored the OpenRouter
API key directly in the `api_key` column. New endpoints leave that
column blank and point `provider` at a `PhoenixKit.Integrations`
connection key instead (e.g. `"openrouter"`).

When `OpenRouterClient.resolve_api_key/2` falls back to the legacy
column, it emits a `Logger.warning` identifying the endpoint so the
warning is actionable. To clear it:

1. Open **Settings → Integrations** and add an OpenRouter connection if
   one doesn't exist.
2. Edit the endpoint and select that connection from the
   `integration_picker`.
3. Save.

The `api_key` column is retained so pre-migration deployments keep
working without forced downtime, and is flagged **Deprecated** in
`PhoenixKitAI.Endpoint` — planned for removal in a future major version.

### Legacy `raw_response` metadata

Older request rows stored the full raw API response under
`metadata["raw_response"]` for debugging. This was removed to avoid
persisting provider responses verbatim; new rows omit the key entirely.
The admin usage UI still renders the raw-response panel when it's
present in a row's metadata, so historic data stays viewable.

## Error handling

All public functions return `{:ok, result}` or `{:error, reason}` where
`reason` is an **atom** from a known set:

| Atom | Cause | Translated message (via `PhoenixKitAI.Errors.message/1`) |
|------|-------|-----|
| `:endpoint_not_found` | Endpoint UUID does not exist | "Endpoint not found" |
| `:endpoint_disabled` | Endpoint exists but `enabled: false` | "Endpoint is disabled" |
| `:invalid_endpoint_identifier` | Caller passed a non-UUID value | "Invalid endpoint identifier" |
| `:invalid_api_key` | OpenRouter returned 401 | "Invalid API key" |
| `:insufficient_credits` | OpenRouter returned 402 | "Insufficient credits" |
| `:rate_limited` | OpenRouter returned 429 | "Rate limited" |
| `:request_timeout` | HTTP request timed out | "Request timeout" |
| `{:api_error, status}` | Other non-2xx status | "API error: …" |
| `{:connection_error, reason}` | Transport-level failure | "Connection error: …" |
| `:invalid_json_response` | Response wasn't valid JSON | "Invalid JSON response" |
| `{:prompt_error, :not_found \| :disabled \| :missing_variables}` | Prompt resolution issues | "Prompt …" |

Business logic stays locale-agnostic; the UI calls
`PhoenixKitAI.Errors.message/1` to render the atom as a translated
string via gettext.

```elixir
case PhoenixKitAI.ask(endpoint.uuid, "Hello") do
  {:ok, response} ->
    {:ok, text} = PhoenixKitAI.extract_content(response)
    text

  {:error, reason} ->
    Logger.warning("AI call failed: #{inspect(reason)}")
    {:error, PhoenixKitAI.Errors.message(reason)}
end
```

## Response structure

### Chat completion

```elixir
%{
  "id" => "gen-...",
  "model" => "anthropic/claude-3-haiku",
  "choices" => [
    %{
      "message" => %{"role" => "assistant", "content" => "..."},
      "finish_reason" => "stop"
    }
  ],
  "usage" => %{
    "prompt_tokens" => 10,
    "completion_tokens" => 15,
    "total_tokens" => 25,
    "cost" => 0.00003
  },
  "latency_ms" => 850
}
```

### Embeddings

```elixir
%{
  "data" => [%{"embedding" => [0.123, -0.456, ...], "index" => 0}],
  "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5},
  "latency_ms" => 120
}
```

## Cost tracking

Costs are stored in **nanodollars** (1/1,000,000 of a dollar) to
preserve precision for cheap calls.

```elixir
PhoenixKitAI.Request.format_cost(30)         # => "$0.000030"
PhoenixKitAI.Request.format_cost(1_500_000)  # => "$1.50"
```

`format_cost/1` tiers decimal precision: 2 decimals above $0.01,
4 decimals above $0.0001, 6 decimals below.

## Project structure

```
lib/
  phoenix_kit_ai.ex                    # Main module (behaviour + context)
  phoenix_kit_ai/
    endpoint.ex                        # Endpoint schema
    prompt.ex                          # Prompt template schema
    request.ex                         # Request logging schema
    errors.ex                          # Atom → translated message mapping
    completion.ex                      # OpenRouter HTTP client
    openrouter_client.ex               # API key validation & model discovery
    ai_model.ex                        # Normalized model struct
    routes.ex                          # Admin sub-routes (new/edit forms)
    web/
      endpoints.ex/.heex               # Endpoints list + usage page
      endpoint_form.ex/.heex           # Create/edit endpoint
      prompts.ex/.heex                 # Prompts list
      prompt_form.ex/.heex             # Create/edit prompt
      playground.ex/.heex              # Interactive testing
test/
  phoenix_kit_ai_test.exs              # Behaviour compliance tests
  phoenix_kit_ai/
    completion_test.exs                # HTTP + error parsing
    endpoint_test.exs                  # Schema + CRUD
    errors_test.exs                    # Atom → message mapping
    openrouter_client_test.exs         # API key + model discovery
    prompt_test.exs                    # Variable extraction + changeset
    request_test.exs                   # Schema + format_cost
```

## Database tables

All tables use UUIDv7 primary keys and timestamptz columns. Migrations
are managed by the parent PhoenixKit project — this repo has no
migrations of its own.

- **`phoenix_kit_ai_endpoints`** — endpoint configurations
- **`phoenix_kit_ai_prompts`** — prompt templates
- **`phoenix_kit_ai_requests`** — request logs (FK to endpoints, prompts,
  users)

## Admin pages

| Page | Path | Description |
|------|------|-------------|
| Endpoints | `/admin/ai/endpoints` | List, create, edit, delete, validate |
| Endpoint form | `/admin/ai/endpoints/new`, `.../edit` | Create/edit with model selection |
| Prompts | `/admin/ai/prompts` | List, create, edit, delete, reorder |
| Prompt form | `/admin/ai/prompts/new`, `.../edit` | Create/edit with variable extraction |
| Playground | `/admin/ai/playground` | Interactive testing with live variables |
| Usage | `/admin/ai/usage` | Dashboard stats and request history |

## Supported providers

Currently supports **OpenRouter** (100+ models from Anthropic, OpenAI,
Google, Meta, Mistral, and more). Embedding model list is maintained
in source and extensible via
`config :phoenix_kit_ai, :embedding_models, [...]`.

## PhoenixKit.Module callbacks

| Callback | Value |
|----------|-------|
| `module_key/0` | `"ai"` |
| `module_name/0` | `"AI"` |
| `enabled?/0` | DB-backed boolean with rescue fallback |
| `enable_system/0` / `disable_system/0` | Persist via Settings API |
| `version/0` | current package version |
| `permission_metadata/0` | key `"ai"`, icon `hero-sparkles` |
| `admin_tabs/0` | Parent + 4 subtabs |
| `css_sources/0` | `[:phoenix_kit_ai]` |
| `route_module/0` | `PhoenixKitAI.Routes` |
| `required_integrations/0` | `["openrouter"]` |
| `get_config/0` | `%{enabled, endpoints_count, total_requests, total_tokens}` |

## Development

```bash
mix deps.get          # Install dependencies
mix precommit         # compile + format + credo --strict + dialyzer
mix test              # Run all tests
mix format            # Format code
mix credo --strict    # Linting
mix dialyzer          # Type checking
mix quality           # format + credo --strict + dialyzer
```

## Testing

```bash
# Unit tests (no DB needed)
mix test

# Integration tests (need PostgreSQL)
createdb phoenix_kit_ai_test
mix test

# LiveView tests (same DB, uses local Test.Endpoint)
mix test test/phoenix_kit_ai/web/
```

Integration tests use an embedded `PhoenixKitAI.Test.Repo` with Ecto
sandbox. When the test database is absent they are automatically
excluded and unit tests still run.

## Troubleshooting

- **Models not loading** — check the OpenRouter integration has a valid
  API key in Settings → Integrations, and the account has credits.
- **Slow responses** — use a faster model (Haiku instead of Opus),
  reduce `max_tokens`, or check OpenRouter's status page.
- **High costs** — monitor the Usage tab; consider cheaper models and
  caching repeated queries.
- **Debug logging** — `Logger.configure(level: :debug)`. Request logs
  live in `phoenix_kit_ai_requests` with full caller context.

## Getting help

1. This README for API documentation
2. OpenRouter docs: <https://openrouter.ai/docs>
3. `dev_docs/pull_requests/` for the history of reviewed changes
