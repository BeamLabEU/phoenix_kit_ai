# AGENTS.md

Guidance for AI agents working in this repository.

## Project Overview

PhoenixKit AI module — AI endpoint management, prompt templates, chat completions, text-to-speech, embeddings, and usage tracking via OpenAI-compatible providers discovered at runtime from the `PhoenixKit.Integrations` registry (`PhoenixKit.Integrations.Providers.with_capability(:ai_completions)`). Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

## What This Module Does NOT Have (by design)

- **No DB migrations of its own** — tables (`phoenix_kit_ai_endpoints`, `_prompts`, `_requests`) are created by versioned migrations in core `phoenix_kit`. Adding a column = core migration first, then schema + changeset edits here.
- **No per-completion Activity logging** — `PhoenixKit.Activity.log/1` runs only on endpoint/prompt CRUD + enable/disable toggles (both success AND failure branches, via `log_failed_*_mutation/3` pipe-step helpers with PII-safe `error_keys` metadata). Per-request usage already lives in `phoenix_kit_ai_requests`.
- **No forced legacy `endpoint.api_key` migration** — `OpenRouterClient.resolve_api_key/1` keeps pre-Integrations endpoints working via a 3-tier fallback (`integration_uuid` → legacy `provider` string → `api_key` column, with a `Logger.warning` only when it reaches the column). Opt-in orchestrator: call `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from `Application.start/2` (invokes `PhoenixKitAI.migrate_legacy/0`, which folds legacy api_keys into Integration connections — atomically clearing the legacy column — and sweeps `provider`-string refs to `integration_uuid`). Saving an endpoint with an integration picked also clears the legacy column atomically (`maybe_clear_legacy_api_key/1`).
- **No public HTTP/API surface** — admin-only; consumers call the `PhoenixKitAI` context module.
- **No Oban for completions** — chat/TTS/embed run synchronously; Oban is used only for the AI-translation pipeline (`PhoenixKitAI.TranslateWorker`).
- **No streaming responses** — `Completion` returns full `{:ok, response}`; the Playground UI is request/response.

## Common Commands

```bash
mix deps.get                # Install dependencies
createdb phoenix_kit_ai_test # Create test DB (first time only)
mix test                    # All tests (integration tests auto-excluded without the DB)
mix test test/phoenix_kit_ai/completion_test.exs:25   # Specific test by line
mix format                  # Format (imports Phoenix LiveView rules)
mix credo --strict          # Lint
mix dialyzer                # Type checking
mix precommit               # compile + format + credo --strict + dialyzer — run before every commit
```

## Dependencies & cross-repo development

This is a **library** — the host app provides endpoint/router; `config/` exists only for tests. Deps: `phoenix_kit` (~> 1.7; Module behaviour, Settings, components, RepoHelper, Activity, Integrations), `phoenix_live_view`, `req` + `jason` (via phoenix_kit), `lazy_html` (test only), `rustler` (optional, lets the transitive `mdex_native` NIF source-build).

Sibling `phoenix_kit*` deps resolve from Hex by default. To build against a local checkout, export `<APP>_PATH`:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Unset = the published pin (so publishing and CI are unaffected). Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*` dep into a `path:` tuple.

## Architecture

PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config). `admin_tabs/0` registers admin pages; `route_module/0` (`PhoenixKitAI.Routes`) adds sub-routes (new/edit forms, usage). Settings via `PhoenixKit.Settings`; permissions via `permission_metadata/0` + `Scope.has_module_access?/2`. API keys live centrally in `PhoenixKit.Integrations`; each endpoint pins one connection by `integration_uuid`. `required_integrations: ["openrouter"]` — Mistral/DeepSeek/OpenAI also work but aren't required.

Key modules (`lib/phoenix_kit_ai/` unless noted):

