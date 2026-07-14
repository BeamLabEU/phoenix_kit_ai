## 0.12.0 - 2026-07-14

### Added
- **Streaming voice for xAI endpoints.** The Playground gets a "Streaming Voice (xAI)" panel — shown only for endpoints on a provider declaring the `:realtime_voice` capability (xAI, as of `phoenix_kit ~> 1.7.194`) — that connects to xAI's realtime TTS WebSocket (via the new `xai` Hex package's `Xai.Realtime`) and streams synthesized audio back in near-real-time as PCM chunks instead of waiting for a full request/response render.
  - `PhoenixKitAI.Realtime.Session` — a `GenServer` owning one realtime connection per Playground session; monitors the owning LiveView so the socket closes automatically when the LiveView goes away (LiveView `terminate/2` isn't reliable without `trap_exit`, so cleanup is driven from here instead), and runs under a `DynamicSupervisor` (`restart: :temporary` — a dead/ended session is never auto-restarted).
  - A new `XaiVoiceStream` JS hook (`priv/static/assets/phoenix_kit_ai.js`, wired via `js_sources/0`) schedules the streamed 16-bit PCM chunks through the Web Audio API for gapless playback.
  - `OpenRouterClient.resolve_api_key/1` is now public so the realtime session can resolve the endpoint's API key the same way the REST completion path does.
  - Scope is streaming **output** only (type text, hear it spoken) — no microphone input / full-duplex voice agent.
- Depends on `phoenix_kit ~> 1.7.194` (adds the xAI `:realtime_voice` capability) and the new `xai ~> 0.1` package.

### Known issues
- `xai`'s gRPC transport pulls in `gun`/`cowlib`, which currently carries two unpatched upstream advisories (`cowlib` 2.18.0: CVE-2026-43966 MEDIUM, CVE-2026-43969 LOW — both in outgoing HTTP header/cookie construction). No fixed `cowlib` release exists yet; `xai`'s own maintainers accept the same risk for the same reason. This module only uses `Xai.Realtime` (WebSocket, via `websockex`) — the vulnerable gRPC/`gun` code path is never exercised at runtime here. Accepted; re-evaluate once `cowlib` patches upstream.

## 0.11.2 - 2026-07-13

### Fixed
- **`:instructions` steering silently dropped for dated OpenAI TTS snapshots.** `supports_instructions?/1`'s `~r/^gpt-4o.*-tts$/` anchored on the model string ending right at `-tts`, so a pinned dated snapshot (e.g. `gpt-4o-mini-tts-2025-12-15`, as OpenAI publishes for this family) never matched — the exact language-steering hint 0.11.0 added to fix homograph mispronunciation ("come"/"fine" read as English) was being discarded again for any host pinning a dated model. The regex now allows an optional trailing `-YYYY-MM-DD`.

## 0.11.1 - 2026-07-13

### Fixed
- **`:instructions` on TTS no longer breaks Mistral with HTTP 422.** 0.11.0's claim that Mistral's `/audio/speech` schema "allows unrecognized JSON properties" was wrong — `voxtral-*-tts` hard-rejects an unrecognized `instructions` field with a 422 and returns no audio at all. `Completion.text_to_speech/3` now only sends `instructions` to models known to support steering (the `gpt-4o*-tts` family); it's silently dropped for everything else, including older OpenAI `tts-1`/`tts-1-hd` (which predate the field) and Mistral. Dropping the hint degrades pronunciation quality; sending it to an unsupported model destroyed the whole request, so dropping is the only safe default.

## 0.11.0 - 2026-07-12

### Added
- **`:instructions` option for `PhoenixKitAI.speak/3` / `Completion.text_to_speech/3`.** Forwards steerable instructions text to `/audio/speech` (accent, tone, pacing, and which language to read ambiguous input as) — needed for `gpt-4o-mini-tts` and similar steerable models. Fixes a real mispronunciation case: without a way to tell the model which language the input is in, a host app's Italian TTS read homographs like "come"/"fine" as English words. Sent only when the caller passes it (same provider-neutral pattern as `:voice`/`:voice_id`); Mistral's `/audio/speech` schema allows unrecognized JSON properties, so the field is safe to send unconditionally rather than gated per-provider.

## 0.10.0 - 2026-06-18

### Changed
- **The translation modal pre-selects the endpoint you actually used last.** `Translations.default_endpoint_uuid/0` now resolves in order: (1) the `ai_translation_endpoint_uuid` setting (admin override), (2) the endpoint of the most recent **successful chat request** in the AI history (`phoenix_kit_ai_requests`) whose endpoint is still enabled, (3) the first enabled **non-reasoning** chat endpoint (reasoning/"thinking" models break the `---FIELD---` structured-response parser), then (4) the first enabled endpoint. Because the shared `AITranslate.FormGlue` consumes this, the catalogue / projects / publishing translation modals all benefit. The history lookup is a single indexed `ORDER BY inserted_at DESC LIMIT 1` query at mount, gated on AI being enabled (PR #11).
- **Dependency refresh.** `phoenix_kit` 1.7.155 → 1.7.162, `leaf` 0.2.24 → 0.3.0 (pulls in `mdex` / `mdex_native`), `phoenix_live_view` 1.2.1 → 1.2.3, `finch` 0.22 → 0.23, `sourceror` 1.12.0 → 1.12.2. The `phoenix_kit ~> 1.7.155` requirement is unchanged. Dropped the orphaned `earmark` lock entry and flattened an internal `Translations` helper to keep `mix precommit` (`credo --strict`, `deps.unlock --check-unused`) green.

### Fixed
- **`default_endpoint_uuid/0` now actually fails open on a missing AI-requests table.** The new history lookup was wrapped in `safe_ai/2`, which only rescues `UndefinedFunctionError` / `FunctionClauseError` / `ArgumentError` — so a missing or pre-migration `phoenix_kit_ai_requests` table (which raises `Postgrex.Error`) would crash the translation modal at mount instead of degrading to `nil`. The query now carries its own `rescue`, mirroring `job_in_flight?`, so any query error falls through to the next resolution step.
- **AI endpoint form: TTS voice state bugs.** The Mistral voice field is matched by provider **prefix** (a `mistral`-prefixed integration key still maps to `voice_id`), and the stored default voice is cleared when the integration/provider changes — voice slugs are provider-specific, so a Mistral voice must never be sent to OpenRouter on the next `speak/3`. Submitted `provider_settings` now merge onto the endpoint's existing settings instead of replacing them.

## 0.9.0 - 2026-06-15

### Changed
- **Provider list is now discovered dynamically from the Integrations registry** instead of a hardcoded `~w(openrouter mistral deepseek)` whitelist. `Endpoint.valid_providers/0` and `Endpoint.provider_options/0` are built from `PhoenixKit.Integrations.Providers.with_capability(:ai_completions)`, and `Endpoint.default_base_url/1` / `Endpoint.provider_label/1` read each provider's `base_url` / `name` from the registry. Any provider that declares the `:ai_completions` capability — built-in (OpenAI, OpenRouter, Mistral, DeepSeek) or contributed by an external module via `integration_providers/0` — now appears in the AI Endpoint provider picker automatically, with no code change here. In particular, **OpenAI endpoints are now configurable** out of the box.
- Requires **`phoenix_kit ~> 1.7.155`** (adds `Providers.with_capability/1` and `Providers.base_url/1`).

### Fixed
- **Version sync.** `version/0` (and its compliance test) were stranded at `0.1.5` while `mix.exs` had moved to `0.8.0`; all three version sources are realigned to `0.9.0` per the AGENTS.md release checklist.

## 0.8.0 - 2026-06-10

### Added
- **Voice picker for TTS endpoints.** When a TTS endpoint's provider exposes a voice catalogue, the endpoint form's "Default Voice" field becomes a two-level **speaker → mood** picker (Mistral Studio style) instead of a free-text box — pick a speaker (grouped/labelled by language), then its mood; the resolved voice slug is what's stored:
  - `PhoenixKitAI.OpenRouterClient.fetch_voices/2` — fetches `GET /audio/voices` (Mistral-specific; ~30 presets in a single `limit=100` page) and returns a normalized `[%{slug, name, language, gender, tags}]`. The `slug` (e.g. `en_paul_neutral`) is what `/audio/speech` accepts as `voice`, so it stores/sends straight through `speak/3`.
  - The picker fetches inline after the model fetch (reusing the validated key + base_url), only for the TTS type. Providers without a voices endpoint (e.g. OpenRouter) return non-200 and the form falls back to the free-text field — kept provider-neutral.
  - Required-voice hint: when the voice picker is shown (Mistral) and no voice is selected, the form warns that a voice is required — Mistral's `/audio/speech` returns `400` without a `voice`/`ref_audio`.
  - The endpoint's stored default voice is sent on the provider's documented field: `voice_id` for Mistral (matches its OpenAPI schema; the voices catalogue is Mistral-specific so a stored voice is always a Mistral slug), `voice` for everything else (OpenRouter / OSS vLLM presets). An explicit caller-supplied `:voice`/`:voice_id` is never overridden.

## 0.7.0 - 2026-06-10

### Added
- **Model-kind icon column on the AI Usage endpoints list.** A leading icon column (before the endpoint name, in both the table and card views) shows at a glance what kind of model each endpoint points at:
  - Text-to-Speech → `hero-speaker-wave`, Embedding → `hero-rectangle-stack`, Chat/Completion → `hero-chat-bubble-left-right`, each with a tooltip.
  - Classification is inferred from the model id via the new pure helpers `PhoenixKitAI.Endpoint.kind/1` (`:chat | :tts | :embedding`) and `kind_icon/1`, reusing the same `tts`/`embed` substring heuristic as the model picker (endpoints store no explicit type).

### Changed
- **Compacter endpoints toolbar.** The sort/filter UI now shares one row with the New Endpoint button + card/list toggle (moved from the `:sort_bar` slot into the core table's `:toolbar_title` slot) instead of stacking a second row beneath them. No core/`phoenix_kit` change required.

## 0.6.0 - 2026-06-10

### Added
- **Model-type selector on the endpoint form** (Chat / Text-to-Speech). Picking a type filters the fetched model list so TTS models no longer sit undifferentiated in the chat dropdown:
  - New `:tts` model type in `PhoenixKitAI.OpenRouterClient` (`fetch_models_by_type/3`, `model_matches_type?/2`). Since neither Mistral nor OpenRouter expose an audio modality flag, TTS models are matched by `tts` in the model id/name (e.g. `voxtral-mini-tts-2603`); the `:text`/Chat filter now excludes them so the chat picker stays clean. Speech-to-text/transcription models are intentionally not matched (no dedicated type yet).
  - The form re-runs its existing fetch with the selected `model_type`; editing an endpoint infers the type from its saved model id (TTS endpoints open on the TTS filter).
- **Per-endpoint default TTS voice.** A "Default Voice" field (shown only for the TTS type) is stored in `provider_settings["voice"]`; `PhoenixKitAI.speak/3` falls back to it when the caller passes no `:voice`/`:voice_id`. No migration — `provider_settings` is already a map.

## 0.5.0 - 2026-06-10

### Added
- **Text-to-speech support** (`PhoenixKitAI.speak/3`). Synthesizes speech from text through a configured AI endpoint and returns the raw audio bytes, mirroring the `embed/3` path (shared endpoint resolution, credential validation, error mapping, and request logging):
  - `PhoenixKitAI.speak(endpoint_uuid, text, opts)` → `{:ok, %{audio: binary(), format: String.t()}}`. Options: `:voice` (preset id) / `:voice_id` (saved/cloned id) — only the present one is sent, keeping the package provider-neutral — plus `:response_format` (default `"mp3"`) and `:source`.
  - `PhoenixKitAI.Completion.text_to_speech/3` posts to `/audio/speech` and decodes both response shapes: Mistral hosted base64-JSON (`{"audio_data": "<base64>"}`) and the raw binary audio body used by OpenRouter / OSS vLLM.
  - Request log gains a `"tts"` `request_type`. TTS carries no token usage (per-character billing), so rows record `input_chars`, `audio_format`, and `audio_bytes` instead; the input text honours the existing `capture_request_content` PII gate.
  - New `:invalid_audio_response` error reason in `PhoenixKitAI.Errors` for an unreadable/empty audio response.

## 0.4.0 - 2026-06-08

### Added
- **AI translation pipeline + UI (moved from core).** A generic, multi-consumer AI-translation layer now lives in the plugin; consumers (publishing/catalogue/projects) wire in a tiny adapter + form binding and get the rest for free:
  - `PhoenixKitAI.Translatable` — adapter behaviour: `fetch/2`, optional scoped `fetch/3`, `source_fields/2`, `put_translation/4`, optional `pubsub_topics/1`
  - `PhoenixKitAI.Translation` — the `ask_with_prompt/4` call + structured `---FIELD---` response parser, with every failure path normalized to `{:error, atom_or_tuple}`
  - `PhoenixKitAI.Translations` — enqueue, scope-aware in-flight dedup, payload-minimal PubSub broadcasts, `missing_languages/3`, and idempotent default endpoint/prompt provisioning
  - `PhoenixKitAI.TranslateWorker` — the generic Oban worker (threads `resource_scope` to `fetch/3` when the adapter exports it; transient-vs-deterministic retry/snooze/discard classification)
  - `PhoenixKitAI.Translatables` — duck-typed adapter discovery scanning `PhoenixKit.ModuleRegistry` for `ai_translatables/0`
  - `PhoenixKitAI.Components.AITranslate{,.Embed,.FormBinding,.FormGlue}` — the shared AI-translate modal UI + LiveView state/progress/stall glue
- **Reasoning-model parser hardening** (`PhoenixKitAI.Translation.parse_response/2`): strips balanced `<think>`/`<thinking>`/`<reasoning>`/`<thought>` blocks before parsing (an unclosed block is left intact so a real answer is never deleted) and anchors opening `---MARKER---` to start-of-line, so chain-of-thought that mentions a marker inline can't open a section. Reasoning output degrades to a clean `:no_markers` parse error instead of a mis-parsed blob that overflowed a consumer's column on persist.
- `PhoenixKitAI.Routes.ai_path/0` — plugin-owned `/admin/ai` path helper (was a module-specific helper in core's `PhoenixKit.Utils.Routes`)
- Reasoning-model UX hint under the endpoint selector in the AI-translate modal: reasoning models are slower and may return unstructured output — prefer a standard model for translation
- Env-gated local-path dep override in `mix.exs` (`<APP>_PATH`, e.g. `PHOENIX_KIT_PATH=../phoenix_kit`) for cross-repo development; unset resolves to the published Hex pin, so `mix deps.get` / `mix hex.publish` / CI are unaffected

### Changed
- Dependency refresh (`mix.lock`)

### Fixed
- AI-translate form applies a completed translation to the live changeset only for languages this session dispatched — a translation triggered in another session/tab on the same resource no longer clobbers unsaved edits
- `mix precommit` green end to end (credo `--strict` 0 issues, dialyzer 0 errors): closed pre-existing alias-order / nesting / alias-usage findings via behavior-preserving extraction, and removed a dialyzer-dead clause in `Translation`

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
