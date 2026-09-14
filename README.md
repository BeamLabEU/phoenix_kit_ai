# PhoenixKitAI

AI module for PhoenixKit — provides endpoint management, prompt templates,
completions, and usage tracking via three OpenAI-compatible providers
(OpenRouter, Mistral, DeepSeek). Implements the `PhoenixKit.Module`
behaviour for auto-discovery by a parent Phoenix application.

## Features

- **Endpoint Management** — Unified configuration combining provider
  credentials, model selection, and generation parameters across three
  built-in providers (OpenRouter, Mistral, DeepSeek)
- **Prompt Templates** — Reusable prompts with `{{Variable}}` substitution
  syntax, live preview, and variable validation
- **Completions API** — Single-turn (`ask/3`), multi-turn (`complete/3`),
  and embeddings (`embed/3`)
- **Reasoning capture** — Chain-of-thought from reasoning models
  (DeepSeek-R1, Mistral Magistral, OpenAI o-series, Anthropic extended
  thinking) automatically persisted to request metadata
- **Usage Tracking** — Every API call logged with tokens, cost
  (nanodollars), latency, status, and full caller context
- **Admin UI** — LiveView pages for Endpoints, Prompts, Usage, and a live
  Playground
- **Dynamic model selector** — Models auto-load from each provider's
  `/models` endpoint when an integration is picked, with a 10-second
  "still loading" hint and a retry button on transient failures
- **Real-time Updates** — PubSub broadcasts for endpoint/prompt/request
  changes
- **Integrations-backed credentials** — API keys resolved via
  `PhoenixKit.Integrations`, not stored per endpoint. Each endpoint
  pins to a specific connection by uuid; the picker filters to the
  current provider

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
- **Admin → Settings → Integrations** — set up at least one provider
  connection (OpenRouter, Mistral, or DeepSeek). The endpoint form's
  picker filters to whichever provider is selected on the dropdown.

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

### Structured output

```elixir
{:ok, %{"json" => %{"axes" => axes}}} =
  PhoenixKitAI.ask(endpoint_uuid, "Propose 3–5 rating axes for chocolate bars.",
    schema: %{"type" => "object", "properties" => %{"axes" => %{"type" => "array", "items" => %{"type" => "string"}}}})

{:ok, %{"json" => %{}}} = PhoenixKitAI.complete(endpoint_uuid, messages, json: true)
```

The schema goes to the provider as `response_format` and into the prompt, so
models without `response_format` still answer in shape; the parsed object
comes back under `"json"`.

### Spend caps and the request cache

```elixir
# Settings (nanodollars per trailing 24 h; 0 = no cap)
PhoenixKitAI.Budget.set_limit(:global, 5_000_000_000)      # $5 a day for the whole install
PhoenixKitAI.Budget.set_limit(:user, 100_000_000)          # $0.10 a day per user_uuid

{:error, {:budget_exceeded, :user}} = PhoenixKitAI.ask(ep, "…", user_uuid: visitor_uuid)
PhoenixKitAI.Budget.status(endpoint, user_uuid: visitor_uuid)   # spent / limit / remaining per scope

# Cache an answer for a day; the second identical call costs nothing
{:ok, _} = PhoenixKitAI.ask(ep, prompt, cache: true)
{:ok, _} = PhoenixKitAI.ask(ep, prompt, cache: [ttl: 3_600])
{:ok, _} = PhoenixKitAI.ask(ep, prompt, cache: :refresh)
```

Caps cover the trailing 24 hours, are checked before every provider call
and warn at 80 %. The cache is in-memory (ETS), keyed on what would be sent
(or on your own `cache: [key: "product:123"]`), writes a zero-cost usage row
on a hit, and empties on restart — pair it with your own persistence for
"write once, keep forever".

### Host apps in the translation pipeline

```elixir
config :phoenix_kit_ai, translatables: [{"product", MyApp.AI.ProductTranslatable}]
```

### Image editing and processing

Image-in, image-out through any provider, with the endpoint choosing the
transport:

```elixir
# Named operations, fitted to what the model accepts:
{:ok, %{images: [%{data: png, content_type: "image/png"}], warnings: warnings}} =
  PhoenixKitAI.process_image(endpoint_uuid, [photo_jpeg], [
    :remove_reflections,
    {:clean_background, color: "white"},
    {:upscale, resolution: "2K"}
  ])

# Or a plain instruction with reference images:
{:ok, %{images: [%{data: png}]}} =
  PhoenixKitAI.edit_image(endpoint_uuid, "Restyle the first photo like the second.",
    [%{data: room_jpeg, content_type: "image/jpeg"}, %{data: reference_jpeg, content_type: "image/jpeg"}],
    aspect_ratio: "4:3")

# Vision: free text, or a parsed JSON object per schema
{:ok, %{json: %{"brand" => brand}}} =
  PhoenixKitAI.describe_image(endpoint_uuid, label_jpeg,
    prompt: "Read the label.",
    schema: %{"type" => "object", "properties" => %{"brand" => %{"type" => "string"}}})

# Text extraction (OCR through the vision model): full transcription,
# typed blocks, language, legibility, plus any named values you want pulled out
{:ok, %{text: text, fields: %{"ean" => ean, "best_before" => date}}} =
  PhoenixKitAI.extract_text(endpoint_uuid, label_jpeg,
    fields: %{"ean" => "the barcode digits", "best_before" => "expiry date as YYYY-MM-DD"})
```