- `../phoenix_kit_ai.ex` — `PhoenixKitAI`: Module behaviour + context for all operations
- `endpoint.ex` / `prompt.ex` / `request.ex` — Ecto schemas (endpoint config, `{{Variable}}` templates, request logging)
- `completion.ex` — provider-agnostic HTTP client (chat, embeddings, TTS). Builds `<base_url>/chat/completions` etc.; missing `base_url` falls back to `Endpoint.default_base_url(provider)`, raises `ArgumentError` rather than misrouting. `extract_content/1`, `extract_reasoning/1` (normalises `reasoning` / `reasoning_content` / `thinking`)
- `openrouter_client.ex` — despite the name, generic across providers: API key validation, model/voice discovery (`fetch_models_grouped/2` takes `:base_url` and `:fallback_provider` opts for slash-less IDs like Mistral/DeepSeek), credential resolution with the 3-tier fallback. 15s timeout for `/models`; chat gets 120s in `Completion`
- `errors.ex` — error atom → gettext string (`Errors.message/1`)
- `ai_model.ex`, `routes.ex` — model struct; admin sub-routes
- `translatable.ex` / `translatables.ex` / `translation.ex` / `translations.ex` / `translate_worker.ex` — generic AI-translation pipeline (adapter behaviour, duck-typed `ai_translatables/0` discovery, Oban worker, enqueue/dedup/broadcast)
- `web/` — admin LiveViews (Endpoints, EndpointForm, Prompts, PromptForm, Playground) + `components/ai_translate/*`

## Critical Conventions

- **Module key** `"ai"` everywhere; **tab IDs** prefixed `:admin_ai_`; **URL paths** use hyphens (`"ai/endpoints"`)
- **Navigation paths**: always `PhoenixKit.Utils.Routes.path/1`, never relative
- **`enabled?/0`** must rescue and return `false` (DB may be down)
- **LiveViews**: `use PhoenixKitWeb, :live_view` (not `Phoenix.LiveView` directly; imports Gettext). Admin assigns: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **JS hooks**: inline `<script>` tags, register on `window.PhoenixKitHooks`
- **Costs** stored in nanodollars in `cost_cents`
- **Error returns**: atoms or `{atom, detail}` tuples, surfaced via `PhoenixKitAI.Errors.message/1`
- **Translatable strings**: everything user-visible through `gettext(...)`; `.po` files live in core `phoenix_kit`, never here
- **Commit messages** start with `Add` / `Update` / `Fix` / `Remove` / `Merge`

## Routing

> ⚠️ **Never hand-register plugin LiveView routes in the parent app's `router.ex`.** PhoenixKit injects module routes into its own `live_session :phoenix_kit_admin` automatically; a hand-written route loses the admin layout and crashes socket navigation.

Multi-page route-module pattern: `PhoenixKitAI.Routes` defines `admin_routes/0` and `admin_locale_routes/0`; tabs (Endpoints, Prompts, Playground, Usage) are declared in `admin_tabs/0`. Discovery: `use PhoenixKit.Module` persists a beam marker → `ModuleDiscovery` scans deps of `:phoenix_kit` → routes compiled into the host router via `phoenix_kit_routes()`.

Tailwind: `css_sources/0` returns `[:phoenix_kit_ai]` so the installer adds the right `@source` directive — without it, module-specific classes get purged.

## Multi-provider support

Providers come from the Integrations registry — no hardcoded whitelist. `Endpoint.valid_providers/0`, `provider_options/0`, `default_base_url/1`, `provider_label/1` all read registry entries. Built-ins with `:ai_completions`: `openrouter`, `mistral`, `deepseek`, `openai`. **Adding a provider = one registry entry in core** (`capabilities: [:ai_completions]` + `base_url`); zero edits here, provided the API exposes `<base_url>/chat/completions` and `/models`.

