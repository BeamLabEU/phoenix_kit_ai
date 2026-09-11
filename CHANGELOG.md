## 0.20.0 - 2026-09-10

### Added

- **`TranslateWorker` now writes an `ai.translation_failed` activity entry on
  every terminal failure**, mirroring the existing `ai.translation_added`
  success entry. Covers both `perform/1`'s setup-failure branch (bad args,
  unknown adapter, missing resource) and `fail/3`'s two terminal clauses
  (deterministic discard, or a retryable reason with attempts exhausted) —
  never on a pending retry, matching the existing PubSub broadcast's own
  silence there. The raw failure reason is never persisted verbatim; a new
  `classify_reason/1` reduces it to a short, static classification tag first,
  since some failure shapes can embed resource content (#24).

### Fixed

- **`classify_reason/1`'s persist-failure detail was unreachable.** The
  generic `{:persist_error, _reason}` clause matched before the specific
  `{:bad_put_translation, _other}` clause, which only ever matched a shape
  nothing in the module produces at the top level in production —
  `persist/2` always wraps it as `{:persist_error, {:bad_put_translation,
  _}}`. Every persist failure logged with `reason_detail: nil` instead of
  distinguishing "adapter returned a malformed shape." Reordered the clauses
  and added the analogous `{:persist_error, {:exception, _}}` case.

## 0.19.3 - 2026-09-07

### Fixed

- Removed duplicate page headings across AI admin pages (Endpoints, Prompts, Prompt form, Playground, Endpoint form) — each repeated the page title already shown in the top breadcrumb bar.
- Fixed the Endpoints page breadcrumb title going stale after switching to the Usage tab.

## 0.19.2 - 2026-08-21

### Changed

- **`ai_multilang_tabs` defaults now match core's headerless multilang
  tabs.** `show_header` / `show_info` default to `false`, so AI-enabled
  forms no longer keep a "Content Language" header row every other form
  has lost. Pass `show_header={true}` to restore it (#22).

### Fixed

- **The playground voice test no longer races `verify_on_exit!`.**
  `Session.send_text/2` and `finish/1` are casts; the LiveView handler
  returns before the session process consumes them. The mocks now signal
  the test process (#22).
- **Prompt/endpoint delete-button tests no longer assume HEEx attribute
  order** on `table_row_menu_button` (post-merge, surfaced by core
  2.13.5).

## 0.19.1 - 2026-08-14

### Fixed

- **A request referencing a missing prompt returned a 500 instead of a changeset
  error.** `Request.changeset/2` declared no `foreign_key_constraint` for
  `prompt_uuid` at all, so the violation escaped as a raw
  `Ecto.ConstraintError`. It now declares **both** names the constraint can
  carry: core's v135 adds this foreign key twice under two names, each block
  guarded only by its own, so a freshly migrated database has both while an
  older one has only `phoenix_kit_ai_requests_prompt_uuid_fkey`. Ecto matches by
  name and Postgres reports one `conname`, so the name that exists matches and
  the other is inert — and this stays correct now that core 2.4.0's V169
  converges the pair on the legacy name (#21, #19).

- **Three tests had been asserting behaviour this package no longer has**, and
  had been failing since 0.15.0/0.16.0 without blocking a release:
  `speak/3`'s response shape gained `:timestamps` in 0.16.0; TTS `cost_cents`
  stopped being `nil` in 0.15.0 when it began being estimated from
  `TtsPricing`; and the image-generation override test asked a stored `quality`
  default to disappear because `size` was overridden, which the code never did
  and never should. Nothing runs `mix test` automatically here — neither
  `precommit` nor CI on push — which is why they sat red.

### Changed

- Minimum `phoenix_kit` is unchanged at `~> 2.0`; the lockfile moves to 2.4.0.

## 0.19.0 - 2026-08-12

### Added

- **Per-module Gettext i18n (en/ru/et).** This package now owns a
  `PhoenixKitAI.Gettext` backend and its own catalogues under `priv/gettext/`
  (338 msgids per locale). Previously `use PhoenixKitWeb, :live_view`
  transitively supplied core's backend, so all 402 `gettext` calls here looked
  their msgids up in *core's* catalogue — the interface rendered in English
  whatever the locale, with nowhere for a translator to add strings for this
  package. Tab and permission-matrix labels are wired through
  `gettext_backend`/`gettext_domain`, and `translatable_labels/0` anchors the
  five labels declared as plain struct literals so `mix gettext.extract` can
  see them and `mix gettext.merge` stops deleting them (#17).
- **`PGDATABASE` / `PGPOOL` overrides for the test suite.** `config/test.exs`
  reads both from the environment, falling back to the previous hardcoded
  database name and `System.schedulers_online() * 2`. Without them the only
  way to run the `:integration` half of the suite was a Postgres role holding
  `CREATEDB` — which a shared or managed instance withholds, so those ~545
  tests silently excluded themselves and the run still exited 0. Same
  mechanism core `phoenix_kit` already uses. CI and a plain local `mix test`
  are unaffected (#18).

### Fixed

- **Foreign-key violations on `phoenix_kit_ai_requests` escaped as raw
  exceptions.** `Request.changeset/2` declared `foreign_key_constraint/2` for
  `:endpoint_uuid` and `:user_uuid` without an explicit `:name`, so Ecto
  derived `phoenix_kit_ai_requests_<field>_fkey` — but core's migration chain
  names these constraints `fk_ai_requests_endpoint_uuid` and
  `fk_ai_requests_user_uuid`. The derived names exist on no database, so
  neither declaration could ever match and both were dead code: logging a
  request against a since-deleted endpoint or user raised `Ecto.ConstraintError`
  out of `create_request/1` instead of returning `{:error, changeset}`. Both
  constraints now pin core's actual names, and a database-free test asserts
  no FK constraint on this changeset carries a derived `*_fkey` name.
- **Two translated strings had raw English stitched into them**, so no
  catalogue could translate them: the endpoint save-flash interpolated the
  literal `"created"`/`"updated"`, and the AI-translate scope picker
  interpolated `"language"`/`"languages"` through a hand-rolled pluraliser
  that hardcoded English's two-form rule, making Russian's three forms
  unreachable. Both now use real `gettext`/`ngettext` calls (#17).
- Several tooltips and count+noun fragments in the endpoints and prompts
  templates were never wrapped in `gettext()` at all, so they were invisible
  to extraction regardless of backend (#17).

### Changed

- Dependency updates: `phoenix` 1.8.11, `beamlab_ex_aws_sqs` 5.0.1, `xai`
  0.2.1, `hackney` 4.7.4 and the transitive set.

## 0.18.2 - 2026-08-11

### Fixed

- **`PhoenixKitAi.version/0` reported 0.18.0 in the 0.18.1 release.** The
  version is kept in three places — `mix.exs`, the hardcoded `version/0`, and
  the test asserting it — and 0.18.1 moved only the first, so the published
  package reported a version it was not and its own version test failed. All
  three move together here.

## 0.18.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.18.0 - 2026-08-10

### Changed
- **⚠️ Requires `phoenix_kit ~> 2.0`.** The pin moved from `>= 1.7.214` to `~> 2.0`, so this release no longer resolves against core 1.7. Core 2.0.0 squashes the migration chain to a `V135` floor and *refuses* to migrate a database below it — read core's 2.0.0 CHANGELOG before upgrading, and check `mix phoenix_kit.status` first. A host below V135 must install `phoenix_kit 1.7.236` (the migration bridge) and migrate up to at least V135 before moving to 2.0. Nothing in this package touches migration internals; the change here is the pin itself.

### Added
- **Usage-sink dispatch (`handle_ai_usage/1`).** Every persisted `%Request{}` is now offered to each discovered module exporting `handle_ai_usage/1` — the zero-coupling observer seam, mirroring the Translatables discovery pattern. Best-effort per sink: a sink that raises, throws, or exits is logged and never breaks request logging. First consumer is the projects work ledger's AI attribution. See `PhoenixKitAI.dispatch_usage_sinks/1`.
- **Opaque `:attribution` metadata on AI calls.** Callers may pass `attribution: %{...}`; it is normalized to string keys and recorded verbatim into request metadata. This package never interprets it — usage sinks do. `TranslateWorker` and the form glue now populate it with `resource_type` / `resource_uuid` / `actor_uuid`.
- **VALUE MODE for AI-translate on unsaved forms.** A `FormBinding` may now export the optional `source_fields/2` callback returning the primary-language values straight from the live form's assigns. When present, `:new` forms get AI translation instead of being disabled-until-saved: with no record for the Oban worker to load, the glue translates the live values through the same `Translation.translate_fields/6` core, over supervised tasks (concurrency 4) that self-send results in the exact message shape the PubSub path delivers — so the whole progress/stall/apply state machine is reused unchanged, and the applied changeset persists with the eventual create. Bindings without the callback keep the old behaviour.

### Documentation
- `Request.cost_cents` is documented at the schema as the misnomer it is: the stored unit is the same 1/1,000,000-of-a-dollar unit `TtsPricing` uses, **not** cents, so cents = value ÷ 10,000. Multiple external reviewers had misread it; the field name is kept for schema compatibility.

## 0.17.1 - 2026-07-27

### Changed
- **Stop calling the deprecated `PhoenixKit.Users.Auth.Scope.admin?/1`.** `PhoenixKitAI.Web.AuthHelpers.admin?/1` now calls `Scope.can_access_admin_area?/1`, the name core renamed it to in phoenix_kit 1.7.214. The old name is a pure `@deprecated` delegate to the new one, so **no behavior changes** — this only silences the deprecation warning host apps were eating on every compile of this library, with no way to fix it themselves. Our own `AuthHelpers.admin?/1` keeps its name (it feeds the `"admin" | "user"` `actor_role` string in `actor_opts/1`), but its doc now states what it actually reports: admin-*area* access, true for any permission holder rather than only the Admin role.
- Dependency floor raised to `phoenix_kit >= 1.7.214` — `can_access_admin_area?/1` does not exist below it, so an older core would be an `UndefinedFunctionError` at call time rather than a warning.

## 0.17.0 - 2026-07-22

### Added
- **`<.ai_multilang_tabs>` component.** Wraps core's `PhoenixKitWeb.Components.MultilangForm.multilang_tabs/1` with the AI-translate button/progress/hint row bundled underneath in the canonical placement — the "just enable it" entry point for the layout every consumer (catalogue, projects, publishing) was previously hand-building. Attrs mirror `multilang_tabs/1` plus an `ai_translate` config map from `FormGlue.ai_translate_config/1`; when that's `nil` or disabled, renders byte-identical to core's tabs alone, so the attr is safe to pass unconditionally. The modal is not bundled (HTML forbids nested `<form>`s) — keep `<.ai_translate_modal>` outside the host's outer form as before. See PR #14.

## 0.16.0 - 2026-07-16

### Added
- **`:with_timestamps` option for `PhoenixKitAI.speak/3` / `Completion.text_to_speech/3`, xAI only.** xAI's `POST /v1/tts` accepts `with_timestamps: true` and returns character-level timing (`audio_timestamps.graph_chars`/`graph_times`, parallel arrays) alongside the audio — useful for caption sync, karaoke-style highlighting, or word-level playback in host apps. `decode_xai_audio/3` now parses that into a flat `timestamps: [%{char:, start:, end:}]` list (word boundaries aren't given directly — split on whitespace to derive them); `nil` when not requested or the response doesn't include it. Ignored by Mistral/OpenAI (`timestamps` is always `nil` there too, for a uniform return shape regardless of provider) — neither offers anything equivalent on their TTS APIs (only on their separate speech-*to*-text models, the wrong direction). No price difference confirmed against xAI's pricing page; adds latency for xAI's post-synthesis alignment pass. Verified against the live API, not just documented shape — the response genuinely does switch from the usual raw-binary body to the documented JSON envelope when this flag is set (unlike the base default-shape assumption fixed in 0.14.1, this one held up).
- `phoenix_kit_ai_requests` TTS metadata gains `has_timestamps: boolean` for observability.

## 0.15.1 - 2026-07-16

### Fixed
- **xAI TTS pricing was wrong by ~3.6x.** `TtsPricing`'s xAI rate shipped in 0.15.0 as $4.20/1M characters — sourced from an OpenRouter resale listing, not xAI's own direct-API rate (this module only ever calls xAI's own `POST /v1/tts`, never OpenRouter's proxy of it). Corrected to **$15.00/1M characters**, confirmed against xAI's own pricing page (a flat per-character rate, no per-model breakdown — consistent with TTS having no model concept at all for xAI). Every xAI `cost_cents` value recorded under 0.15.0 is undercounted by the same factor; host apps that care about historical accuracy should recompute those rows (`input_chars * 15` nanodollars) rather than trusting the stored value.

## 0.15.0 - 2026-07-16

### Added
- **Estimated cost for TTS requests.** `cost_cents` (nanodollars) on a `tts` request row was always `nil` — no TTS provider self-reports cost the way OpenRouter's chat completions do (no `usage` object at all in an `/audio/speech` or xAI `/tts` response), so unlike chat/embeddings there was nothing to extract. New `PhoenixKitAI.TtsPricing` module estimates it from a hand-maintained per-provider rate table instead: Mistral and xAI bill per character (`$16` / `$4.20` per 1M chars respectively) and `input_chars` is exact, so those are exact given the rate is current; OpenAI bills per token with no token counts to read back, so it uses the commonly-cited blended rate (~$0.015/min of audio) applied to a duration estimated from `audio_bytes` at the assumed 128kbps MP3 bitrate — an estimate, not exact. Rates are dated in the module doc and will need periodic manual updates as providers change pricing; an unpriced provider still returns `nil`, same as before.

## 0.14.1 - 2026-07-15

### Fixed
- **xAI batch TTS decode against the live API.** `Completion.text_to_speech/3`'s xAI path (`POST /v1/tts`) assumed the documented `{"audio": <base64>, "content_type", "duration"}` envelope. Verified against a live endpoint: the response is the raw audio bytes (e.g. MP3) with status 200 — same ambiguity the OpenAI-compatible path already tolerates. `decode_xai_audio/3` now accepts both shapes, falling back to raw binary only when the body is not JSON at all (so a real error JSON with a missing/null `"audio"` still surfaces as `:invalid_audio_response` rather than the JSON text misread as audio).
- **xAI image-generation form defaults no longer send OpenAI-only fields.** The Endpoint form's Image Generation defaults for xAI are now aspect ratio / resolution (stored in `provider_settings`), and `generate_image/3` applies those as `:aspect_ratio` / `:resolution` instead of the OpenAI `image_size` / `image_quality` columns. OpenAI / OpenRouter keep the existing size/quality behaviour.

### Added
- **xAI batch REST TTS** (landed in 0.14.0, documented here). `speak/3` dispatches to `POST /v1/tts` for xAI endpoints — a single request, complete audio file back — distinct from the Playground's streaming WebSocket path. Request fields: `text`, `voice_id`, `language` (default `"auto"`), nested `output_format`, optional `speed`.

## 0.14.0 - 2026-07-15

### Added
- **Image generation.** `PhoenixKitAI.generate_image/3` (and `Completion.generate_image/3`) call the provider's `POST /images/generations` — the same path and response envelope across OpenAI, OpenRouter, and xAI, so one implementation covers all three (unlike TTS, which needed a separate xAI-specific function). Falls back to the endpoint's stored `image_size`/`image_quality` when the caller passes neither.
  - The Endpoint form gets a new "Image Generation" model type (with its own size/quality picker), gated on the Integrations registry's `:image_generation` capability via `Endpoint.image_gen_model_picker?/1` — shown for OpenAI, OpenRouter, and xAI; correctly absent for providers with no image-gen models (Mistral, DeepSeek).
  - `Endpoint.kind/1` now recognizes image-gen models (`dall-e-*`, `gpt-image-*`, `grok-imagine-image*`, etc.) for admin-UI badging instead of falling back to chat.
  - New `request_type: "image"` in usage tracking (added to `Request`'s valid types).
- **xAI batch REST TTS** via `POST /v1/tts` (dispatched from existing `PhoenixKitAI.speak/3` / `Completion.text_to_speech/3`). Synchronous counterpart to the streaming Playground panel — generate once, cache, serve.
- Depends on `phoenix_kit ~> 1.7.196` (adds the `:image_generation` capability to OpenRouter and xAI — OpenAI already had it).

### Fixed
- **Endpoint form: hide the non-functional TTS model type for xAI.** xAI TTS is not model-based (`POST /v1/tts` takes `voice_id`, nothing in `GET /models`), so picking "Text-to-Speech" always returned an empty model list. `Endpoint.tts_model_picker?/1` hides the option for xAI and resets `model_type` when switching an endpoint onto xAI while TTS was selected.
- **`:image_gen` model filter for xAI.** Relied on `architecture.modality`, which xAI's `/models` never returns — `grok-imagine-image` / `-quality` never matched. No-modality branch now uses `image_price` / id substring the same way the `:text` exclusion already did.

## 0.13.0 - 2026-07-14

### Fixed
- **Streaming voice played nothing at all, with zero errors.** The `XaiVoiceStream` JS hook only created its `AudioContext` reactively when the first audio chunk arrived via `push_event` — not a synchronous user gesture, so browser autoplay policy silently created it `suspended` and nothing ever played. Now unlocked on the first click after the panel mounts (covers the "Connect" click), plus a defensive `resume()` before scheduling each chunk.
- **Silent on iOS Safari specifically**, even after the fix above — WebKit has historically needed a sound actually *played* synchronously within the gesture, not just `resume()` alone. Now plays a zero-length silent buffer in the same click handler (the same technique Howler.js/Tone.js use); a no-op everywhere else.
- `PhoenixKitAI.Realtime.Session` discarded the return value of `send_text`/`send_text_done`, and the Playground silently dropped every realtime event except `"error"` — both now log, which is how the two bugs above were actually found and confirmed fixed (real audio chunks were arriving from xAI the whole time; the bug was entirely client-side).

### Added
- **Visual status feedback in the streaming voice panel.** Audio played via the Web Audio API has no visible player at all, so there was previously no way to tell "silently not working" apart from "actually playing" short of trusting your ears. The panel now shows a live `AudioContext` state, a chunks received/scheduled counter, and a "Test speaker" button that plays a tone independent of xAI entirely — isolates broken audio output (wrong device, muted/silent-switch, OS-level block) from a broken xAI pipeline.
- **Live voice picker.** `OpenRouterClient.fetch_xai_voices/2` hits xAI's `GET /v1/tts/voices` (a different endpoint/shape from `fetch_voices/2`'s Mistral `/audio/voices`) and populates a "Voice" dropdown — includes any custom/cloned voices on the account, not just the 5 built-ins (Ara/Eve/Leo/Rex/Sal), which is why this fetches live instead of hardcoding the list. Falls back to the 5 built-ins if the fetch fails. Disabled once connected — the voice is fixed at connect time, baked into the WebSocket URL by `Xai.Realtime.connect_tts/1`.

## 0.12.2 - 2026-07-14

### Fixed
- **The `cowlib`/`gun` advisory noted in 0.12.0 no longer applies.** `xai` 0.2.0 made `gun` (and `mint`) optional adapters for its gRPC transport (`Xai.Chat`/`Xai.Video`, which this module never calls) instead of a hard dependency. Bumping to `xai ~> 0.2` and not separately depending on `gun` drops `gun`/`cowlib` out of this module's dependency tree entirely — confirmed via `mix deps.get`/`mix.lock` — rather than merely not exercising the vulnerable code path at runtime.
- Depends on `xai ~> 0.2` (was `~> 0.1`).

## 0.12.1 - 2026-07-14

### Fixed
- **0.12.0's `XaiVoiceStream` JS hook bundle never actually shipped.** `package[:files]` in `mix.exs` didn't list `priv`, so `priv/static/assets/phoenix_kit_ai.js` — declared via `js_sources/0` — was left out of the published Hex tarball entirely. Any host app depending on `phoenix_kit_ai` from Hex (not a local path dep) failed to compile with `js_sources/0 bundle not found` the moment the `:phoenix_kit_js_sources` compiler tried to vendor it. `priv` is now included; verified via `mix hex.build`'s file listing.

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