Operations (`PhoenixKitAI.Images.Operations`): `:clean_background`,
`:blur_background`, `:remove_background`, `:replace_background`,
`:remove_reflections`, `:remove_objects`, `:enhance`, `:upscale`,
`:relight`, `:recolor`, `:straighten`, `:crop_to_subject`, `:restyle`,
plus free text — extendable from config, and any operation's wording can
be overridden by a saved prompt named `Image op <name>`.

Providers: OpenRouter's unified Images API (every image model on the
gateway, with per-model capabilities), xAI, OpenAI, and any
OpenAI-compatible API through chat completions. Adding one is a
`PhoenixKitAI.Provider` adapter plus a config entry. The module stores no
files: results come back as bytes for the caller to keep.

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

### Reasoning models — chain-of-thought capture

Reasoning models (DeepSeek-R1, Mistral Magistral, OpenAI o-series,
Anthropic extended thinking) return their chain-of-thought alongside
the final answer in a per-provider field on the assistant message.
PhoenixKitAI normalizes the three known shapes and persists the trace
into request metadata so operators can inspect it from the admin
Usage page (collapsed by default — chains-of-thought routinely run
5-50× the length of the answer).

```elixir
{:ok, response} = PhoenixKitAI.complete(endpoint.uuid, [
  %{role: "user", content: "If a train leaves Chicago at 2pm..."}
])

# Final answer
{:ok, answer} = PhoenixKitAI.extract_content(response)

# Chain-of-thought (if the model produced one)
PhoenixKitAI.Completion.extract_reasoning(response)
# => "Step 1: identify the variables...\nStep 2: ..."
# => nil when the model isn't a reasoning model
```

Field-name normalization (handled internally; you don't need to know
which shape your provider uses):

| Provider / response shape | Field on `message` |
|---|---|
| OpenRouter and what it proxies | `reasoning` |
| DeepSeek native API | `reasoning_content` |
| Some others | `thinking` |

The trace lands in `phoenix_kit_ai_requests.metadata.response_reasoning`.
Subject to the same `capture_request_content?` privacy gate as
`response` content (see "Privacy / retention controls" below) — when
content capture is off, reasoning is dropped too. Reasoning can mirror
prompt content and is PII-equivalent.

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
# Create — OpenRouter
{:ok, endpoint} = PhoenixKitAI.create_endpoint(%{
  name: "Claude Fast",
  provider: "openrouter",          # provider key (see Supported providers)
  integration_uuid: integration.uuid,
  model: "anthropic/claude-3-haiku",
  temperature: 0.7
})

# Create — Mistral. base_url defaults to https://api.mistral.ai/v1
# via Endpoint.default_base_url/1; model id is provider-native.
{:ok, ep} = PhoenixKitAI.create_endpoint(%{
  name: "Mistral Large",
  provider: "mistral",
  integration_uuid: mistral_integration.uuid,
  model: "mistral-large-latest"
})