- The changeset does **not** `validate_inclusion(:provider, …)` — legacy rows hold UUIDs or `provider:name` strings; the UI dropdown is the enforcement surface.
- **Provider switch in the form** clears integration, model list/params, `provider_settings["voice"]`, and `base_url` — cleared with `""`, not `nil` (the template's `@form.params[...] || @endpoint...` fallback treats `nil` as "no intent"; `""` is truthy).
- **The integration picker never auto-picks**, even with one connection — `active_connection` is set only from what the endpoint is actually pinned to. Orphaned `integration_uuid` renders a "deleted/missing" warning card; no silent rebinding on PubSub changes.
- OpenRouter `/models` excludes embeddings — curated list in `OpenRouterClient.builtin_embedding_models/0`. Mistral `/v1/models` returns chat + embeddings together; `/audio/voices` feeds the TTS voice picker.
- Endpoint cards show enabled badge + integration-health badge (missing/error/not-connected) + masked key (first-8 + last-4 via `Web.Endpoints.mask_api_key/1`; short keys → `•••`). `integrations_by_uuid` is loaded once per render to avoid N+1.
- Endpoint form model-fetch UX: `models_loading` / `models_loading_slow` (10s hint) / `models_error` with Retry, consolidated in `start/stop_model_fetch_indicators/1`.

## Completion behaviour notes

- **Reasoning capture**: `extract_reasoning/1` → persisted to `phoenix_kit_ai_requests.metadata.response_reasoning` (`PhoenixKitAI.log_request/7`), rendered collapsed in the Usage modal. Gated by `capture_request_content?/0` like response content (PII-equivalent).
- **TTS**: `PhoenixKitAI.speak/3` → `Completion.text_to_speech/3` posts `<base_url>/audio/speech`; decodes Mistral base64-JSON and raw binary. Returns `{:ok, %{audio, format}}`. Endpoint form has a `:text`/`:tts` model-type selector (heuristic: `tts` substring in id/name); switching clears the model. Default voice in `provider_settings["voice"]` (`voice_id` field for Mistral, `voice` otherwise). TTS logs use `request_type: "tts"` with `input_chars`/`audio_format`/`audio_bytes`, same PII gate.

## Settings & config

Settings table: `ai_enabled` (boolean, default `false`) — module toggle.

Application env:

| Key | Default | Purpose |
|-----|---------|---------|
| `:capture_request_content` | `true` | Persist message/response content in request `metadata`; `false` writes `content_redacted: true` instead (tokens/latency/cost still recorded) |
| `:capture_request_memory` | `false` | Opt-in per-request `:memory` snapshot in metadata — debug only |
| `:allow_internal_endpoint_urls` | `false` | Bypass the SSRF guard on `Endpoint.base_url` (loopback/RFC1918/`*.local`/non-http(s) rejected) — for self-hosted Ollama etc. |
| `:embedding_models` | `[]` | Extra embedding models appended to `OpenRouterClient.fetch_embedding_models/2`; non-list values warned + ignored |
| `:req_options` | `[]` | Extra `Req` opts appended to every HTTP call — tests use it for `Req.Test` plug stubs |

## Testing

- **Unit tests** (no DB, always run) and **integration tests** (PostgreSQL sandbox; `PhoenixKitAI.DataCase`/`LiveCase` auto-tag `:integration`, auto-excluded without the DB).
- Test DB `phoenix_kit_ai_test` uses `PhoenixKitAI.Test.Repo` (`test/support/test_repo.ex`); `test/test_helper.exs` runs core's versioned migrations directly — no module-owned DDL.
- `test/support/`: `test_endpoint.ex` / `test_router.ex` / `test_layouts.ex` (minimal Phoenix stack), `live_case.ex` (`fixture_endpoint/1`, `seed_openrouter_connection/2`, `fake_scope/1`, …), `data_case.ex`, `hooks.ex` (`:assign_scope` on_mount), `activity_log_assertions.ex` (`assert/refute_activity_logged/2`). Router scopes at `/en/admin/ai/…`.
- Destructive rescue tests: `test/phoenix_kit_ai/destructive_rescue_test.exs` (`async: false`); the LV-mounted one is tagged `:destructive`, opt-in via `--include destructive`.
- `test/phoenix_kit_ai_test.exs` verifies the behaviour callbacks (`module_key/0`, `version/0`, `admin_tabs/0`, …).

## Versioning & Releases

SemVer. Bump the version in **three places**: `mix.exs` `@version`, `lib/phoenix_kit_ai.ex` `version/0`, and the version test in `test/phoenix_kit_ai_test.exs`.

Release checklist:

1. Bump the three version locations; add a `CHANGELOG.md` entry
2. `mix precommit` — zero warnings/errors
3. Commit (`"Bump version to x.y.z"`), push to main, **verify the push**
4. Tag with bare version (no `v`): `git tag x.y.z && git push origin x.y.z`
5. `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "<changelog section>"`

**Never tag before all changes are committed and pushed** — tags are immutable pointers.

## Pull Requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md` (see `dev_docs/pull_requests/README.md`). Every PR folder gets a `FOLLOW_UP.md` once triaged (a stub if no findings) — no `FOLLOW_UP.md` means "not triaged yet".

## Deferred refactors (don't do as standalone work)

- `metadata.error_reason` is stored via `inspect/1` (`log_failed_request/7`, `log_failed_embedding_request/5`) — a raw `reason` value would filter better via JSONB, but no consumer filters on it yet. If refactored, update the assertion pinning `"{:connection_error, :nxdomain}"` in `test/phoenix_kit_ai/completion_coverage_test.exs`.
