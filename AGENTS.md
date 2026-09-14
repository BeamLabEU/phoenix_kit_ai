# AGENTS.md

Guidance for AI agents working on `phoenix_kit_ai`.

## Overview

AI endpoint management, prompt templates, chat completions, embeddings,
text-to-speech, image generation and editing, realtime voice, and per-request
usage tracking. Providers are OpenAI-compatible and are discovered at runtime
from core's `PhoenixKit.Integrations` registry
(`PhoenixKit.Integrations.Providers.with_capability(:ai_completions)`), so there
is no hardcoded provider whitelist. Implements the `PhoenixKit.Module`
behaviour for auto-discovery by the host application; it is a library, and the
host supplies endpoint and router (`config/` exists only for tests).

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex). No sibling `phoenix_kit_*`
  deps. Non-kit deps: `phoenix_live_view` `~> 1.1`, `gettext` `~> 1.0`, `xai`
  `~> 0.2` (realtime voice only — `Xai.Realtime`; `gun`/`mint` are deliberately
  not added so cowlib's CVE surface stays out of the tree), `rustler`
  (optional, lets the transitive `mdex_native` NIF source-build), plus
  `lazy_html` and `mox` in `:test`.
- **Consumed by:** `phoenix_kit_catalogue`, `phoenix_kit_publishing`,
  `phoenix_kit_projects`, `phoenix_kit_restyle`, `phoenix_kit_ecommerce` — all
  through the `PhoenixKitAI` context module.
- **Admin surface:** one parent tab `AI` at `ai` with four subtabs —
  `ai/endpoints`, `ai/prompts`, `ai/playground`, `ai/usage`. Sub-routes for the
  new/edit forms come from `route_module/0`.
- **Module key** `"ai"`; settings prefix `ai_`.

## What this module does NOT do

- **No DB migrations of its own.** Tables are created by core's versioned
  chain. Adding a column is a core migration first, then schema + changeset
  edits here.
- **No per-completion Activity logging.** `PhoenixKit.Activity.log/1` runs on
  endpoint/prompt CRUD and enable/disable toggles, on both the success and
  failure branches, via the `log_failed_*_mutation/3` pipe-step helpers with
  PII-safe `error_keys` metadata, and on each terminal outcome of an AI
  translation job (`ai.translation_added` / `ai.translation_failed`, the
  latter carrying only a static classification tag, never the raw reason).
  Per-request usage already lives in `phoenix_kit_ai_requests`.
- **No forced legacy `endpoint.api_key` migration.**
  `OpenRouterClient.resolve_api_key/1` keeps pre-Integrations endpoints working
  through a three-tier fallback (`integration_uuid` → legacy `provider` string →
  `api_key` column, with a `Logger.warning` only when it reaches the column).
  The migration is opt-in: a host calls
  `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from
  `Application.start/2`, which invokes `PhoenixKitAI.migrate_legacy/0`.
- **No public HTTP/API surface.** Admin-only; consumers call the `PhoenixKitAI`
  context module.
- **No file storage.** Image verbs take bytes or URLs in and hand bytes back;
  the caller stores results (core's Storage, usually). Only the request row
  is kept, and never the image bytes.
- **No `gun` dependency, on purpose** (see Depends-on: cowlib's CVE
  surface). The `:gun.*` compile warnings a host may see come from the
  optional WebSocket adapter inside the `xai` package; they are harmless
  unless the host runs realtime voice, and that host owns the decision to
  add `gun` itself.
- **No Oban for completions.** Chat, TTS, embeddings and image calls run
  synchronously. Oban is used only by the AI-translation pipeline
  (`PhoenixKitAI.TranslateWorker`).
- **No streaming chat responses.** `Completion` returns a full
  `{:ok, response}` and the Playground is request/response. Realtime *voice* is
  the one streaming path, and it is a separate WebSocket transport.

## Commands

```bash
mix deps.get
createdb phoenix_kit_ai_test # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Other useful invocations:

```bash
mix test test/phoenix_kit_ai/completion_test.exs:25   # one test by line
mix test --include destructive                        # opt-in destructive-rescue LV test
```

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- **Module key** `"ai"` everywhere; **tab ids** prefixed `:admin_ai_`; **URL
  segments** use hyphens, never underscores (`"ai/endpoints"`). A test asserts
  no tab path contains `_`.
- **Paths** always come from `PhoenixKit.Utils.Routes.path/1`, or from
  `PhoenixKitAI.Routes.ai_path/0` which wraps it — never a hardcoded or
  relative string.
- **Routing** uses the route-module pattern: `PhoenixKitAI.Routes` defines
  `admin_routes/0` and `admin_locale_routes/0`, the same routes with and
  without the `/:locale` prefix, and `route_module/0` returns it. Tabs are
  declared in `admin_tabs/0` with `path:`, not `live_view:`. Never hand-register
  a plugin LiveView route in the host's `router.ex` — PhoenixKit injects module
  routes into its own `live_session :phoenix_kit_admin`, and a hand-written
  route loses the admin layout and crashes socket navigation.
- **LiveViews** `use PhoenixKitWeb, :live_view`, and every LiveView or component
  that calls `gettext(...)` **also** needs `use Gettext, backend:
  PhoenixKitAI.Gettext` on the line immediately after it. `:live_view` imports
  gettext macros bound to core's `PhoenixKitWeb.Gettext`; without the module's
  own line, calls resolve against core's catalogue instead of this module's
  `priv/gettext/` with no compile error. Admin LiveViews do not wrap templates
  in `LayoutWrapper`. Admin assigns available: `@phoenix_kit_current_scope`,
  `@current_locale`, `@url_path`.
- **Gettext backend** is this module's own `PhoenixKitAI.Gettext`
  (`otp_app: :phoenix_kit_ai`), catalogues in this repo's `priv/gettext/`
  (`en`, `et`, `ru`) — not core's. After adding a string run
  `mix gettext.extract && mix gettext.merge priv/gettext`, then fill the `et`
  and `ru` `msgstr`s by hand. `mix gettext.merge` deletes any `.po` entry
  missing from a freshly extracted `.pot`, so a string can never be hand-typed
  into a `.po` alone. Labels declared as plain string literals in
  `admin_tabs/0` and `permission_metadata/0` are invisible to the extractor and
  are anchored by `PhoenixKitAI.translatable_labels/0` via `dgettext_noop/2`;
  adding a tab or renaming a label means adding the msgid there too. `priv`
  must stay in the package `files:` or every Hex install renders raw msgids.
  Core's `guides/per-module-i18n.md` has the full setup.
- **JS hooks** ship in the prebuilt bundle `priv/static/assets/phoenix_kit_ai.js`
  under the namespaced global `PhoenixKitAIHooks`, declared by `js_sources/0`
  and folded into `window.PhoenixKitHooks` by the `:phoenix_kit_js_sources`
  compiler. That fold is last-write-wins across every module's bundle and
  core's own hooks, so a new hook's name carries the `PhoenixKitAI` prefix
  (`PhoenixKitAIModelGridSearch`, not `ModelGridSearch`). Prefer an existing
  core hook (`ResetSelect`, `CopyToClipboard`) before writing one. Never
  register a hook from an inline `<script>`: morphdom does not execute inserted
  script tags, so an inline hook vanishes on LiveView navigation.
- **Tailwind** classes are kept by `css_sources/0` returning
  `[:phoenix_kit_ai]`, which makes the installer add the right `@source`
  directive; without it module-specific classes get purged.
- **`enabled?/0`** must return `false` on any failure — it `rescue`s **and**
  `catch`es `:exit`, because a shutting-down connection pool exits rather than
  raising.
- **Activity logging** goes through the `log_failed_*_mutation/3` pipe-step
  helpers so failures are logged as well as successes, with PII-safe
  `error_keys` metadata instead of raw values. `PhoenixKitAI.Translation` also
  writes one `core.ai_translation.requested` entry per dispatched translation,
  giving a unified audit trail of AI spend across every consuming module.
- **Request-content PII gate**: message bodies, response content and captured
  reasoning are all persisted only when `capture_request_content?/0` is true;
  otherwise the row records `content_redacted: true` and keeps tokens, latency,
  model and cost. Any new field carrying user text must sit behind the same
  gate.
- **Costs** are stored in nanodollars.
- **Error returns** are atoms or `{atom, detail}` tuples, rendered through
  `PhoenixKitAI.Errors.message/1`.
- No soft-delete sentinel: endpoints and prompts are hard-deleted.

### Landmines

- **A hook that filters or stamps must reapply itself on every patch.** Two
  in this bundle used to resolve once at `mounted()` and never again.
  `PhoenixKitAIModelGridSearch` keeps its filter in inline `style.display` on
  the CARDS, so cards arriving from a discovery round-trip render visible
  under a query still typed in the box, and morphdom resets the style on any
  card it re-renders — and because the hook is on the INPUT, a patch to the
  grid alone never calls its `updated()`. It watches the grid with a
  `MutationObserver` (childList only, so its own style writes cannot
  re-trigger it) and reapplies from `updated()` too.
  `PhoenixKitAIManualModelInput` re-resolves its sibling submit button on
  every patch instead of caching it: a patch can replace the button while
  leaving the input in place, and a cached reference then stamps
  `phx-value-model` onto a detached node.

- No template here carries an inline `<script>`, and none may: morphdom never
  runs a script tag it inserts, so a hook registered that way works on a hard
  page load and silently does nothing after a `live_redirect` (the console
  reads `unknown hook found for "…"`). Every hook lives in
  `priv/static/assets/phoenix_kit_ai.js` — `PhoenixKitAIManualModelInput` and
  `PhoenixKitAIModelGridSearch` for the endpoint form, `PhoenixKitAIScrollIntoView`
  on the playground's `#playground-response` container, `XaiVoiceStream` for
  realtime audio. The scroll hook is the shape to copy for a page-level
  listener: the cards dispatch `phx:scroll-into-view` on themselves via
  `phx-mounted` and it bubbles to the container hook, which binds in
  `mounted()` and unbinds in `destroyed()`. A `document.addEventListener` in
  `mounted()` would instead leak one live handler per navigation.
- The `cost_cents` column holds **nanodollars** (1/1,000,000 of a dollar),
  not cents — the name is legacy. Reading it as cents is off by seven orders of
  magnitude. The spend-cap settings use the same unit: `5_000_000` is $5.
- `user_uuid:` on a verb must be a PhoenixKit user uuid. The usage row has a
  foreign key on it, so an anonymous or external id means the provider is
  paid and the row is *not written* (logged as a warning) — which also
  blinds the per-user cap. Cap the endpoint or the site for visitors.
- Spend caps read the usage table; concurrent callers overshoot by their
  in-flight calls, and a database error fails open. Treat a cap as a brake
  on a runaway day, not as a hard invoice ceiling.
- The request cache is ETS on one node: it empties on restart, is shared
  across users (scope a caller `key:` yourself), and without the module's
  supervisor tree every lookup is a silent miss. Never use it as the store
  for "write once, keep forever".
- Clearing a field in the endpoint form must write `""`, not `nil`. The
  template's `@form.params[...] || @endpoint...` fallback treats `nil` as "no
  intent" and the old value reappears; `""` is truthy and wins.
- Do not combine `PGDATABASE=<shared db>` with `PHOENIX_KIT_PATH=../phoenix_kit`.
  `test_helper.exs` would then run the *local* core's migration chain against
  the shared database, moving the schema for every other module pointed at it.
- A `gettext(...)` call written *above* the `use Gettext, backend:
  PhoenixKitAI.Gettext` line in the same file binds to whichever backend was in
  scope at that point — core's. The symptom is silent: a msgid that also exists
  in core returns core's translation, one that does not returns raw English.

## Architecture

PhoenixKit scans `.beam` files at startup and auto-discovers modules with zero
host configuration: `use PhoenixKit.Module` persists a beam marker,
`ModuleDiscovery` scans the deps of `:phoenix_kit`, and routes are compiled into
the host router via `phoenix_kit_routes()`. API keys live centrally in
`PhoenixKit.Integrations`; each endpoint pins exactly one connection by
`integration_uuid`. `required_integrations/0` returns `["openrouter"]` —
Mistral, DeepSeek, OpenAI and xAI also work but are not required.

```
lib/phoenix_kit_ai.ex            PhoenixKitAI — Module behaviour + the whole public context
lib/phoenix_kit_ai/
  endpoint.ex prompt.ex request.ex   Ecto schemas
  completion.ex                  provider-agnostic HTTP client (chat, embeddings, TTS); image verbs delegate to adapters
  provider.ex                    PhoenixKitAI.Provider behaviour + adapter resolution by provider key
  providers/                     adapters: openrouter (unified /images), xai, openai (multipart), openai_compatible (chat parts), http (shared Req door)
  images.ex images/              generic image layer: operations → prompt, option fitting, describe/compare, model-capability cache
  openrouter_client.ex           generic across providers despite the name
  errors.ex                      error atom -> gettext string
  ai_model.ex routes.ex          model struct; admin sub-routes
  gettext.ex                     PhoenixKitAI.Gettext backend
  tts_pricing.ex                 hand-maintained TTS rate table
  realtime/session.ex            one xAI realtime WebSocket per Playground LiveView
  translat*.ex translate_worker.ex   generic AI-translation pipeline
  components/ai_translate*       reusable translate button/glue components
  web/                           admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground
```

Notes on the less obvious modules:

- `completion.ex` builds `<base_url>/chat/completions` and friends; a missing
  `base_url` falls back to `Endpoint.default_base_url(provider)` and raises
  `ArgumentError` rather than misrouting the request. `extract_content/1` and
  `extract_reasoning/1` normalise the `reasoning` / `reasoning_content` /
  `thinking` variants.
- `openrouter_client.ex` handles API-key validation, model and voice discovery
  (`fetch_models_grouped/2` takes `:base_url` and `:fallback_provider` for
  slash-less model ids like Mistral's and DeepSeek's) and the three-tier
  credential resolution. `/models` gets a 15s timeout; chat gets 120s in
  `Completion`.
- `realtime/session.ex` is a `GenServer` under the `DynamicSupervisor`
  contributed by `children/0`, `restart: :temporary`. The WebSocket links to the
  session, not the LiveView, so a socket crash only kills the session; the
  reverse direction is handled by monitoring the LiveView pid, because
  LiveView's `terminate/2` is not reliably called.
- `translation.ex` is the single orchestration layer every consuming module
  wraps in its own worker: prompt rendering with `{{SourceLanguage}}` /
  `{{TargetLanguage}}` / arbitrary field variables, a parser for the
  `---FIELD_NAME---` response shape, and error normalisation so every failure
  path returns `{:error, atom_or_tuple}`. Adapters are duck-typed through
  `ai_translatables/0` discovery.

### Data model

| Table | Schema | Notes |
|---|---|---|
| `phoenix_kit_ai_endpoints` | `PhoenixKitAI.Endpoint` | provider credentials, model, generation params, `provider_settings` |
| `phoenix_kit_ai_prompts` | `PhoenixKitAI.Prompt` | `{{Variable}}` templates |
| `phoenix_kit_ai_requests` | `PhoenixKitAI.Request` | per-request usage log |

### PubSub topics

| Topic | Subscribe helper |
|---|---|
| `phoenix_kit:ai:endpoints` | `subscribe_endpoints/0` |
| `phoenix_kit:ai:prompts` | `subscribe_prompts/0` |
| `phoenix_kit:ai:requests` | `subscribe_requests/0` |

### Settings & permissions

Settings: `ai_enabled` (boolean, default `false`) is the module toggle;
`ai_legacy_api_key_migration_completed_at` is the idempotency marker for
`migrate_legacy/0`. Spend caps (`PhoenixKitAI.Budget`): `ai_daily_budget`,
`ai_daily_budget_per_endpoint`, `ai_daily_budget_per_user` — nanodollars per
trailing 24 hours, `0` = no cap — and `ai_budget_warn_percent` (default 80),
read through the settings cache. Every provider-calling verb (not the
realtime voice session) checks them first and returns
`{:error, {:budget_exceeded, scope}}` once one is reached, cached answers
included; only a `process_image/4` dry run skips the check (no other verb
honours `dry_run:`).

Permissions: a single module permission `"ai"` from `permission_metadata/0`,
checked with `Scope.has_module_access?/2`. No sub-permissions.

### Application env

| Key | Default | Purpose |
|-----|---------|---------|
| `:capture_request_content` | `true` | Persist message/response content in request `metadata`; `false` writes `content_redacted: true` instead (tokens/latency/cost still recorded) |
| `:capture_request_memory` | `false` | Opt-in per-request `:memory` snapshot in metadata — debug only |
| `:allow_internal_endpoint_urls` | `false` | Bypass the SSRF guard on `Endpoint.base_url` (loopback/RFC1918/`*.local`/non-http(s) rejected) — for self-hosted Ollama etc. |
| `:embedding_models` | `[]` | Extra embedding models appended to `OpenRouterClient.fetch_embedding_models/2`; non-list values are warned about and ignored |
| `:req_options` | `[]` | Extra `Req` opts appended to every HTTP call — tests use it for `Req.Test` plug stubs |
| `:realtime_module` | `Xai.Realtime` | Swappable realtime client; tests point it at a Mox mock of `Xai.RealtimeBehaviour` |
| `:provider_adapters` | `%{}` | Provider key → `PhoenixKitAI.Provider` module, merged over the built-in adapters (add a provider without touching this module) |
| `:image_operations` | `%{}` | Extra or replacement image operations for `PhoenixKitAI.Images.Operations` (string or atom keys) |
| `:max_image_bytes` | `25_000_000` | Largest image accepted as input or fetched as output by the image verbs |
| `:translatables` | `[]` | `[{resource_type, adapter_module}]` a host app registers for the AI-translation pipeline without being a kit module; configured entries win over module-declared ones |
| `:request_cache` | `[]` | `ttl:` (seconds, default 86 400), `sweep:` (300), `max_entries:` (10 000), `max_value_bytes:` (8 000 000), `default:` (`true` caches every verb unless a call says `cache: false`); read per call by `PhoenixKitAI.RequestCache` |
| `:allow_internal_image_urls` | `false` | Lift the image-fetch host policy (loopback / link-local / RFC 1918 / `.local`, resolved addresses included) — tests and air-gapped installs only; separate from the endpoint base-URL switch |

### Providers

Provider data comes from the Integrations registry, so `Endpoint.valid_providers/0`,
`provider_options/0`, `default_base_url/1` and `provider_label/1` all read
registry entries. **Adding a provider is one registry entry in core**
(`capabilities: [:ai_completions]` plus `base_url`) and zero edits here,
provided the API exposes `<base_url>/chat/completions` and `/models`.

- The changeset deliberately does **not** `validate_inclusion(:provider, …)`:
  legacy rows hold UUIDs or `provider:name` strings, and the UI dropdown is the
  enforcement surface.
- Switching provider in the form clears the integration, model list and params,
  `provider_settings["voice"]` and `base_url` — with `""`, per the landmine
  above.
- **The integration picker never auto-picks**, even when exactly one connection
  exists. `active_connection` is set only from what the endpoint is actually
  pinned to. An orphaned `integration_uuid` renders a "deleted/missing" warning
  card; there is no silent rebinding on PubSub changes.
- OpenRouter's `/models` excludes embeddings, so a curated list in
  `OpenRouterClient` supplies them. Mistral's `/v1/models` returns chat and
  embeddings together, and its `/audio/voices` feeds the TTS voice picker.
- Endpoint cards show an enabled badge, an integration-health badge
  (missing/error/not-connected), and a masked key via
  `Endpoint.masked_api_key/1`. `integrations_by_uuid` is loaded once per render
  to avoid an N+1.
- **Image verbs pick an adapter by provider key** (`PhoenixKitAI.Provider.for_endpoint/1`):
  OpenRouter, xAI and OpenAI have their own; everything else gets the
  OpenAI-compatible default. A new image provider is an adapter module plus
  a `:provider_adapters` entry — no edits to `Completion` or `Images`.
- Endpoint-form model fetching drives `models_loading` /
  `models_loading_slow` (10s hint) / `models_error` with Retry, all consolidated
  in `start/stop_model_fetch_indicators/1`.

### Completion behaviour

- **Reasoning capture**: `extract_reasoning/1` is persisted to
  `phoenix_kit_ai_requests.metadata.response_reasoning` by `log_request/8` and
  rendered collapsed in the Usage modal, behind the PII gate.
- **Image editing and processing**: `edit_image/4` takes reference images
  (bytes, `%{data:, content_type:}`, `%{url:}`, or data/http URL strings,
  all inlined as data URLs) plus a prompt and canonical options, and hands
  them to the endpoint's adapter: OpenRouter → `POST /images` with
  `input_references` (`transport: :chat` keeps the chat-completions path
  with `modalities`/`usage.include`); xAI → JSON `/images/edits`; OpenAI →
  multipart `/images/edits`; anything else → chat completions with
  `image_url` parts. `process_image/4` is the generic entry point: named
  operations become one prompt, options are fitted to the model's published
  capabilities (dropped with a warning, or refused under `strict: true`),
  and `verify: true` attaches a vision check of the result.
  `describe_image/3` / `extract_text/3` / `compare_images/4` are the
  vision verbs (`"vision"` request type) through the adapter's optional
  `vision/3`; `extract_text/3` is OCR by vision model — a fixed schema
  (text, typed blocks, language, confidence) plus caller `fields:`. Outputs are
  always bytes (URL results are fetched, bounded, same host policy as
  inputs); `dry_run: true` returns the plan without a request; a safety
  refusal is `{:content_policy, message}`. A prose-only answer is
  `{:error, {:no_image_in_response, text}}`.
  Logged with tokens, `usage.cost` when reported, image counts and byte
  sizes, operations and warnings; the image bytes themselves are never
  persisted. **Never send a provider a permanent Storage URL — inline the
  bytes.** `dev_docs/guides/image-processing.md` has the full picture.
- **Image generation**: `generate_image/3` goes through the endpoint's
  adapter (OpenRouter `POST /images`, everyone else `/images/generations`)
  and fills omitted options from the endpoint's stored defaults —
  `image_size` / `image_quality` columns and `provider_settings["aspect_ratio"]`
  / `["resolution"]` — but only the ones the adapter can send (xAI takes no
  `size`).
- **TTS**: `speak/3` posts to `<base_url>/audio/speech` and decodes both
  Mistral's base64 JSON and raw binary, returning `{:ok, %{audio, format}}`.
  The endpoint form has a `:text`/`:tts` model-type selector (heuristic: a
  `tts` substring in the id or name) and switching it clears the model. The
  default voice lives in `provider_settings["voice"]` — key `voice_id` for
  Mistral, `voice` otherwise. Logged as `request_type: "tts"` with
  `input_chars` / `audio_format` / `audio_bytes`, same PII gate. No provider
  reports a TTS cost, so `TtsPricing` estimates it from a hand-maintained rate
  table.

## Database & migrations

None. Tables `phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts` and
`phoenix_kit_ai_requests` ship in core's versioned chain; `migration_module/0`
is unset and this module owns no DDL. A schema change is a core migration
first, then the schema and changeset edits here.

Primary keys are UUIDv7 (`@primary_key {:uuid, UUIDv7, autogenerate: true}`),
and every table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
target the schema core's migrations installed into — a conformance test asserts
this, because a missing prefix is invisible on public installs and broken on
prefixed ones.

`Request` declares `foreign_key_constraint` for `endpoint_uuid`, `user_uuid`
and `prompt_uuid`; the prompt constraint has to tolerate two possible index
names, because databases created before and after the named-constraint change
carry different ones.

## Testing

Test database `phoenix_kit_ai_test`.

- **Unit tests** (schemas, changesets, pure functions) always run. **Integration
  tests** need PostgreSQL — `PhoenixKitAI.DataCase` and `LiveCase` auto-tag
  `:integration`, and `test_helper.exs` excludes that tag when the database is
  absent, after probing with `psql -lqt` and falling back to a connect attempt.
- The schema is built by `PhoenixKit.Migration.ensure_current(TestRepo, log: false)`
  — core's own chain, the same call a host makes. It re-applies newly shipped
  migrations on every boot; the older `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], …)`
  pattern silently stopped re-applying once `0` was recorded in
  `schema_migrations`, so never reintroduce it.
- `test_helper.exs` explicitly `Code.require_file`s the support modules (Elixir
  1.19's `mix test` no longer auto-loads them), then boots the minimal runtime
  the suite needs: `PhoenixKit.PubSub.Manager`, `PhoenixKit.ModuleRegistry`,
  `PhoenixKit.Users.RateLimiter.Backend` (without it user fixtures die on a
  missing ETS table), `PhoenixKit.TaskSupervisor` (the endpoint form's
  validate-then-fetch uses `Task.Supervisor.start_child/2`),
  `PhoenixKitAI.Realtime.Supervisor`, and the test `Endpoint` with
  `server: false`. It also forces the URL-prefix cache so admin paths resolve
  under `/en/admin/ai/…`, which is what the test router scopes.
- `test/support/`: `test_repo.ex`, `test_endpoint.ex`, `test_router.ex`,
  `test_layouts.ex` (minimal Phoenix stack), `data_case.ex`, `live_case.ex`
  (`fixture_endpoint/1`, `seed_openrouter_connection/2`, `fake_scope/1`),
  `hooks.ex` (the `:assign_scope` `on_mount`), and `activity_log_assertions.ex`
  (`assert_activity_logged/2` / `refute_activity_logged/2`).
- `config/test.exs` reads `PGDATABASE` and `PGPOOL` for the repo's `database:`
  and `pool_size:`, falling back to `phoenix_kit_ai_test` and
  `System.schedulers_online() * 2`. Set both to point the suite at a database
  it does not own, e.g. one shared with sibling modules — but see the landmine
  about combining it with `PHOENIX_KIT_PATH`.
- Destructive-rescue tests live in `test/phoenix_kit_ai/destructive_rescue_test.exs`
  (`async: false`); the LiveView-mounted one is tagged `:destructive` and needs
  `--include destructive`.
- Conformance tests guard two cross-repo invariants:
  `core_pin_conformance_test.exs` rejects a three-segment `~> 2.0.x` core pin
  (which would exclude every later core minor and break consumers, never this
  repo) and a path override reaching a commit;
  `schema_prefix_conformance_test.exs` asserts every table-backed schema uses
  `PhoenixKit.SchemaPrefix`.
- `test/phoenix_kit_ai_test.exs` covers the behaviour callbacks: `module_key/0`,
  `module_name/0`, `version/0`, `admin_tabs/0`, `css_sources/0`, `js_sources/0`,
  `permission_metadata/0`.
- i18n tests are skipped unless core exports `PhoenixKit.Dashboard.Tab.localized_label/1`;
  the current core floor is well past that, so the exclusion is a formality.
- `Xai.RealtimeBehaviour` is mocked with Mox via the `:realtime_module` app env.

## Feature notes

- Every provider-calling verb goes through one gate and one wrapper:
  `authorize/2` (endpoint usable, spend caps have room) and `with_cache/6`
  (key, lookup, zero-cost hit row). A new verb joins both or it is not a
  verb — `dev_docs/guides/spend-caps-and-caching.md` holds the semantics
  of caps, cache, structured output and telemetry.
- Structured output (`schema:` / `json: true`) is parsed *inside* the
  cached closure, so a prose answer to a JSON request is logged with its
  usage but never stored as a success.
- A cache hit's usage row is the fresh row minus cost: same `user_uuid`,
  attribution, prompt link and snapshot. Reports that ignore
  `metadata.cached` still add up.
- Host translatables (`config :phoenix_kit_ai, translatables:`) implement
  `PhoenixKitAI.Translatable` (`fetch/2`, `source_fields/2`,
  `put_translation/4`); a configured entry wins over a module's adapter
  for the same type without a duplicate warning.
- Image processing is provider-neutral by construction: callers name an
  endpoint and operations, adapters own the HTTP shape, and options are
  fitted to the model's published capabilities before anything is sent —
  `dev_docs/guides/image-processing.md`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). 
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

`dev_docs/pull_requests/README.md` describes the layout in this repo. A PR
folder with no `FOLLOW_UP.md` means "not triaged yet"; a stub file is what
"triaged, no findings" looks like.

## TODOs

- Not built, each a self-contained PR when a host needs it: a pluggable
  persistent cache backend behind `RequestCache` (ETS stays L1) with
  single-flight on a miss; atomic budget reservation before dispatch
  (today concurrent calls can overshoot); a nullable external-subject
  column on the requests table in core so anonymous visitors can be
  capped per identity (today `user_uuid` is a foreign key); composite
  partial indexes `(endpoint_uuid, inserted_at)` / `(user_uuid,
  inserted_at) WHERE status = 'success'` in core once per-endpoint caps
  run on a busy table; per-source / per-user rate and concurrency limits
  (spend caps are too coarse against a scrape); one `%Result{}` struct
  across verbs instead of provider-shaped maps; streaming chat/TTS with
  cancellation and an async (Oban) mode for slow verbs; provider-neutral
  tool calling; endpoint capability flags (chat / json_schema / vision /
  embed / tts) that fail fast before HTTP — needs core columns; pre- and
  post-dispatch policy hooks for tenancy and redaction; usage rows for the
  realtime voice session.
- Image layer follow-ups, in rough order of value:
  async execution (an Oban worker with progress and cancellation for
  batch jobs); retries with backoff and idempotent replay on top of the
  `idempotency_key` already recorded; per-tenant cost ceilings and a
  `dry_run` price estimate; input roles (`subject` / `reference` / `mask`)
  instead of positional inputs once a second provider takes masks;
  media normalisation (EXIF rotation, colour profiles) before dispatch.
  Trigger: the first consumer that batches, or a second mask-capable
  provider.
- `PhoenixKitAI.Completion` is both the bottom of the stack (`url/2`,
  `handle_error_status/2`, `decode_image_url/1`) and the top (the image
  verbs delegating to adapters). Split the shared helpers into
  `PhoenixKitAI.Providers.Shared` and leave `Completion` the chat /
  embeddings / TTS client. Trigger: the next provider adapter, or the next
  time a compile-time cycle bites.
- `PhoenixKitAI.Images.ImageModels` caches in `:persistent_term`; an ETS
  table with single-flight refresh would avoid the global GC on refills
  and unbounded key growth across endpoints. Trigger: more than a handful
  of image endpoints per install.
- The SSRF policy in `Providers.HTTP` resolves hostnames at check time;
  DNS rebinding between check and connect is out of its reach. Trigger:
  an install that cannot firewall egress.
- No automated `mix test` run (`precommit` stops at dialyzer; no CI
  workflow) — PR #21's open item, waiting on a policy call.

- `metadata.error_reason` is stored via `inspect/1` in `log_failed_request/7`
  and `log_failed_embedding_request/5`. A raw `reason` value would filter better
  through JSONB, but no consumer filters on it yet. Trigger: the first consumer
  that needs to query it — and then update the assertion pinning
  `"{:connection_error, :nxdomain}"` in
  `test/phoenix_kit_ai/completion_coverage_test.exs`.
- `TtsPricing`'s per-provider rate table is hand-maintained; no TTS provider
  reports cost in its response. Trigger: any provider price change, or a cost
  figure that has to be billing-accurate rather than indicative.
