# AGENTS.md

Guidance for AI agents working on `phoenix_kit_ai`.

## Overview

AI endpoint management, prompt templates, chat completions, embeddings
(text and images), text-to-speech, image generation and editing, reading and
locating things in images (boxes, regions, checking statements against
images, batches), realtime voice, and per-request usage tracking. Providers are OpenAI-compatible and are discovered at runtime
from core's `PhoenixKit.Integrations` registry
(`PhoenixKit.Integrations.Providers.with_capability(:ai_completions)`), so there
is no hardcoded provider whitelist. Implements the `PhoenixKit.Module`
behaviour for auto-discovery by the host application; it is a library, and the
host supplies endpoint and router (`config/` exists only for tests).

- **Depends on:** `phoenix_kit` `~> 2.64` (Hex; the floor carries V223's
  dollar-valued request cost and removes the legacy account reference;
  `PhoenixKit.Module.oban_crons/0` ships in 2.63, needed to schedule the nightly
  journal cleanup (`PhoenixKitAI.JournalPruneWorker`);
  Activity and Actor also need at least 2.38). No sibling
  `phoenix_kit_*` deps. Non-kit deps: `phoenix_live_view` `~> 1.1`, `gettext` `~> 1.0`, `xai`
  `~> 0.2` (realtime voice only — `Xai.Realtime`; `gun`/`mint` are deliberately
  not added so cowlib's CVE surface stays out of the tree), `rustler`
  (optional, lets the transitive `mdex_native` NIF source-build), plus
  `lazy_html` and `mox` in `:test`.
- **Consumed by:** `phoenix_kit_catalogue`, `phoenix_kit_publishing`,
  `phoenix_kit_projects`, `phoenix_kit_restyle`, `phoenix_kit_ecommerce` — all
  through the `PhoenixKitAI` context module.
- **Admin surface:** one parent tab `AI` at `ai` with five subtabs —
  `ai/endpoints`, `ai/prompts`, `ai/playground`, `ai/usage`, `ai/tasks`.
  Sub-routes for the new/edit forms come from `route_module/0`.
- **Module key** `"ai"`; settings prefix `ai_`.

## What this module does NOT do

- **No column change for `phoenix_kit_ai_endpoints`, `_prompts` or
  `_requests` in core.** Core's chain still creates them first (history), but
  since V5 of this module's chain adopts them and owns their shape; core
  refuses a migration that touches a module table (V223 was the last). A
  change is a new version in `PhoenixKitAI.Migrations`, then schema +
  changeset edits here — see "Database & migrations".
- **No per-completion Activity logging.** `PhoenixKit.Activity.log/3` runs on
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
  (`PhoenixKitAI.TranslateWorker`, and the sweep chains consuming modules
  run through `PhoenixKitAI.TranslationSweep`) and by the journal cleanup
  (`PhoenixKitAI.JournalPruneWorker`).
- **No streaming chat responses.** `Completion` returns a full
  `{:ok, response}` and the Playground is request/response. Realtime *voice* is
  the one streaming path, and it is a separate WebSocket transport.
- **No automatic cleanup without a period.** The request journal, its
  content and the guard's events are kept forever until a person sets a
  period for them (AI → Usage, `PhoenixKitAI.Retention`); the nightly job
  that `oban_crons/0` puts in the host's crontab deletes nothing until then.
  No `VACUUM` is run from code either.

## Commands

```bash
mix deps.get
mix test                     # the alias tries `ecto.create` first; aborts if the test database is unusable
PK_AI_SKIP_DB=1 mix test     # no Postgres on this machine: unit tests only (never in CI or before a release)
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
  gate. A call's `capture_request_content: false` may switch it off for that
  call; `true` on a call never overrides a global `false`. `speak/3` and
  `embed/3` ignore the per-call option.
- **No credential or user content in a process message, a broadcast or a
  log line.** A LiveView message names a connection or endpoint by uuid and
  the handler resolves the key; the change topics broadcast `{event, uuid}`;
  a catch-all `handle_info/2` logs `PhoenixKitAI.Web.MessageShape.describe/1`,
  never `inspect(msg)`; a translation failure is logged and broadcast as
  `TranslateWorker.classify_reason/1`'s pair, never the raw reason.
- **Money** is US dollars as a `Decimal` everywhere (`PhoenixKitAI.Money`).
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
- Money is US dollars as a `Decimal`, stored as it is: a call's `cost`
  (core's V223, `numeric(28,18)`), the spend caps, task limits and their declared
  defaults, prices per 1M tokens. Never scale it into integers, and never write
  it into a JSON map as a number (it reads back as a float): `Money.to_json/1`.
  An integer where an amount is expected is refused (`Money.amount/1`) — the
  released versions stored integer millionths of a dollar, and reading one as
  dollars loosens a cap a million times. A float is refused too. This module
  needs core's V223 and its own V4: until both have run every call is refused
  with `:money_migration_required`, `{:budget_unmigrated, scope}` or
  `{:task_limit_unmigrated, task}`.
- A chat or embedding row's cost comes from `PhoenixKitAI.CallCost`, the
  first source with a price: the provider's `usage.cost` > the operator's
  catalogue price (OpenRouter `pricing`) > the endpoint's manual price
  (`provider_settings["pricing"]`, dollars per 1M tokens as decimal strings) > Anthropic's
  built-in rates (`AnthropicPricing`, from BeamLabEU/phoenix_kit_ai#47,
  overridable by `config :phoenix_kit_ai, :anthropic_prices`). The row's
  `metadata.cost_source` says which (`provider` / `catalogue` / `manual` /
  `table`). The answer's model is priced; with no price anywhere, the
  endpoint's model. The table never becomes a catalogue price
  (`Capabilities.prompt_price`), so a manual price corrects it.
  `PhoenixKitAI.reports_cost?/1` says whether any source prices an
  endpoint's model (`TaskLimits.money_counted?/2` reads it). Chat,
  embeddings and the vision verbs (`describe_image` / `extract_text` /
  `compare_images`, model: the answer's, else the call's `model:`, else the
  endpoint's) are priced by `CallCost`; a call without tokens gets no cost.
  Making or editing images (`generate_image` / `edit_image` /
  `process_image`) is priced per image or per call, so it keeps only the
  provider's own cost — no manual or table price. A manual price
  names its model (dropped when the model changes), has both halves, at most
  $10 000 per 1M tokens, and setting, changing or removing it needs
  `ai.manage` (the `:scope` option; an Owner always).
- `user_uuid:` on a verb must be a PhoenixKit user uuid. The usage row has a
  foreign key on it, so an anonymous or external id cannot be stored there:
  the row is written without it (`user_uuid` nil, the submitted id kept in
  `metadata["unresolved_refs"]`, a warning logged) and counts toward the
  endpoint and global caps but never the per-user one. The same applies to
  an `endpoint_uuid` or `prompt_uuid` that names no row. Task limits read a
  `user_uuid:` that is not a uuid as no user: the task's own limits apply,
  the per-user ones do not. Cap the endpoint or the site for visitors.
- Spend caps read the usage table; concurrent callers overshoot by their
  in-flight calls, and a database error fails open. Treat a cap as a brake
  on a runaway day, not as a hard invoice ceiling.
- The journal is no longer forever for its readers once a period is set.
  A total "for all time" (`get_usage_stats/1`, the Endpoints and Usage
  tabs) covers only what is kept — the tabs say "for the retained period,
  since <date>" — and the 30-day windows (model recommendations and
  `Recommendations.worked/2`, token medians, flags of the last 30 days, the
  30-day totals) see less under a period shorter than 30 days. Anything
  that needs older history copies it out first. Only the floor is
  promised: the current month, from local midnight two days before its
  first day (and the last 24 hours of content).
- Guard events changed behaviour: they used to be deleted after a fixed
  180 days by `GuardEventsPruneWorker`; now they are kept forever unless
  `guard_events` gets a period, so an install that relied on the old
  pruning sets one.
- What clearing the content leaves of personal data: the `error_message`
  column (`Errors.message/1` plus the provider's answer, cut and masked;
  a `{:content_policy, text}` refusal is the provider's text, which can
  paraphrase the request) goes only with the row, by the `requests` period;
  the reasons and lift notes of blocks (`phoenix_kit_ai_guard_blocks`) are
  written by people and no period covers them.
- Deleting and clearing do not shrink the table files: the space is reused
  after autovacuum. A large first run writes a burst of WAL (replicas,
  backups, disk). Nothing here runs `VACUUM`.
- A new `metadata` key carrying user text — anything written under the
  `capture_request_content?` gate — must be added to
  `Retention.content_keys/0`, or the content step leaves it behind for good.
  `test/phoenix_kit_ai/retention_content_keys_test.exs` writes each kind of
  row with capture on and off and fails on a gated key missing from the
  list.
- `test/phoenix_kit_ai/retention_client_timeout_test.exs` commits the
  `ai_journal_retention` row to the test database from connections outside
  the sandbox (to hold it under `FOR UPDATE`, and a save on its own repo
  instance), and removes the row and its committed `setting.changed`
  Activity entries itself, before each test and in `on_exit`. A run killed
  midway leaves them behind for every later run of this module and of any
  module sharing the database (`PGDATABASE`) until the test runs again.
- `PhoenixKitAI.Limiter` counts per node: in a cluster each node has its own slots,
  so a provider sees up to `limit × nodes` concurrent calls. The slot covers the whole
  call including retries; a retried 429 keeps its slot while it backs off, on purpose.
- With `request_log_mode: :async`, spend caps read rows that may not be written yet
  (a few ms behind), and rows still queued when the node is killed are lost. Leave it
  `:sync` where a cap must hold tightly. The Playground, which reads the call's row for
  its cost chip, waits for the queue once, up to 2 s, when the row is not there yet.
- `PhoenixKitAI.Cache` drops credentials on core's *system* integrations topic only; a
  personal connection's change is seen within `credential_cache_ttl`.
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
  completion.ex                  provider-agnostic HTTP client (chat, embeddings, TTS) — per-call timeout, retries with backoff; image verbs delegate to adapters
  limiter.ex                     PhoenixKitAI.Limiter — per-key concurrency slots + FIFO waiting line around provider calls
  cache.ex                       PhoenixKitAI.Cache — short-lived endpoint + credential lookup cache, dropped on change broadcasts
  request_log.ex                 PhoenixKitAI.RequestLog — writes usage rows off the caller (request_log_mode: :async)
  provider.ex                    PhoenixKitAI.Provider behaviour + adapter resolution by provider key
  providers/                     adapters: openrouter (unified /images), xai, openai (multipart), openai_compatible (chat parts), http (shared Req door)
  images.ex images/              generic image layer: operations → prompt, option fitting, describe/compare, model-capability cache;
                                 images/regions.ex — schemas, prompts and parsing of located answers (regions, text boxes, statements)
  box.ex                         PhoenixKitAI.Box — the one box type ([x0, y0, x1, y1] fractions, top-left) and each model's box format
  vision_batch.ex                PhoenixKitAI.VisionBatch — one vision verb over many items, per-item status, budget and fatal stop
  runs.ex                        PhoenixKitAI.Runs — a run's totals from the journal (`run:` / `step:` tags)
  openrouter_client.ex           generic across providers despite the name
  capabilities.ex                what a model can do (catalogue + declared), ETS cache process
  task_spec.ex tasks.ex          AI task declarations (`ai_tasks/0`), the registry, fitness for a task
  recommendations.ex             models for a task grouped by capability (verified / possible / experimental) + models that worked (journal, 30 days)
  guard.ex                       the call-time check: needs of a call, fitness, require_parameters; ai.manage; admit/4; off-purpose reports, self_flag?, anomaly rules
  guard_blocks.ex guard_block.ex   blocks of a person in a task's block group: rights, the per-node cache; the V3 schema
  task_limits.ex                 task limits: calendar windows, limits in force, counting from the journal, forgiving
  guard_events.ex guard_watch.ex   guard events, dedupe, watchers, notifications; the model_unfit watch process
  retention.ex                   PhoenixKitAI.Retention — journal retention: periods, boundaries and the floor, preview, foreign-key check, chunked cleanup, last-run stamp; the policy block (who, defaults, limits)
  journal_prune_worker.ex        the nightly and manual cleanup job (Oban, `default` queue, unique)
  guard_events_prune_worker.ex   shim of the old 180-day prune: only queues JournalPruneWorker
  migrations.ex model_capability.ex   the module's own migration chain; capability snapshot schema
  task_setting.ex task_user_limit.ex guard_event.ex   schemas of the chain's V2 tables
  errors.ex                      error atom -> gettext string
  ai_model.ex routes.ex          model struct; admin sub-routes
  gettext.ex                     PhoenixKitAI.Gettext backend
  tts_pricing.ex                 hand-maintained TTS rate table
  realtime/session.ex            one xAI realtime WebSocket per Playground LiveView
  translat*.ex translate_worker.ex   generic AI-translation pipeline
  components/ai_translate*       reusable translate button/glue components
  web/                           admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground, Tasks;
                                 journal_retention.ex + components/journal_retention_card.ex (the Usage tab's retention card); access.ex (rights now, per event)
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
  `{{TargetLanguage}}` / `{{SourceFields}}` / `{{Glossary}}` / arbitrary
  field variables (those four names are reserved — a resource field named
  exactly `"Glossary"` would be overwritten), a parser for the
  `---FIELD_NAME---` response shape, and error normalisation so every failure
  path returns `{:error, atom_or_tuple}`. Adapters are duck-typed through
  `ai_translatables/0` discovery.

### Data model

| Table | Schema | Notes |
|---|---|---|
| `phoenix_kit_ai_endpoints` | `PhoenixKitAI.Endpoint` | (module chain V5, adopted from core) provider credentials, model, generation params, `provider_settings` |
| `phoenix_kit_ai_prompts` | `PhoenixKitAI.Prompt` | `{{Variable}}` templates |
| `phoenix_kit_ai_requests` | `PhoenixKitAI.Request` | per-request usage log |
| `phoenix_kit_ai_model_capabilities` | `PhoenixKitAI.ModelCapability` | capability snapshot of the endpoints' models (module chain) |
| `phoenix_kit_ai_task_settings` | `PhoenixKitAI.TaskSetting` | a task's limits, warn percent (module chain V2) |
| `phoenix_kit_ai_task_user_limits` | `PhoenixKitAI.TaskUserLimit` | a user's personal limits in a task (module chain V2) |
| `phoenix_kit_ai_guard_events` | `PhoenixKitAI.GuardEvent` | what the guard noticed; `dedupe_key` unique where set (module chain V2) |
| `phoenix_kit_ai_guard_blocks` | `PhoenixKitAI.GuardBlock` | a person blocked from a block group until lifted; one active per group and person (module chain V3) |

### PubSub topics

| Topic | Subscribe helper |
|---|---|
| `phoenix_kit:ai:endpoints` | `subscribe_endpoints/0` |
| `phoenix_kit:ai:prompts` | `subscribe_prompts/0` |
| `phoenix_kit:ai:requests` | `subscribe_requests/0` |
| `phoenix_kit:ai:capabilities` | `Capabilities.subscribe/0` |
| `phoenix_kit:ai:guard` | `TaskLimits.topic/0` (`GuardWatch` subscribes) |

Every message is `{event, uuid}`; a subscriber that needs the record reads
it by uuid. The capabilities topic carries
`{:capabilities_refreshed, base_urls}` after a catalogue refresh that changed
the cache, with the base URLs that changed. The guard topic carries
`{:task_limits_changed, task_key}` after a change of a task's limits, so
every node drops its cached limits of the task, and
`{:guard_blocks_changed, block_group}` after a block or a lift, so every
node drops its copy of the active blocks.

### Settings & permissions

Settings: `ai_enabled` (boolean, default `false`) is the module toggle;
`ai_legacy_api_key_migration_completed_at` is the idempotency marker for
`migrate_legacy/0`; `ai_translation_sweep_last_run_<sweep_key>` holds each
translation sweep's last outcome, written by `PhoenixKitAI.TranslationSweep`.
Spend caps (`PhoenixKitAI.Budget`): `ai_daily_cap`,
`ai_daily_cap_per_endpoint`, `ai_daily_cap_per_user` — dollar strings per
trailing 24 hours, `0` = no cap (the released `ai_daily_budget*` keys held
millionths; V4 copies them over and a scope with only its old key refuses
calls) — plus `ai_daily_calls_per_user` (a count of
successful calls per user, scope `:user_calls`), and `ai_budget_warn_percent` (default 80),
read through the settings cache. Every provider-calling verb (not the
realtime voice session) checks them first and returns
`{:error, {:budget_exceeded, scope}}` once one is reached, cached answers
included; only a `process_image/4` dry run skips the check (no other verb
honours `dry_run:`). A refused call is written as a usage row (see
"Feature notes").

The call-time guard: `ai_guard_verified_models_only` (boolean, default
`false`, switched on AI → Tasks) refuses a call whose model's capability
for a requirement is unknown instead of letting it through; while it is on,
a new or changed capability declaration on an endpoint needs `ai.manage`
(`create_endpoint/2` / `update_endpoint/3` take `scope:`).
`ai_guard_watchers` (JSON text of a list of user uuids, ≤ 1000 characters;
empty = every Owner) is who gets the guard's `"ai_guard"` notifications.

AI translation: `ai_translation_endpoint_uuid` / `ai_translation_prompt_uuid`
pick the shared endpoint and prompt; `ai_translation_glossary_<target_lang>`
(exact string match, no `de-DE` → `de` fallback) overrides — never appends
to — the shared `ai_translation_glossary`. Plain text passed verbatim into
the prompt's `{{Glossary}}` slot, uncapped. A blank value cannot be stored,
so `Settings.delete_setting/1` is how a language falls back to the shared
key; `translate_fields/6`'s `glossary:` option overrides both (`nil` = none).

Journal retention (`PhoenixKitAI.Retention`): `ai_journal_retention` is
one JSON document, `{"content": P, "requests": P, "guard_events": P,
"changed_at": {"content": ISO, …}}`, each `P` either `"forever"` or
`{"n": N, "unit": "day" | "month" | "year"}` (N 1..36 500 days, 1..1 200
months, 1..100 years). No setting means every kind forever, the default;
a save writes the kinds it did not change out as they are (a missing one
as `"forever"`). Read without the settings cache; a database error, a
value of the wrong form or out of range, or a finite period without its
`changed_at` reads as `"forever"` with a log warning (the last also lands
in `settings/0`'s `unconfirmed`, its stored period in `unconfirmed_periods`;
the card's form shows that period, and saving it as shown applies it,
through the preview of a first finite period).
`put_settings/3` writes it through core's
`update_json_setting_with_module/4` with `actor_uuid:` and
`source: "settings"`, so core's own `setting.changed` entry is the audit
of a change; `changed_at` is set by the server, for the changed kinds
only. `ai_journal_retention_last_run` is the runs' stamp, written with
`history: false` (no settings history; the manual run's person is inside
the JSON): `scheduled` and `manual` entries (`at`, `status` `ok` /
`failed` / `skipped`, `error` — a class, never a message — `counts` of
`content` / `requests` / `guard_events` / `guard_reasons`, `more_left`,
`content_batch`, `failure_logged_at`, `actor_uuid` on a manual one), plus
`content_done_before` (content below it is already cleared; only moves
forward), `content_resume` (`{"lower", "upper"}`, an interval above that
point already cleared, skipped by the next content step) and
`rows_deleted_before` (the earliest boundary below which any run deleted
journal rows; never cleared, so the "retained since" notes stay after a
run that deletes nothing).

Permissions: the module permission `"ai"` from `permission_metadata/0`,
checked with `Scope.has_module_access?/2`, and three sub-permissions.
`"ai.view_usage"`: the Usage tab (every request with its prompt and
response). `"ai.manage_endpoints"`: creating, editing, enabling,
reordering and deleting endpoints — the base key still lists them, and the
recommendations panel's create link needs this key. Both are checked by
`Web.Access.can?/2` (an Owner always) at mount or patch and again in every
event that reads or writes what they gate: the tabs declare `path:`, so
core's route gate admits any `ai` holder and the tab `permission:` only
hides the sidebar entry. Core keeps a viewer on the page when only a
sub-key is revoked, so `Web.Endpoints` implements core's
`phoenix_kit_scope_changed/1` to recompute both gates and leave the Usage
tab (dropping loaded requests) the moment `ai.view_usage` is lost; any new
page with a sub-key gate needs the same callback. `migrate_legacy/0` grants each once to every role
that held `ai` (flags `ai_view_usage_backfilled`,
`ai_manage_endpoints_backfilled`, set only after every grant succeeded; the
roles' keys are read with the module's own query, which raises, because
core's `get_permissions_for_role/1` reads a failed lookup as "no keys").
The endpoint form leaves on a lost `ai.manage_endpoints`; the Tasks page
reloads private reasons and clears editors on a scope change; the Usage
card refreshes its retention rights and drops previews when `ai.manage`
is lost. Regaining a permission never restores a discarded confirmation.
`"ai.manage"`: changing the task guard (limits, personal limits, forgiving,
watchers, "only verified models", declaring capabilities while that is on,
a task's self-flag mode, blocking and lifting), seeing the reasons of a private task's flags and
blocks, and the journal's retention — the periods of all three kinds, their
preview and a cleanup by hand (`Retention.may_set?/2` / `may_run?/2`, the
policy kept in one block at the top of `Retention`; `owner_only_kinds/0`
is empty). Seeing the periods and the runs' outcome on the Usage tab
needs `ai.view_usage` as well as the base `ai` permission.
An Owner always may (`Guard.may_manage?/1`); core grants a new
sub-permission to Admin once while Admin holds `ai`. Every context function
that changes the guard or the retention takes the actor's scope and checks
it; the Tasks page and the Usage page's retention card check again per
event, against the socket's scope and the scope as it is now
(`PhoenixKitAI.Web.Access`: the session's through core's `SessionRef`
where core has it, else the user's current row). The card's acting events
go through `Access.manage_scope/1`, which hands back the scope it checked
so the context function gets that same, current scope.

### Application env

| Key | Default | Purpose |
|-----|---------|---------|
| `:capture_request_content` | `true` | Persist message/response content in request `metadata`; `false` writes `content_redacted: true` instead (tokens/latency/cost still recorded). A call may only narrow it: `capture_request_content: false` on `complete/3` / the image verbs redacts that call; `true` does not override a global `false` |
| `:capture_request_memory` | `false` | Opt-in per-request `:memory` snapshot in metadata — debug only |
| `:allow_internal_endpoint_urls` | `false` | Bypass the SSRF guard on `Endpoint.base_url` (an internal address, a name resolving to one, `*.local` / `*.internal` are rejected; non-http(s) always is) — for self-hosted Ollama etc. |
| `:embedding_models` | `[]` | Extra embedding models appended to `OpenRouterClient.fetch_embedding_models/2`; non-list values are warned about and ignored |
| `:req_options` | `[]` | Extra `Req` opts appended to every HTTP call — tests use it for `Req.Test` plug stubs |
| `:realtime_module` | `Xai.Realtime` | Swappable realtime client; tests point it at a Mox mock of `Xai.RealtimeBehaviour` |
| `:provider_adapters` | `%{}` | Provider key → `PhoenixKitAI.Provider` module, merged over the built-in adapters (add a provider without touching this module) |
| `:image_operations` | `%{}` | Extra or replacement image operations for `PhoenixKitAI.Images.Operations` (string or atom keys) |
| `:max_image_bytes` | `25_000_000` | Largest image accepted as input or fetched as output by the image verbs |
| `:translatables` | `[]` | `[{resource_type, adapter_module}]` a host app registers for the AI-translation pipeline without being a kit module; configured entries win over module-declared ones |
| `:request_cache` | `[]` | `ttl:` (seconds, default 86 400), `sweep:` (300), `max_entries:` (10 000), `max_value_bytes:` (8 000 000), `default:` (`true` caches every verb unless a call says `cache: false`); read per call by `PhoenixKitAI.RequestCache` |
| `:task_registry_retry_ms` | `60_000` | How long a task registry built while a module's `ai_tasks/0` failed is kept before the next access builds it again |
| `:task_providers` | `[]` | A host app's own modules whose `ai_tasks/0` declares AI tasks (see Feature notes) |
| `:task_registry_callback_timeout_ms` | `5_000` | How long the registry builder waits for one module's `ai_tasks/0`; a timeout counts as a failure |
| `:task_registry_build_timeout_ms` | `30_000` | How long a caller waits for the builder before answering from the last cached registry |
| `:retry` | `false` | Retries for chat / embeddings / TTS calls: `true` (defaults) or `[max_attempts: 3, base_delay: 1_000, max_delay: 30_000, retry_timeouts: false]`; a call's `retry:` wins. Retried: HTTP 408/429/500/502/503/504 (never a 429 about money — an exhausted balance or quota) and transport errors other than a timeout; `Retry-After` honoured up to `max_delay`. Off by default so callers with their own retry/snooze logic (`TranslateWorker`) are unaffected |
| `:timeout` | `120_000` | Receive/connect timeout (ms) for chat / embeddings / TTS calls; a call's `timeout:` wins |
| `:concurrency` | `%{}` | Concurrency limits per key, `%{"provider:openrouter" => 8, "endpoint:<name or uuid>" => 2}` — the most specific key wins; a call's `concurrency: [limit:, key:, wait:, notify:]` or `concurrency: false` overrides. See `PhoenixKitAI.Limiter` |
| `:concurrency_defaults` | `[]` | `wait:` (ms a call waits for a slot, default 30_000) and `max_waiting:` (line length before `:concurrency_queue_full`, default 1_000) |
| `:endpoint_cache_ttl` / `:credential_cache_ttl` | `300` | Seconds `PhoenixKitAI.Cache` keeps a resolved endpoint / integration credentials; `0` turns that cache off (config/test.exs does). Entries are also dropped on the endpoints broadcast / core's system integrations topic |
| `:request_log_mode` | `:sync` | `:async` writes usage rows from `PhoenixKitAI.RequestLog` instead of the calling process (same insert, broadcast, telemetry and sinks); `create_request/1` stays synchronous |
| `:request_log_max_queue` | `10_000` | Async backlog above which callers write synchronously again (no row is dropped) |
| `:log_cache_hits` | `true` | `false` skips the zero-cost usage row of a cache hit (a call's `log_cache_hit:` wins); the hit telemetry event still fires |
| `:box_formats` | `%{}` | Model-id prefix → how that model writes a box (`:yx_1000`, `:xy_1000`, `:xy_fraction`, `:yx_fraction`), merged over the built-in table (`PhoenixKitAI.Box.format_for/2`; longest prefix wins; a call's `box_format:` wins over both). An unknown value is ignored with a warning |
| `:allow_internal_image_urls` | `false` | Lift the image-fetch host policy (loopback / link-local / RFC 1918 / `.local`, resolved addresses included) — tests and air-gapped installs only; separate from the endpoint base-URL switch |
| `:journal_prune` | `[]` | Options of the journal cleanup (`PhoenixKitAI.JournalPruneWorker` → `Retention.run/3`): `request_batch:` 1 000, `content_batch:` 500 (halved after a chunk's `statement_timeout`, down to `content_min_batch:` 50, which is capped at `content_batch`), `event_batch:` 1 000, `pause_ms:` 50 between chunks (at most 5 000; a longer one is 5 000, with a warning), `max_rows:` 1 000 000 per counter per run, `statement_timeout_ms:` 30 000 and `lock_timeout_ms:` 5 000 per chunk, `time_limits:` `%{requests: 600_000, content: 360_000, guard_reasons: 60_000, guard_events: 120_000}` (ms). An invalid value falls back to its default with a warning; time limits that would not fit in the job's 25-minute `timeout/1` — their sum plus, per counter, one `pause_ms` and one chunk and one probe at `statement_timeout_ms` + 5 s (a counter overruns its slice by at most that; the content step starts no later range once its slice is over), plus a minute — fall back to the defaults as a whole, and a `statement_timeout_ms` too long for even the default slices (32 500 − `pause_ms` / 2 or more; 32 475 at the default pause) is lowered, with a warning naming it, to the largest that fits (`Retention.run_options/1`; the run never budgets past `timeout/1`). `lock_timeout_ms` is not part of the budget: PostgreSQL's statement timeout bounds a lock wait too. `:now` and `:actor_uuid` are ignored (they are the job's own); a value that is not a keyword list is ignored with a warning. `preview_timeout_ms:` (60 000) is the statement and lock timeout of a preview's counts, read separately; past it the preview is `{:error, :preview_timeout}` |

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
- **The connection picker** is the form's own `EndpointForm.connection_picker/1`
  (not core's `integration_picker`): each card is a toggle button with
  `aria-pressed` and a radio mark, its status badge ("Connected", …) apart
  from the selection, inside a labelled `role="group"`; >6 cards get core's
  `IntegrationPickerSearch` hook. **Auto-pick:** a provider's only *usable*
  connection (one with credentials, `Integrations.connected?/1`) is picked on
  a new endpoint's mount (after a recommendation's prefilled one) and when the
  provider changes — never on an edited endpoint's mount, and on a provider
  change only when nothing is stored or it is the stored connection. With
  several usable connections nothing is picked. An unpick is not undone while
  the provider stays. An orphaned `integration_uuid` renders a
  "deleted/missing" warning card; there is no silent rebinding on PubSub
  changes.
- OpenRouter's `/models` excludes embeddings, so a curated list in
  `OpenRouterClient` supplies them. Mistral's `/v1/models` returns chat and
  embeddings together, and its `/audio/voices` feeds the TTS voice picker.
- Endpoint cards show an enabled badge, an integration-health badge
  (missing/error/not-connected), and a masked key via
  `Endpoint.masked_api_key/1` (the last 4 characters only — every base
  `ai` holder sees the list). A stored key is never rendered in clear,
  the legacy `api_key` notice on the form included — it shows the masked
  form and asks for an Integration instead. `integrations_by_uuid` is loaded once per render
  to avoid an N+1.
- **Image verbs pick an adapter by provider key** (`PhoenixKitAI.Provider.for_endpoint/1`):
  OpenRouter, xAI and OpenAI have their own; everything else gets the
  OpenAI-compatible default. A new image provider is an adapter module plus
  a `:provider_adapters` entry — no edits to `Completion` or `Images`.
- Endpoint-form model fetching drives `models_loading` /
  `models_loading_slow` (10s hint) / `models_error` with Retry, all consolidated
  in `start/stop_model_fetch_indicators/1`. Neither round-trip runs in the
  LiveView process: validation is a supervised task, the `/models` fetch is
  `start_async(:model_fetch)`, and a result for a connection or model type
  the operator has left is dropped.
- The chat model list keeps every model whose only output is text
  (`output_modalities == ["text"]`, or the right side of `modality`), so
  models that also take images are in it. Each card carries the model's
  `PhoenixKitAI.Capabilities` as badges (images, documents, image
  generation, tools, JSON schema; a grey "?" with a hint where nobody
  verified it; an Anthropic model's lifecycle) and no price badge where the
  listing names no price; where the catalogue says nothing, the
  Current Model panel offers checkboxes that declare capabilities in
  `provider_settings["capabilities"]` for that model id only (the changeset
  drops a declaration naming another model; each change is an
  `endpoint.capabilities_declared` activity). An Anthropic endpoint's list
  comes from the native `/v1/models` (all pages, all lifecycle stages),
  with the headers the core registry declares for `anthropic`
  (`validation.extra_headers`; `anthropic-version` of this module when it
  has none). DeepSeek's `/models` (input/output modalities, context window)
  and Mistral's `/v1/models` (`capabilities.vision`, `function_calling`,
  context length) are catalogues too; OpenAI, xAI and Z.ai list no
  capabilities (`:unknown` unless declared). With "only verified models"
  on, an `:unknown` need refuses the call — image generation included
  (`generate_image` / `edit_image` / `process_image` need `:image_output`),
  so on OpenAI / xAI / Z.ai endpoints mark "Image generation" (and the
  other capabilities their tasks need) on the endpoint first.
- The `base_url` guard resolves a name only when the URL is being changed,
  for two seconds at most, never for the provider's registry default and
  never from `change_endpoint/2` (a form's per-keystroke changeset); a name
  that does not resolve is accepted. Chat, embeddings, TTS and adapter calls
  do not follow redirects.

### Completion behaviour

- **Per-call model and fallbacks**: `model:` replaces the endpoint's model for one
  chat or embedding call — it is the model the guard checks, the cache keys and the
  usage row names and prices; `models: [...]` is sent to OpenRouter as its
  model-routing fallback list (the call's model first) and ignored for other
  providers, and is part of the cache key. A fallback that answered is the row's
  `metadata.answered_model` (`Request.other_model/2`: a provider prefix on one side,
  letter case or a dated snapshot of the asked model is the same model).
- **Usage accounting**: OpenRouter chat calls send `usage: {include: true}` so the
  response carries `usage.cost` (stored in dollars as it came, so even a
  $0.00000004 call keeps its cost); other providers don't get it.
- **Delivery options** — `retry:`, `timeout:`, `concurrency:`, `log_cache_hit:` — change
  how a call is made, not what is asked, so they are dropped from the cache key.
- **Endpoints by name**: `get_endpoint_by_name/1` / `resolve_endpoint_by_name/1`
  let an app name an endpoint ("Label reader") instead of carrying its uuid;
  case-insensitive, surrounding spaces ignored on both sides.
- **Usage by source prefix**: `list_requests/1` and `get_usage_stats/1` take
  `source_prefix:` (LIKE-escaped) to total one app's calls across its many
  `source:` strings.
- **Runs**: every verb takes `run:` and `step:` (strings, at most 200
  characters; `Guard.run_tag/1`), stored on every row the call writes —
  success, error, refusal, cache hit — through the admission's
  `row_metadata` / `task_metadata`. `run_costs/2` totals a run by step and
  model; `list_requests/1` and `get_usage_stats/1` filter by `run:` /
  `step:`. Not part of the cache key (`cacheable/1` drops them), so two
  runs over the same input share an entry. `process_image(verify:)` passes
  them to its check. The tag has no index: pass `since:` on a large
  journal.
- **Image embeddings**: `embed/3` takes images (`{:image, input}`,
  `%{image:, text:}`), checked and inlined by `Images.normalize_inputs/2`
  and sent as OpenRouter multimodal `content` inputs; the image bytes are
  never on the row (`image_count` is). The answer carries `"space"`
  (`"<model>:<dimensions>"`); vectors from two spaces are not comparable.
  No guard need is implied — a text-only model answers images with a
  provider error.
- **Several images in `extract_text/3`**: `images_as:` says how they relate —
  `:pages` (one document, the default), `:separate`, or a caller's own
  sentence — and is part of a caller-supplied cache key.

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
  Logged with tokens, the cost (vision: `CallCost`, like chat; making or
  editing images: `usage.cost` when reported), image counts and byte
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

Tables `phoenix_kit_ai_endpoints`, `phoenix_kit_ai_prompts` and
`phoenix_kit_ai_requests` were created by core's versioned chain before this
module had one. **V5 adopts them** (see below): the chain owns their shape, so
a schema change to one is a new version here, never a core migration (core
refuses them since V223). Core's V135 baseline plus V164, V169, V193 and V223
shaped them; the floor `~> 2.64` carries all of those.

`migration_module/0` returns `PhoenixKitAI.Migrations`, the module's own
chain for all of its tables (`mix phoenix_kit.update` runs it after core's). Version marker: `COMMENT ON TABLE phoenix_kit_ai_model_capabilities
IS 'ai_schema:<N>'`. Every statement guards itself, so the chain re-runs
cleanly; additive only. V1 creates `phoenix_kit_ai_model_capabilities`
(unique `(base_url, model)`, flags `yes`/`no`/`unknown`), the snapshot
`PhoenixKitAI.Capabilities` loads at start. V2 creates
`phoenix_kit_ai_task_settings` (unique `task_key`),
`phoenix_kit_ai_task_user_limits` (unique `(task_key, user_uuid)`, deleted
with the user) and `phoenix_kit_ai_guard_events` (`kind` CHECK — a new kind
is a new version; unique `dedupe_key WHERE dedupe_key IS NOT NULL`; user
`CASCADE`, endpoint/request/actor `SET NULL`), and the index
`phoenix_kit_ai_requests_task_inserted_at_index` on core's journal,
`((metadata->>'task'), inserted_at)` with no status condition (core's
schema repair reports extra columns of its tables, not extra indexes), and
`file_input` / `image_output` flags on the snapshot (`unknown` until a
later version fills them). V3 creates `phoenix_kit_ai_guard_blocks`
(user `CASCADE`; origin event, blocker and lifter `SET NULL`; reason and
lift note ≤ 500; one active block per group and person — unique
`(block_group, user_uuid) WHERE lifted_at IS NULL`). V4 converts money to dollar strings (needs core's V223 `cost`). V5 adopts
the three core-created tables: `CREATE TABLE IF NOT EXISTS`, guarded
constraints and indexes, exactly as a fresh core builds them, a no-op on
every existing install. **It is emitted ahead of V2's statements, not last**
(`version_up/3`): V2's foreign keys and its journal index, and V4's
conversions, touch those tables, and without core's copy only V5 creates
them. The number is still the next one; a target below 5 builds the old chain.
Down from 5 only moves the marker and never drops an adopted table. Down to 2
drops it (V3's table); down to 1 drops what V2 added; down to 0 also the snapshot, which the next
refresh rebuilds.

**Before V2 on a host with a large journal, measure it**
(`SELECT count(*), pg_size_pretty(pg_total_relation_size('phoenix_kit_ai_requests'))`)
and run the update in a quiet window: the index is built with a plain
`CREATE INDEX`, which holds a SHARE lock on `phoenix_kit_ai_requests` — every
AI call's usage row waits — until it is built. `CONCURRENTLY` is not
possible in this chain: the wrapper `mix phoenix_kit.update` generates for a
module's migration has no `@disable_ddl_transaction`, so the chain runs in
the migration's transaction, where `CREATE INDEX CONCURRENTLY` is refused;
running it on another connection from inside the migration would wait for
that very transaction to end. It needs a change in core's generator (a
module asking for a non-transactional wrapper), not here. A host that
edits its committed wrapper to `@disable_ddl_transaction true` still gets
the plain build: the chain does not switch to `CONCURRENTLY` on its own.

Between new code and the migration (code on V2, database still on V1) the
capability snapshot cannot be loaded — its new columns are missing — and
`Capabilities` starts with an empty cache, logged, until its first refresh;
nothing fails. Migrate before starting the new code (`upgrade.sh` does).

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
  `:integration`. The `test` alias in `mix.exs` tries `ecto.create` (best
  effort: a role without CONNECT on `postgres` skips it), then
  `test_helper.exs` preflights the database and **raises** when it is
  unusable rather than quietly excluding the tag — a broken database used to
  report "0 failures" with most of the suite skipped. `:integration` is
  excluded only under the explicit `PK_AI_SKIP_DB=1` opt-out.
- The schema is built by `PhoenixKit.Migration.ensure_current(TestRepo, log: false)`
  — core's own chain, the same call a host makes — and then by this module's
  chain through `Ecto.Migrator` and `PhoenixKitAI.Test.SchemaMigration`. It re-applies newly shipped
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
  `test/core_pin_conformance_test.exs` rejects a three-segment `~> 2.x.y` core pin
  (which would exclude every later core minor and break consumers, never this
  repo) and a path override reaching a commit;
  `test/schema_prefix_conformance_test.exs` asserts every table-backed schema uses
  `PhoenixKit.SchemaPrefix`.
- `test/phoenix_kit_ai_test.exs` covers the behaviour callbacks: `module_key/0`,
  `module_name/0`, `version/0`, `admin_tabs/0`, `css_sources/0`, `js_sources/0`,
  `permission_metadata/0`.
- i18n tests are skipped unless core exports `PhoenixKit.Dashboard.Tab.localized_label/1`;
  the current core floor is well past that, so the exclusion is a formality.
- `Xai.RealtimeBehaviour` is mocked with Mox via the `:realtime_module` app env.

## Feature notes

- Every provider-calling verb goes through one gate and one wrapper:
  `authorize/5` (endpoint usable; the user is not blocked from the task,
  `PhoenixKitAI.GuardBlocks`; the model fits what the call and its
  task need, `PhoenixKitAI.Guard`; the task's limits have room,
  `PhoenixKitAI.TaskLimits`; spend caps have room) and `with_cache/6`
  (key, lookup, zero-cost hit row). A new verb joins both or it is not a
  verb — `dev_docs/guides/spend-caps-and-caching.md` holds the semantics
  of caps, cache, structured output and telemetry. A refusal past the
  endpoint check (`{:task_disabled, key}`, `{:task_blocked, group}`, `{:model_unfit, missing}`,
  `{:model_unverified, unclear}`,
  `{:task_limit_exceeded, scope, unit, period}`, `{:budget_exceeded,
  scope}`) writes an error row through `refuse/4`,
  marked `metadata.refused: true`; `dispatch_usage_sinks/1` skips those.
- AI tasks: modules declare `%PhoenixKitAI.TaskSpec{}`s in `ai_tasks/0`
  (duck-typed); `PhoenixKitAI.Tasks` keeps the registry, `fitness/2`,
  `endpoint_options/1` and `check_selection/2`. The registry is rebuilt
  only when the module set changes, or a minute after a build in which a
  module's `ai_tasks/0` failed (raised, exited or threw; meanwhile the
  module keeps the tasks it declared when it last answered, so a failure
  never hands its keys to a later declarer — before a first answer it has
  none) — not when code
  is hot-reloaded: a changed `ai_tasks/0` with the same modules needs a
  restart to show. Every verb takes `task:`; every row it writes
  (success, error, refusal, cache hit, unparsed JSON) carries
  `metadata.task`, and `:task` is not part of the cache key. A key no
  module declares is logged once and the call goes on. This module
  declares `ai.translation` and `ai.playground`. A host app that is not a
  kit module lists its own modules in `config :phoenix_kit_ai,
  task_providers:` (run time; part of the registry's rebuild key): read
  after the registered modules, always `enabled: true` (`enabled?/0` is
  never asked of a provider — `Tasks.provider?/1`), a module listed both
  ways counts as a kit module. A colliding key keeps the first declaration
  (kit modules first, then providers in config order); the dropped one is
  warned about naming both and listed by `Tasks.collisions/0` on AI →
  Tasks. `spec.module` may therefore be a plain host module: never call a
  `PhoenixKit.Module` callback on it. One writer: `PhoenixKitAI.Tasks.Builder` (in
  `children/0`) builds, serially and always for the current config; reads
  stay a lock-free `:persistent_term` hit, and a miss asks the builder.
  Each `ai_tasks/0` runs in its own UNLINKED process
  (`spawn_monitor`) bounded by `:task_registry_callback_timeout_ms`
  (default 5 s): a crash, a crashing linked child or a timeout is that
  module's failure and never reaches the builder. Its reply goes to a
  process alias dropped when the wait ends (no stray late message), and a
  watchdog kills it at its deadline or when its caller dies. A call from
  inside a build (the builder, a process mid-inline-build, a callback, or
  anything a callback starts — callback processes are marked, found
  through `$callers`) answers from the last cached registry; an unrelated
  task of the builder's caller reads normally. Without the builder (a host not
  starting the kit's children) a caller builds a state for itself only —
  never cached, same runner and timeout. The test helper starts
  the builder (unlinked), so tests see caching as a host does. Read one snapshot per lookup (`Tasks.overview/0` for a page).
  An improper `task_providers` list is bad config (warned, its proper part
  used). A switched-off module's task refuses calls: `for_call/1`
  carries `enabled` from the same snapshot (the module's `enabled?/0` is a
  cached settings read), and `authorize/5` (and `Guard.admit/4`) refuse
  with `{:error, {:task_disabled, key}}` first, before blocks, the model
  check and the request cache, as a refusal row. With the AI module off
  that includes `ai.translation` and `ai.playground` — no other gate in
  the call path checked `ai_enabled` before. `TranslateWorker` does not
  retry it (not in `retryable?/1`): the job is discarded with a terminal
  `task_disabled` event. No task and an undeclared key are unaffected.
  The realtime voice session runs no task, so it checks the switch itself:
  the Playground refuses to start or speak while the AI module is off
  (closing an open session, with a flash), and `Realtime.Session` closes
  and stops on any send while it is off (`enabled?:` option).
- Task limits (`PhoenixKitAI.TaskLimits`): scope `:task` (every call of
  the task) and `:user` (one user in it) × money (dollars) / requests
  / tokens × calendar day / month in the site time zone. In force, cell by
  cell: the user's personal limit, else the task's default for users, else
  the declaration's `default_limits`; the task's own, else the
  declaration's. A task declared with `user_limits: false` (its module
  limits its users) has no `:user` scope: the declared and stored user
  values are ignored (kept), and `put_user_limits/4`, `forgive/6` of
  `:user` and `update_settings/3` with a user amount are
  `{:error, :user_limits_off}`. Empty is none, `0` allows nothing.
  Counted from the journal by `metadata->>'task'` (and `user_uuid`),
  `status = 'success'` only — a cache hit is one request and no money or
  tokens, a refusal never counts; money where a call has a cost
  (`PhoenixKitAI.CallCost`: the provider's own, else a catalogue, manual or
  built-in Anthropic price; `TaskLimits.money_counted?/2`, which for a task
  that makes images (`:image_output`) counts only the provider's own, and
  for one that reads them (`:vision`) is the chat rule — so a caller asking
  `money_counted?(endpoint, [:vision])` gets the chat answer). Checked in
  `authorize/5` after the model check and before `Budget`; a reached limit
  is `{:error, {:task_limit_exceeded, scope, unit, period}}` with a refusal
  row. Forgiving restarts one scope and period's count from that moment
  (kept only as a `limit_forgiven` event). `Guard.admit/4` checks the
  limits once for a piece of work (an assistant's turn) and gives a token
  for `guard_admission:`; calls with it skip the limits (not the model
  check, not `Budget`), only for the same task and user and until it
  expires. Tokens live in the request cache's flags table, on one node.
  A call reads the task's settings and personal limits from a per-node
  cache in the same table (dropped on every change through `TaskLimits`,
  here directly and on the other nodes through the guard topic; all of it
  when `GuardWatch` starts; each entry read again after 60 s, which bounds
  a lost broadcast and a change made inside the caller's transaction): a
  task without limits costs about one load a minute; the usage is read only
  when a limit is in force.
- Guard signals (`PhoenixKitAI.GuardEvents`): `limit_warning` (at the
  task's warn percent, default 80: a user's limit tells the user in the
  app, the task's the watchers), `limit_reached` (the user and the
  watchers; a `Budget` refusal too, scope `budget:<scope>`, once per local
  day), `limit_forgiven`, `model_unfit` (`PhoenixKitAI.GuardWatch`: a
  task's endpoint that was fit and is not after a catalogue refresh or an
  endpoint save, once a day per task and endpoint). Once per window is a
  unique `dedupe_key` inserted with `ON CONFLICT DO NOTHING`; only an
  insert that went through signals. Watchers: `ai_guard_watchers` (else
  every Owner) and the task's `watchers` callback, never the user; type
  `"ai_guard"`. Activity: `guard.<kind>` with the event as `resource_uuid`
  (never `target_uuid`). Texts carry no reasons and nothing of a call. A key
  that was inserted is also kept on the node until its window ends, so a
  limit past its threshold costs no further INSERT. `GuardWatch` emits
  `[:phoenix_kit_ai, :guard_watch, :look]` after each look. Events are
  kept until a period is set for them (journal retention, below; forever
  by default).
- Journal retention (`PhoenixKitAI.Retention`, applied by
  `PhoenixKitAI.JournalPruneWorker`): three kinds, each kept forever until
  a period is set. `content` — journal rows older than the period lose the
  `content_keys/0` from `metadata` and get `metadata.content_pruned_at`; the
  row, its cost, tokens and small keys stay; the `reason` of an
  `off_purpose` event older than the boundary is cleared too. `requests`
  — journal rows are deleted. `guard_events` — events are deleted. A
  period's boundary (`cutoff/3`) is local midnight N days back, or the
  start of the local month N months (years: 12·N) back, in the site time
  zone (an empty or unusable zone is UTC). Under every boundary, whatever
  its origin — the night, a preview, `run_now/2`, a job's arguments —
  `effective_cutoff/3` puts the floor (`floor/2`): rows and events newer
  than local midnight two days before the first of the current month are
  never deleted (the day and month task limits, a month's
  `limit_forgiven` events and the trailing 24-hour cap, which reaches into
  the previous month on the 1st, read them; the two days cover a change of
  the site's time zone and clock skew between nodes), and content newer
  than 24 hours is never cleared. A shorter period is clamped, not refused
  (the preview's `clamped`); a boundary after now is
  `{:cutoff_in_future, kind}`, one that is not a `DateTime`
  `{:invalid_cutoff, kind}`. The event an active block was set from
  (`origin_event_uuid`, `lifted_at IS NULL`) is neither deleted nor
  cleared while the block stands.
  Nightly (`oban_crons/0` → `{"17 3 * * *", PhoenixKitAI.JournalPruneWorker}`,
  core's `default` queue): a kind kept forever or changed less than 24 hours
  ago (`changed_at`) is skipped; with the module off the run is stamped
  `skipped`; a night whose last scheduled run is `ok` and under 20 hours
  old runs nothing and writes no stamp (once a night: a second crontab
  entry, the shim, a host's deliberate second schedule). By hand:
  `run_now/2` queues `JournalPruneWorker.manual_job/2` with the boundaries
  clamped, and the job clamps them again. One job at a time: Oban
  uniqueness on the worker over `available` / `scheduled` / `executing` /
  `retryable` (no `:suspended`: Oban's unique query fails with it on a
  database migrated before Oban 14, and the cron inserts through `new/2`),
  so a night while a manual run is queued or running does not run and a
  second `run_now/2` is `:prune_running`. `timeout/1` is 25 minutes (under
  Lifeline's default 60-minute rescue), `max_attempts: 3`.
  A run's order: journal rows → content → off-purpose reasons → guard
  events, each in chunks, each chunk its own transaction with
  `SET LOCAL statement_timeout` / `lock_timeout` and the chunk chosen in a
  `MATERIALIZED` CTE (as `uuid IN (subquery)` the planner may run a
  `LIMIT … SKIP LOCKED` subquery again and delete more than the limit).
  Rows: keyset by `(inserted_at, uuid)` with `FOR UPDATE SKIP LOCKED` —
  the only step that skips locked rows — and whether any are left is a
  probe (`inserted_at < boundary LIMIT 1`), never a short chunk. Content:
  keyset windows of `content_batch` rows in `[lower, content boundary)`,
  updating the ones that carry a content key and waiting for a locked row;
  `lower` is the later of the rows' boundary and `content_done_before`
  only when the row step ran and left nothing — with a tail left, the
  content of the rows that stay is cleared first, then the tail's — and
  `content_done_before` moves only once everything below the boundary is
  done (a stopped step keeps `content_resume`). Reasons and events:
  unordered chunks (no index leads with the events' `inserted_at`; the
  table is small), finished by a probe. Each counter has a time slice
  (rows 10 min, content 6 min, reasons 1 min, events 2 min) and a
  `max_rows` cap; what is left is `more_left`, continued by the next night
  or run. Before anything, `check_foreign_keys/1` reads `pg_constraint`
  for every key referencing the journal or the events (by schema-qualified
  name): each must be `ON DELETE SET NULL`, on one nullable column, with a
  valid index leading with it (no predicate, or `col IS NOT NULL`), else
  `{:foreign_key_blocks, table}` and nothing is deleted; the preview
  reports the same. Rows written during a run are newer than any boundary.
  Audit: `PhoenixKit.Activity.log("ai", …)` with `permanent: true` (core's
  Activity pruning must not remove the trace of a deletion), `mode:`
  `"manual"` / `"cron"`, the person of a manual run, and metadata of counts
  (`content_cleared`, `requests_deleted`, `guard_events_deleted`,
  `guard_reasons_cleared`), boundaries (`content_before`,
  `requests_before`, `guard_events_before`) and `more_left` — no row uuids,
  no content. `journal.pruned` for every manual run and every night that
  did something (an idle night is only in the stamp); `journal.prune_failed`
  with `error` (a Postgres error code or an exception module, never the
  database's message) and the counts already committed. A failed check is
  `{:cancel, reason}` (no retry, `failed` in the stamp), and a nightly one
  is logged to Activity once per 20 hours per class; a failed chunk is an
  error, retried by Oban, each attempt counting from zero. A job with
  unreadable arguments (a manual one) is stamped `failed` (`invalid_args`)
  and cancelled.
  UI: the "Journal retention" card on AI → Usage
  (`Web.JournalRetention`, markup `Web.Components.JournalRetentionCard`):
  per kind a number and a unit or "keep forever", with
  `Retention.warnings/4` under it; saving a shorter or first finite period
  (`Retention.shorter?/4`) goes through a preview and a confirmation; the
  nightly line (off / first cleanup of a kind not before a date / the last
  night within 36 hours with its counts and "more left" / failed / not run,
  check the crontab), the last manual run, a pending job read from
  `oban_jobs` (a stuck `executing` shows); "Clean up now" per kind (leave /
  by the saved period / a value for this run only) with a `start_async`
  preview, the confirmation acting on the boundaries in the page's assigns,
  never the event's parameters. The page follows core's settings topic and
  draws from the value in `{:setting_changed, key, value}` (core announces
  before its transaction commits). Totals on the Endpoints and Usage tabs
  say "for the retained period, since <date>" once rows may be gone (a
  finite rows period, or `rows_deleted_before` set); a request's details say
  when its content was removed. Without `ai.manage` the card is read-only.
  `PhoenixKitAI.GuardEventsPruneWorker` is a shim: `perform/1` only inserts
  a `JournalPruneWorker` job (its uniqueness and the once-a-night rule
  apply) and deletes nothing; `retention_days/0` is deprecated. It left
  `oban_crons/0`, but a host's crontab entry of it, or a job already
  queued, still works.
- Off-purpose use (`PhoenixKitAI.Guard`): the consumer flags, the guard
  never edits a prompt or a schema. `self_flag?/1` (the task's guard mode,
  else the declaration's `self_flag`) before building the prompt; the mode
  is set to `off` or `self_flag` on the Tasks page
  (`TaskLimits.set_guard_mode/3`, `ai.manage`; the classifier modes come
  with the classifier);
  `self_flag_instruction/1` is English text with the purpose (an admin's
  override when set), "refuse politely and flag", "judge only the user's
  own message" and "no quote in the reason"; `report_off_purpose/4` writes
  one `off_purpose` event per turn (`%{turn_ref: …}`) or call (the row's
  request uuid), reason ≤ 500 (kept only while `capture_request_content?/0`
  is true, like any text that can echo the user), a no-op (`:off`) while the task does not
  self-flag, and tells the watchers once a day per person and task
  (`off_purpose_signal`, no reason). Anomaly rules of a declaration
  (`sources`, `max_calls_per_hour` per person, `max_tokens_per_call`) are
  checked after each journal row (`check_anomalies/1`, not for refusals;
  a task without rules costs nothing; the hourly count is skipped once its
  rule was signalled that day) and signalled once a day per rule
  (`anomaly`); they never block.
- Blocks (`PhoenixKitAI.GuardBlocks`): set by a person — no automatic
  block. A block lands on the task's `block_group` (else its key);
  `ai.playground` and an assistant's chat share `free_text`. Checked in
  `authorize/5` first after the endpoint (not for a dry run, not for a call
  with an admission of `Guard.admit/4`, which checks it), refusing with
  `{:error, {:task_blocked, group}}` and a refusal row — the group, never
  the reason. Set: `ai.manage` or an Owner; only an Owner blocks an Owner.
  Lift: an Owner (their own too, with a record), else `ai.manage`, or
  `agent.manage` for a `free_text` block (checked by string), never one's
  own and never an Owner's. `blocked` / `unblocked` events, watchers (but
  the actor) and the person told, Activity by the event — no reason or
  note. Active blocks are cached per node like the limits (one query a
  minute; dropped on block and lift, here and through the guard topic).
  A private group (any of its tasks `private`) shows its reasons only to
  `ai.manage` and Owners (`Guard.reasons_visible?/2`, `GuardEvents.flags/3`;
  `GuardBlocks.active/2` gives the state without the reason or note,
  `active/3` with them for a viewer allowed to see them). Reasons and notes
  are cut to 500 code points (what the CHECK counts), never inside a
  grapheme.
- Recommendations (`PhoenixKitAI.Recommendations`, live data only — no list
  of "best models", no `recommended:` in declarations): `ranked/2` takes
  the catalogue the capability cache holds for the base URLs the endpoints
  use and groups the models by capability first: `verified` (`:fit` for
  every need), `possible` (nothing `:no`, something `:unknown`, named in the
  row's `unverified`) and `experimental` (an id with `preview`/`beta`/`exp`,
  a `:free` variant or a free price, an alias, or no price in OpenRouter's
  catalogue — at most one free row). The needs are the task's, its images /
  documents / image generation ones replaced by the filters (the task's own
  by default; `refilter/2` regroups without the journal). Models must
  answer in text unless image generation is needed; retired ones are
  dropped, deprecated marked. Inside a group the rows are ranked by
  `typical_tokens × catalogue prices` (else the journal's median tokens over
  30 days, else the input price alone — `estimate: :rough`). Anthropic,
  DeepSeek and Mistral list no prices: unpriced, after the priced rows, one
  place kept; never mapped to an OpenRouter model by name. `cheapest/2`
  is every fit model by price, whatever it looks like. The
  cache therefore keeps each model's `name`, `prompt_price`,
  `completion_price` and `text_output` (not in the DB snapshot: after a
  restart they are empty until the first refresh). `worked/2` is one
  aggregate over `phoenix_kit_ai_requests` by `metadata->>'task'`, without
  `metadata.refused` rows. The UI is `Web.Components.TaskModelPicker`
  (`picker/1` for a consumer's form field, `recommendations/1` for the
  panel alone, as on AI → Tasks); the panel is the live component
  `Web.Components.RecommendationsPanel` (its filters are its own state,
  kept over the page's re-renders); its create link needs
  `ai.manage_endpoints` in the `scope` attr and opens the new-endpoint form with
  `?name=&model=&integration_uuid=` prefilled — never saved by the link.
- Every verb's result names its usage row: `"request_uuid"` in the chat and
  embedding responses, `:request_uuid` in the other verbs' maps; a cache
  hit names the row it wrote, not the first one.
- Anthropic (`api.anthropic.com`, its OpenAI-compatible layer): the
  endpoint's stored `temperature`/`top_p`/`top_k`/penalties/`seed` are
  not sent, a caller's own sampling values are (never `temperature` with
  `top_p`, and neither to a model from Claude Opus 4.7 on, decided from the
  model id — `Completion.anthropic_sampling?/1`; an id it cannot read
  counts as newer), and the OpenRouter-shaped reasoning options become `thinking`
  only in a form the model's catalogue lists
  (`capabilities.thinking.types.<type>.supported`): a token budget as
  `enabled` + `budget_tokens`; `reasoning_enabled: false` as `disabled`,
  else `between_tools`; otherwise (thinking on, an effort alone, or the
  catalogue not read yet) no `thinking` is sent and the model keeps its
  default. `adaptive` is never sent: the compatibility layer answers it
  with a 400 and ignores `reasoning_effort` (ported from
  BeamLabEU/phoenix_kit_ai#47, 8e8c65e).
- On OpenRouter a call with a hard `:tools`/`:json_schema` need sends
  `provider.require_parameters` — only when the model's parameter list is
  in the capability cache (not before the first catalogue read after a
  restart, not for a model the catalogue lacks) — and leaves out the
  parameters that list lacks (`metadata.stripped_params`, logged once per
  endpoint and parameter); `max_tokens`, `tools` and `response_format` are
  never left out. OpenRouter's "no provider for these parameters" answer
  is `{:no_provider_for_params, params}` (the endpoint's parameters only).
- A refused row is `status: "error"` with `metadata.refused`; the Usage tab
  marks it "Refused" and its status filter has a `refused` choice.
- Structured output (`schema:` / `json: true`) is parsed *inside* the
  cached closure, so a prose answer to a JSON request is logged with its
  usage but never stored as a success.
- A cache hit's usage row is the fresh row minus cost: same `user_uuid`,
  attribution, prompt link and snapshot. Reports that ignore
  `metadata.cached` still add up.
- A module's background translation top-up is `PhoenixKitAI.TranslationSweep`:
  the module keeps its own Oban worker (already-scheduled jobs name it) and
  implements the callbacks; the engine owns the chain (one waiting tick per
  worker), the gates, both caps (a candidate that does not fit whole is
  admitted for the languages that do), holding back a pair whose latest job
  was discarded in the last day, and the recorded outcome. A module whose
  `phoenix_kit_ai` dependency is optional implements the callbacks without
  declaring the behaviour.
- The sweep translates with `Translations.unattended_endpoint_uuid/0`, not
  the modal's `default_endpoint_uuid/0`: an explicit
  `ai_translation_endpoint_uuid` is binding (gone or disabled stops the tick
  as `:ai_unavailable` with the reason under `"endpoint"`, nothing is
  enqueued), and the "last used" endpoint is never consulted.
- A rate-limited translation job snoozes at most five times (30 s,
  doubling); after that a 429 is an ordinary retryable failure, so an
  exhausted quota ends in `ai.translation_failed` instead of holding its
  in-flight slot.
- `use PhoenixKitAI.Components.AITranslate.Embed, authorize: …` gates the
  translate modal: a 1-arity remote capture or `{m, f, args}` (called with
  the socket first), evaluated against the live socket for each of the six
  `ai_*` events before anything is dispatched; falsy halts with an error
  flash and enqueues nothing. Omitted, every event is dispatched (kept for
  existing hosts) — a host should always pass it, since the hook halts
  those events before any host `handle_event` could re-check.
- Host translatables (`config :phoenix_kit_ai, translatables:`) implement
  `PhoenixKitAI.Translatable` (`fetch/2`, `source_fields/2`,
  `put_translation/4`); a configured entry wins over a module's adapter
  for the same type without a duplicate warning.
- The translation glossary only reaches the model through a prompt that
  has a `{{Glossary}}` slot. The shared prompt carries one only on installs
  provisioned from 0.23.2 on — `Translations.ensure_default_prompt/0` never
  rewrites an existing, operator-editable prompt — so an older install
  adds the line to its prompt by hand; until then the setting is silently
  inert.
- Located answers: `detect_regions/4`, `check_statements/4`,
  `describe_image/3` with `regions:` and `extract_text/3` with
  `boxes: true` return `PhoenixKitAI.Box` structs. Boxes are asked for as
  `[ymin, xmin, ymax, xmax]` on 0–1000 and read in the format the
  *answering* model writes (`Box.format_for/2`) — never guessed from the
  numbers; an unusable box is dropped and counted (`dropped_regions`), not
  repaired. The new verbs are `describe_image/3` with their own prompt and
  schema (same gate, task needs, cache, row), so a new located verb is a
  prompt + schema in `Images.Regions`, not a new call path.
  `vision_batch/3` runs any of them over many items with a status per item
  (`:ok` / `:error` / `:unparsed` / `:skipped`) and stops on `budget:` or
  on a refusal every later item would hit (`VisionBatch`'s fatal list).
  Every vision result carries `:cost` — the row's (`log_usage/1` hands it
  back in async mode too), zero on a cache hit (`hit_value/3`). An unparsed
  vision answer's row carries `metadata.unparsed: true` (a chat call's does
  not), and its cost reaches `vision_batch/3`'s budget through the process
  dictionary (`take_unparsed_cost/0`, same process). The new schemas carry
  no `minimum` / `maximum`: Anthropic's strict mode refuses them. The verbs, formats,
  measured model behaviour and what stays in a host app:
  `dev_docs/guides/image-processing.md` ("Locating and comparing").
- Vision answers cut off at the output limit (`Completion.truncated?/1`:
  `finish_reason` `"length"` / `"max_tokens"`): a JSON request — vision or
  chat — is `{:error, {:output_truncated, text}}` (billed; a vision row is
  marked `unparsed` + `truncated`), a text answer carries `truncated: true`.
  `fallback_models:` on `describe_image/3` / `extract_text/3` (and the
  verbs built on them) re-runs the whole verb with the next `model:` only
  for `fallback_reason?/1` errors — never a refusal, a key or balance error
  or an input error — and lists failed attempts in `:fallbacks` (tags only,
  no provider text); it is not part of the cache key. Vision calls pass
  `safety_errors: true` to `Completion.chat_completion/3`, so a 400/403/422
  safety refusal is `{:content_policy, _}` there as in the image adapters;
  plain chat keeps `{:api_error, status}` (its retry rules depend on it).
  `vision_batch(group: n)` (describe only) packs plain items into one call
  with a per-item answer schema and an equal cost share.
  `check_statements/4`: `:contradicted` without an image is reported
  `:insufficient` (`downgraded:`); `confirm:` re-asks the contradicted
  statements and keeps only agreed ones.
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
  capped per identity (today `user_uuid` is a foreign key); per-source /
  per-user *rate* limits (per-key concurrency exists: `PhoenixKitAI.Limiter`;
  spend caps are too coarse against a scrape); retries and the limiter for the
  image adapters (`Providers.HTTP` — today they cover chat, embeddings and TTS only); one `%Result{}` struct
  across verbs instead of provider-shaped maps; streaming chat/TTS with
  cancellation and an async (Oban) mode for slow verbs; provider-neutral
  tool calling; pre- and post-dispatch policy hooks for tenancy and
  redaction; usage rows for the realtime voice session.
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
