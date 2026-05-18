## 0.3.0 - 2026-05-18

### Added
- Manual sort mode on the endpoints list — picking "Manual" turns rows + cards into a drag-to-reorder `SortableGrid` target; `reorder_endpoints/2` rewrites `sort_order` via the shared `PhoenixKit.Utils.Reorder.reorder/4` two-phase primitive
- Reorder mutations log a single `endpoint.reordered` / `prompt.reordered` activity row with count metadata
- Optional Provider Settings (HTTP-Referer / X-Title) default from `PhoenixKit.Settings` (`site_url` / `project_title`) via `get_setting_cached/1`; per-endpoint fields act as pure overrides

### Changed
- **Minimum `phoenix_kit` is now 1.7.112** — this release uses `PhoenixKit.Utils.{Reorder,Values,Format}` and the `<.form_section>` / `:sort_bar` core components
- Endpoints + Prompts admin tables adopt `<.table_default toggleable>` (card + table views); sort UI moved to the core `:sort_bar` slot
- Endpoint form, Prompt form, Playground migrated to `<.form_section>` / `<.form_actions>` / core inputs — drops ~500 lines of hand-rolled form boilerplate
- Recent Requests table migrated to `<.table_default>`; columns tiered by importance against the admin sidebar breakpoint
- AI pages expand to full width on large screens
- `parse_sort_*` and actor-resolution helpers extracted to `PhoenixKitAI.Web.{SortHelpers,AuthHelpers}` (~75 lines of duplication removed)
- `reorder_prompts/2` migrated to the shared `Reorder.reorder/4` primitive (was an inline single-phase transaction); takes `[uuid]` instead of `[{uuid, sort_order}]`
- i18n: 14+ raw English strings wrapped in `gettext/1`; `@sort_options` moved to a request-time function so `gettext.extract` sees the labels

### Fixed
- Stable `:uuid` tiebreaker on every endpoint/prompt sort branch — tied sort-field values no longer reshuffle between pages/refreshes
- Replaced the bogus `{:id, "ID"}` endpoint sort option (no `id` column — it silently fell through to default sort) with `{:inserted_at, "Created"}`
- Endpoint "Enabled" toggle now submits a hidden `false` companion so unchecking actually persists
- `PromptForm` gained a `handle_info/2` catch-all so an unexpected message can't crash the form
- Quality sweep: all credo `--strict` findings closed (5 complexity refactors via behavior-preserving extraction); `mix precommit` green end to end

## 0.2.1 - 2026-05-12

### Fixed
- `format_price/1` no longer crashes on JSON-integer pricing (free-tier `0` from OpenRouter); coerces via `value * 1.0` before `:erlang.float_to_binary/2`
- Provider dropdown on `/admin/ai/endpoints/new` no longer surfaces the mount-default `"openrouter"` as a dead-end option when the operator has no OpenRouter integration configured

### Added
- Stale-fetch guard on `:fetch_models` — if the operator switches integrations between Task scheduling and message delivery, the response is dropped instead of repopulating models for the wrong integration

### Changed
- Quality sweep: 7 of 12 pre-existing credo findings closed (two `cond`→`if/else` conversions, five nested-module alias suggestions in tests) plus one dialyzer dead-pattern clause removed

## 0.2.0 - 2026-05-02

### Added
- Multi-provider support: Mistral and DeepSeek endpoints alongside OpenRouter
- Reasoning chain-of-thought capture (reasoning_effort, reasoning_max_tokens) in request history
- Strict-UUID Integrations API — endpoints pin to a specific integration row via `integration_uuid`
- Legacy `api_key` auto-migration with idempotency guards and `:persistent_term` rate-limiting
- Integration-health badges on endpoints list (missing, error, not connected)
- Integration name + masked API key display on endpoint cards
- SSRF guard on `base_url` (blocks localhost, RFC1918, link-local, IPv6 loopback/ULA)
- `endpoint.masked_api_key/1` head+tail mask (first 8 + last 4 chars)
- Provider-switch resets model selector to avoid stale cross-provider model IDs

### Changed
- Move LiveView data loading from `mount/3` to `handle_params/3` (avoids double-fetch)
- Endpoint form wires through changeset on integration deselect
- `OpenRouterClient` lazy-promotes legacy provider strings to `integration_uuid` on read
- Model fetcher generalized to any OpenAI-compatible `/models` endpoint
- DRY credential resolution across completion, validation, and model fetch

### Fixed
- Provider-switch URL reuse bug — switching provider now fetches models from the new provider's base URL
- Duplicated `mask_api_key/1` removed from Endpoints LiveView (consolidated into schema helper)
- `migrate_legacy/0` now surfaces inner `:error` instead of masking it as `{:ok, _}`
- Snapshot-based UUID lookups in migration prevent N+1 queries
- Compile warnings resolved against phoenix_kit 1.7.x

## 0.1.5 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.4 - 2026-04-06

### Changed
- Migrate API key management to centralized PhoenixKit.Integrations system
- Endpoint provider field now stores integration connection UUID
- Endpoint form uses shared IntegrationPicker component
- Declares `required_integrations: ["openrouter"]`

## 0.1.3 - 2026-04-02

### Changed
- Update dependencies

## 0.1.2 - 2026-03-25

### Removed
- Remove leftover `PhoenixKitAI.Migrations.V1` module — all migrations are handled by the parent PhoenixKit package

### Fixed
- Clean up migration references in README

## 0.1.1 - 2026-03-25

### Fixed
- Fix wrong GitHub org in README git dependency (mdon → BeamLabEU)
- Remove unused test.setup/test.reset mix aliases (no local migrations)
- Clarify migration module is called by parent app, not run directly

### Added
- Add versioning & releases section to AGENTS.md

## 0.1.0 - 2026-03-24

### Added
- Extract AI module from PhoenixKit into standalone `phoenix_kit_ai` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `PhoenixKitAI.Endpoint` schema for AI endpoint configurations (provider credentials, model, generation parameters)
- Add `PhoenixKitAI.Prompt` schema for reusable prompt templates with `{{Variable}}` substitution
- Add `PhoenixKitAI.Request` schema for request logging (tokens, cost, latency, status)
- Add `PhoenixKitAI.Completion` HTTP client for OpenRouter chat completions and embeddings
- Add `PhoenixKitAI.OpenRouterClient` for API key validation and model discovery
- Add admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground
- Add route module with `admin_routes/0` and `admin_locale_routes/0`
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (v1) with `IF NOT EXISTS` for all 3 tables (run by parent app)
- Add behaviour compliance test suite
- Add prompt unit tests (variable extraction, substitution, validation)