# Create — DeepSeek
{:ok, ep} = PhoenixKitAI.create_endpoint(%{
  name: "DeepSeek Reasoner",
  provider: "deepseek",
  integration_uuid: deepseek_integration.uuid,
  model: "deepseek-reasoner"       # reasoning model — chain-of-thought captured
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

> **API keys are managed via Integrations.** Each endpoint references a
> specific `PhoenixKit.Integrations` connection by uuid via the
> `integration_uuid` column (added in core's V107 with backfill from
> existing `provider` strings). The picker on the endpoint form writes
> the chosen connection's uuid; `OpenRouterClient.resolve_api_key/1`
> looks up credentials by uuid at request time — no per-provider
> guessing. After a successful migration (manual save with an
> integration picked, or `migrate_legacy/0` at boot), the legacy
> `api_key` column is atomically wiped to `""` so the credential lives
> in exactly one place. The column itself stays in the schema (it's
> `NOT NULL` in core's V34, so the value must be a string — empty
> string represents "cleared") so a manual DB recovery is still
> possible if catastrophe strikes; planned for removal in a future
> major version.
> See [Migrating from legacy `endpoint.api_key`](#migrating-from-legacy-endpointapi_key)
> for the recommended workflow and the boot-time auto-migrator.

## Source tracking & debugging

Every request automatically captures:

- **Source** — clean caller identifier (e.g.
  `"MyApp.ContentGenerator.summarize"`), auto-extracted from the
  stacktrace. Override via `source: "CustomLabel"`.
- **Stacktrace** — up to 20 frames.
- **Caller context** — `request_id` (Phoenix Logger metadata), `node`,
  `pid`.
- **Message + response content** — full user message list and assistant
  response text. Default-on; controllable via the config flag below.
- **Memory snapshot** (opt-in) — enable with
  `config :phoenix_kit_ai, :capture_request_memory, true` when you need
  per-request memory data; off by default to keep JSONB metadata small.

All of this is stored in `phoenix_kit_ai_requests.metadata` (JSONB) and
surfaced in the admin Usage page's request-details modal.

### Privacy / retention controls
  # Image processing (see dev_docs/guides/image-processing.md)
  provider_adapters: %{},              # provider key => PhoenixKitAI.Provider module
  image_operations: %{},               # extra / replacement named operations
  max_image_bytes: 25_000_000,         # largest input or fetched output
  allow_internal_image_urls: false     # lift the image-fetch host policy (tests only)

```elixir
# config/config.exs (defaults shown)
config :phoenix_kit_ai,
  # Persist user message + assistant response content in request
  # metadata. Default `true` matches the shipped debugging shape.
  # Set to `false` for deployments with PII / data-retention
  # obligations — token counts, latency, model, and cost are still
  # recorded; only the user-supplied strings get redacted (replaced
  # with `metadata.content_redacted: true`).
  capture_request_content: true,

  # Capture process memory in request `caller_context` (default off).
  capture_request_memory: false,

  # Bypass SSRF guard on `Endpoint.base_url` — required for
  # self-hosted Ollama / intranet inference. Off by default; the
  # guard rejects loopback / RFC1918 / link-local / `*.local` /
  # non-http(s) URLs unless this is enabled.
  allow_internal_endpoint_urls: false
```

## Migrating from legacy `endpoint.api_key`

Endpoints created before V107 / the Integrations migration stored the
OpenRouter API key directly in the `api_key` column and used the bare
`provider` field (`"openrouter"`) without a specific connection
reference. V107's backfill stamps `integration_uuid` for any endpoint
whose `provider` matches a `PhoenixKit.Integrations` row. Endpoints
that can't be auto-resolved keep working via the legacy `api_key`
column with a deprecation warning per request — until they're
migrated, at which point the column is atomically wiped.

The recommended workflow is to point each endpoint at a specific
integration connection via the form's `integration_picker`. The
endpoint changeset clears the legacy column to `""` in the same
DB transaction (`Endpoint.maybe_clear_legacy_api_key/1`), so once
migrated the credential lives only in the integration row.

Stuck endpoints (`api_key` populated, `integration_uuid` still NULL —
e.g., when V107 couldn't match anything and the boot-time migrator
hasn't reached this endpoint) get a "Legacy API key (recovery)" card
on the edit form, with a copy button so the operator can paste the
key into a new Integration without bouncing back to OpenRouter. The
card disappears once an integration is selected and saved.

### Manual workflow (per-endpoint)

1. Open **Settings → Integrations** and add an OpenRouter connection if
   one doesn't exist.
2. Edit the endpoint and select that connection from the
   `integration_picker`.
3. Save. The legacy warning stops firing on the next request.

### Boot-time auto-migrator

The recommended entry point is the orchestrator
`PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`. Call it once from
your host app's `Application.start/2`; it walks every registered
PhoenixKit module and invokes its `migrate_legacy/0` callback (idempotent
per module, never crashes the boot):

```elixir
def start(_type, _args) do
  children = [...]
  result = Supervisor.start_link(children, opts)

  # One call. Walks all modules. Per-module errors caught + logged.
  PhoenixKit.ModuleRegistry.run_all_legacy_migrations()

  result
end
```

For AI specifically, `PhoenixKitAI.migrate_legacy/0` (the callback)
runs both kinds of legacy data migration: the api_key→Integrations
credentials migration AND the provider-string→integration_uuid reference
sweep. Both emit `PhoenixKit.Activity` entries (`action:
"integration.legacy_migrated"`) with PII-safe metadata so operators can
audit migrations from the activity feed.

Behaviour:

- Targets endpoints with `provider == "openrouter"` (the bare default —
  named connections like `"openrouter:my-key"` are NEVER touched) AND a
  non-empty `api_key`.
- Groups by `api_key` value (endpoints sharing a key share one
  connection — dedup).
- Creates one Integrations connection per distinct key. Naming:
  `"openrouter:default"` for single-key deployments;
  `"openrouter:imported-1"` / `"imported-2"` / etc. for multi-key.
- Updates each endpoint's `provider` string AND `integration_uuid`
  to point at the new connection — atomically, in a single
  `Repo.update_all`.
- **Clears the legacy `api_key` column atomically with the linking**
  (set to `""`). The credential lives in exactly one place after
  migration; the runtime resolver takes the `integration_uuid` path,
  and a broken integration surfaces a loud error rather than silently
  coasting on a stale duplicate key.
- *Un*-migrated endpoints (skipped by the where-clause filter, or by
  one of the idempotency gates) keep their `api_key` populated as a
  safety-net fallback until they're explicitly handled — either via
  the manual UI workflow or a re-run of the auto-migrator after the
  blocking condition clears.

Idempotency guards (any one short-circuits): completion-flag setting,
existing `integration:openrouter:*` key in `phoenix_kit_settings`, no
endpoints needing migration. Failure modes are contained — top-level
`try/rescue/catch :exit` shell ensures the migration NEVER crashes the
host-app boot.

The migration is opt-in (you must call the function explicitly).
Operators who prefer the manual UI workflow can simply not call it —
the resolver's legacy fallback path keeps existing endpoints working
indefinitely.

The `api_key` column itself is flagged **Deprecated** in
`PhoenixKitAI.Endpoint` and is planned for removal in a future major
version.

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
    completion_test.exs                # HTTP + error parsing (unit)
    completion_coverage_test.exs       # Req.Test-stubbed integration tests
    endpoint_test.exs                  # Schema + CRUD + SSRF guard
    errors_test.exs                    # Atom → message mapping
    openrouter_client_test.exs         # API key + model discovery (unit)
    openrouter_client_coverage_test.exs# Req.Test-stubbed integration tests
    prompt_test.exs                    # Variable extraction + changeset
    prompt_changeset_test.exs          # Persistence + uniqueness
    request_test.exs                   # Schema + format_cost
    coverage_test.exs                  # Top-level public API integration
    schema_coverage_test.exs           # Schema-level edge cases
    activity_logging_test.exs          # Per-action activity log assertions
    legacy_api_key_migration_test.exs  # Auto-migrator (idempotency + dedup)
    destructive_rescue_test.exs        # DROP-TABLE-in-sandbox rescue tests
    web/                               # LiveView smoke + coverage tests
  support/                             # Test infra (DataCase, LiveCase, etc.)
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

Three OpenAI-compatible providers are wired into the endpoint form. All
share the same `Completion.chat_completion/3` HTTP path; the form's
provider dropdown drives the picker filter, default base URL, and
model-list fetcher.

| Provider | Default base URL | Models endpoint | Notes |
|---|---|---|---|
| **OpenRouter** | `https://openrouter.ai/api/v1` | `/models` (~100 aggregated chat models with pricing + modality metadata) | Models grouped by underlying provider (`anthropic`, `openai`, `meta-llama`, etc.). Embedding models served separately — see below |
| **Mistral** | `https://api.mistral.ai/v1` | `/v1/models` (chat + embedding mixed in one list) | OpenAI-compatible response. Pricing / context-length / modality fields aren't returned; the form renders sparser model cards |
| **DeepSeek** | `https://api.deepseek.com/v1` | `/models` (chat only — `deepseek-chat`, `deepseek-reasoner`) | OpenAI-compatible. Reasoner models return chain-of-thought (see Reasoning capture above) |

Each provider's connection is set up under **Settings → Integrations**
(those entries live in core's `PhoenixKit.Integrations.Providers`
registry). After validation, the picker on the AI endpoint form
filters connections to whichever provider is currently selected on
the dropdown; switching providers clears any selected integration and
resets `base_url` to the new provider's default.

Models auto-load from the chosen provider's `/models` endpoint when
the integration is picked. Slow fetches (>10s) surface a "still
loading" hint next to the spinner; failed fetches show a Retry button
on the error pane so operators can recover from transient upstream
issues without re-picking the integration.

**Embedding models for OpenRouter** are NOT returned by `/models` —
OpenRouter proxies embeddings via `POST /api/v1/embeddings` but
doesn't list them anywhere queryable. The embedding-model dropdown
for OpenRouter endpoints is backed by a curated list in
`OpenRouterClient.builtin_embedding_models/0` (last refreshed in
source); extensible via:

```elixir
config :phoenix_kit_ai,
  embedding_models: [
    %{"id" => "custom/embedding-model", "name" => "Custom",
      "context_length" => 8192, "dimensions" => 1024,
      "pricing" => %{"prompt" => 0.00000001, "completion" => 0}}
  ]
```

Mistral exposes embedding models in the same `/v1/models` list as
chat models (`mistral-embed`, `codestral-embed`); operators select
the right one manually. DeepSeek currently exposes chat models only.

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
