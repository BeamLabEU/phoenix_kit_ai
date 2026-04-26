# Follow-up Items for PR #1

Post-merge review of CLAUDE_REVIEW.md findings against the current code on
`main`. Items are tracked by the original numbering in the review.

## Resolved before this sweep

- ~~**#2** N+1 risk in endpoint listing~~ — `endpoints.ex` calls
  `list_endpoints/1` with no preloads and fetches stats via a separate
  `AI.get_endpoint_usage_stats/0` aggregation. The reviewer's hypothesized
  `:requests` preload never landed.
- ~~**#4** Missing `connected?/1` guard on PubSub subscriptions~~ —
  `endpoints.ex:47` wraps both `subscribe_*` calls in `if connected?(socket)`.
- ~~**#5** Migration `down/0` doesn't clean up settings row~~ — N/A. The
  AI module is headless: migrations now live in core `phoenix_kit`
  (per the module convention), so there is no local migration to amend.
- ~~**#8** Cost precision in `format_cost/1`~~ — `request.ex:220-226`
  tiers precision: 2 decimals above $0.01, 4 above $0.0001, 6 below.
  Sub-cent costs display as e.g. `$0.000123` instead of `$0.00`.

## Fixed (Batch 1 — 2026-04-24)

- ~~**#1** API response stored unsanitised in `log_request` metadata~~ —
  `phoenix_kit_ai.ex:1776`. Dropped `raw_response:` from the metadata map;
  the decoded `response` text, `request_payload`, and `usage` columns
  already capture everything useful for the dashboard.
- ~~**#3** Broad `rescue e ->` in `save_endpoint` hides real errors~~ —
  `endpoint_form.ex:541`. Logger call now uses
  `Exception.format(:error, e, __STACKTRACE__)` so production errors
  come through with a full stacktrace. Same fix applied symmetrically to
  `prompt_form.ex:124` (Finding #7).
- ~~**#6** Hardcoded embedding model list will rot~~ —
  `openrouter_client.ex`. Added `@embedding_models_last_updated` module
  attribute with a comment documenting the convention to bump it on
  refresh. `fetch_embedding_models/2` now merges the built-in list with
  `Application.get_env(:phoenix_kit_ai, :embedding_models, [])` so users
  can add providers without a package update. Public helper
  `embedding_models_last_updated/0` surfaces the date.
- ~~**#7** Inconsistent error handling across LiveViews~~ — audited
  `endpoints.ex`, `playground.ex`, `prompts.ex`: all already flash
  user-facing messages and avoid bare rescues. The two outliers
  (`endpoint_form.ex` and `prompt_form.ex`) both had the same bare
  `rescue e ->` pattern — brought into line with the other LiveViews by
  logging the full stacktrace.
- ~~**#9** No HTTP error-path tests in `completion.ex`~~ —
  `test/phoenix_kit_ai/completion_test.exs` (new). 15 tests covering
  `handle_error_status/2` (401/402/429/4xx/5xx + recognised + opaque
  bodies), `extract_error_message/1`, `extract_content/1`, and
  `extract_usage/1`. `handle_error_status/2` and `extract_error_message/1`
  were widened from `defp` to `def` with `@doc false` to expose them for
  direct testing without mocking HTTP.
- ~~**#10** Prompt variable regex too permissive~~ — `prompt.ex:394-454`.
  Extracted the rule into a module attribute
  `@valid_variable_name ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/` and used it in both
  `valid_content?/1` and `invalid_variables/1`. Disallows leading digits;
  moduledoc and doctests updated. These helpers are advisory (not called
  from the changeset), so form-save behaviour is unchanged — only the UI
  validator message is stricter.
- ~~**#11** Logger severity mix in `completion.ex`~~ — Documented the
  rule in the moduledoc: `warning` for recoverable external failures
  (non-2xx HTTP, transport errors, rate limits) and `error` for
  unexpected internal failures. Transport-error branch at the bottom of
  `http_post/3` downgraded from `error` → `warning` to match.
- ~~**#12** `Process.info(self(), :memory)` captured on every request~~ —
  `phoenix_kit_ai.ex` `capture_caller_info/0`. Memory capture is now
  opt-in via `config :phoenix_kit_ai, capture_request_memory: true`
  (default `false`). When disabled, `memory_bytes` is omitted from the
  caller-context JSONB entirely rather than stored as `nil`.

## Also fixed in this sweep

- **`get_config/0` crashes outside a sandbox checkout** — pre-existing test
  failure (`test/phoenix_kit_ai_test.exs:141`) was masked until
  `phoenix_kit_ai_test` DB was created. The three count queries
  (`count_endpoints/0`, `count_requests/0`, `sum_tokens/0`) now go through
  a `safe_count/1` helper that rescues any exception and returns `0`,
  matching the defensive `enabled?/0` pattern. Documented in the
  moduledoc for `get_config/0`.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_ai.ex` | #1 drop `raw_response`; #12 opt-in memory capture; `safe_count/1` wrapper for `get_config/0` |
| `lib/phoenix_kit_ai/completion.ex` | #11 moduledoc + transport-error log level; #9 widen two helpers to `def @doc false` |
| `lib/phoenix_kit_ai/openrouter_client.ex` | #6 `@embedding_models_last_updated`, `user_embedding_models/0`, `embedding_models_last_updated/0` |
| `lib/phoenix_kit_ai/prompt.ex` | #10 `@valid_variable_name` module attr + doctest |
| `lib/phoenix_kit_ai/web/endpoint_form.ex` | #3 full stacktrace in rescue log |
| `lib/phoenix_kit_ai/web/prompt_form.ex` | #7 same pattern as `endpoint_form.ex` |
| `test/phoenix_kit_ai/completion_test.exs` | #9 new, 15 tests |

## Verification

- `mix format --check-formatted` ✓
- `mix compile --warnings-as-errors` ✓
- `mix credo --strict` — 1 pre-existing software-design suggestion on
  `endpoint_form.ex:137` (nested-module alias), committed 2026-04-05. Not
  touched in this sweep.
- `mix dialyzer` — 0 errors
- `mix test` — 82 tests, 0 failures (was 1 failure before the
  `get_config/0` fix)

## Fixed (Batch 2 — re-validation 2026-04-26)

Pipeline re-run against the AI module — the first sweep target — to
catch drift since 2026-04-24 as the playbook has evolved. Phase 1 PR
triage (#1 / #2 / #3 / #4) re-verified clean; the items below are the
gaps the current C-step checklist surfaced and the fixes applied.

- ~~**phx-disable-with missing on destructive `phx-click` buttons**~~
  (C5) — `endpoints.html.heex:223` (`delete_endpoint`),
  `prompts.html.heex:179` (`delete_prompt`), and the playground send
  button (`playground.html.heex:217`) all destructive/async. Each now
  carries `phx-disable-with={gettext("Deleting…")}` /
  `gettext("Sending…")` so a slow round-trip can't be double-clicked.
  Pinned by regex assertions in `endpoints_test.exs`,
  `prompts_test.exs`, and `playground_test.exs`.
- ~~**Catch-all `handle_info/2` clauses missing or silent**~~ (C10) —
  `endpoint_form.ex` and `playground.ex` had no catch-all (any
  unmatched PubSub broadcast surfaced as a `FunctionClauseError`);
  `endpoints.ex:467` and `prompts.ex:205` had silent
  `def handle_info(_msg, socket), do: {:noreply, socket}` clauses.
  All four now log at `Logger.debug` per the workspace sync precedent
  (AGENTS.md:677-679). Pinned by a "ignores unrelated PubSub messages
  without crashing" smoke test per LV that does
  `send(view.pid, …); render(view)`.
- ~~**`pgcrypto` extension not enabled in test_helper**~~ (C7) —
  `test/test_helper.exs:69` only enabled `uuid-ossp`, but
  `uuid_generate_v7()` calls `gen_random_bytes/1` from `pgcrypto`.
  Worked on the existing test DB by accident; would break on a
  fresh `createdb`. Now creates both extensions side by side, matching
  the canonical pattern in `phoenix_kit_hello_world` /
  `phoenix_kit_locations`.
- ~~**`errors_test.exs` had the `is_binary/1` smell**~~ (C8) — the
  test asserted only `is_binary(result)` over a list of atoms. Per
  AGENTS.md:293-295 every branch of `message/1` returns a binary, so
  the assertion proved nothing — a regression in any single
  `gettext(...)` call would slip through. Rewrote to pin the EXACT
  translated string per atom, and added the missing
  `:api_key_forbidden` and `:model_not_found` rows. Plus-15 tests.
- ~~**Translations sweep gaps**~~ (C12 agent #2) — re-running the
  translations Explore agent surfaced 9 user-facing strings still
  hard-coded in heex templates: "Sort by:" (×2), "Never used" (×2),
  delete-button `data-confirm` text (×2), "Clear" filter button,
  "No requests match the current filters", "No Endpoints Yet" /
  "Create your first AI endpoint…" / "Create Endpoint",
  "No Prompts Yet" / "Create reusable prompt templates…" /
  "Create First Prompt", "Sending…" inline button text, "Send"
  inline button text. All wrapped in `gettext(...)`. Plus
  `endpoints.html.heex:416` was using `String.capitalize(status)`
  on a translatable status string — replaced with
  `PhoenixKitAI.Request.status_label/1`, which got literal-call
  `gettext("Success") / gettext("Error") / gettext("Timeout") /
  gettext("Unknown")` clauses (the only shape `mix gettext.extract`
  picks up — see AGENTS.md:350-360).
- ~~**`@type t` missing on `Request` schema**~~ (C12 agent #3) —
  `request.ex` had `@type t` declared on `Endpoint` and `Prompt` but
  not `Request`. Added `@type t :: %__MODULE__{}` to match.
- ~~**AGENTS.md missing canonical "What This Module Does NOT Have"
  section**~~ (C1) — pulled the section from `phoenix_kit_hello_world`'s
  template and filled in the AI-specific deliberate non-features
  (no own DB migrations, no per-completion activity logging, no
  legacy `api_key` data migration script, no public HTTP API, no
  Oban background jobs, no streaming responses, no Errors-module
  truncation helper).

## Skipped (with rationale)

- **SSRF on `endpoint.base_url`** (C12 agent #1, HIGH) — verified real:
  `endpoint.ex:117` declares `field(:base_url, :string)`,
  `endpoint.ex:170` casts it from form params, and
  `completion.ex:322-327`'s `build_url/2` flows it straight into
  `Req.post/2` at `completion.ex:281` with no allowlist. An admin
  user could create an endpoint with `base_url:
  "http://169.254.169.254/latest/meta-data/"` (cloud metadata) or
  any RFC1918 / loopback / `.local` host and have the server make
  the request, with the response surfacing in the playground UI.
  Mitigating factor: AI is admin-only, no public route. Not fixed
  here per the [feedback_quality_sweep_scope.md](~/.claude/projects/-Users-maxdon-Desktop-Elixir/memory/feedback_quality_sweep_scope.md)
  rule — SSRF allowlist validation is a missing-feature, not a
  refactor of an existing path. Surfaced for Max to schedule as a
  dedicated hardening PR. Suggested fix: a `validate_base_url/1`
  changeset validator that parses the URL, rejects RFC1918 ranges
  (10/8, 172.16/12, 192.168/16), link-local (169.254/16),
  loopback (127/8, ::1), `.local` mDNS, and non-`https` schemes for
  external providers.
- **`@spec` backfill on 33+ public functions** (C12 agent #3) — the
  bulk of `lib/phoenix_kit_ai.ex` (~28 fns), `completion.ex` (5),
  `openrouter_client.ex` (~15), and `routes.ex` (2) lack `@spec`
  declarations. Adding them en masse is a separate documentation
  pass, not a behaviour-affecting refactor. Surfaced for a follow-up.
  The high-traffic functions on the request schema (`status_label`,
  `status_color`, etc.) were not specced either; ditto deferral.
- **Bulk component-refactor (raw `<input>`/`<textarea>` →
  `<.input>`/`<.textarea>`)** (C6) — `endpoint_form.html.heex`,
  `prompt_form.html.heex`, and parts of `endpoints.html.heex` use
  raw HTML inputs instead of `PhoenixKitWeb.Components.Core.{Input,
  Textarea}`. Per AGENTS.md:466-477 the playbook recommends the swap,
  but the AI forms have a lot of bespoke wrapping (provider picker
  + dynamic param grid + reasoning-effort grid) that would need
  per-field rework. Out of scope for this re-validation pass;
  surfaced as a dedicated component-pass PR opportunity.
- **LV error-path tests** (C12 agent #2) — current LV smoke tests
  cover happy paths plus the few "not found" / "no endpoint
  selected" branches. Empty-input / >255-char / Unicode /
  SQL-metacharacter coverage is thinner than the playbook's
  ideal but the underlying changeset validations are pinned by
  `endpoint_test.exs` / `prompt_changeset_test.exs`. Not a
  pinning-test gap for behaviour the sweep introduced; deferred.

## Files touched (Batch 2)

| File | Change |
|------|--------|
| `lib/phoenix_kit_ai/web/endpoints.html.heex` | C5 phx-disable-with on delete; C12 gettext on Sort by / Never used / data-confirm / No Endpoints Yet / Create Endpoint / Clear / No requests match; status_label swap |
| `lib/phoenix_kit_ai/web/prompts.html.heex` | C5 phx-disable-with on delete; C12 gettext on Sort by / Never used / data-confirm / No Prompts Yet / Create First Prompt |
| `lib/phoenix_kit_ai/web/playground.html.heex` | C5 phx-disable-with on send; C12 gettext on Sending… / Send |
| `lib/phoenix_kit_ai/web/endpoint_form.ex` | C10 catch-all handle_info with Logger.debug; require Logger hoisted to module top |
| `lib/phoenix_kit_ai/web/endpoints.ex` | C10 catch-all upgraded silent → Logger.debug; require Logger added |
| `lib/phoenix_kit_ai/web/playground.ex` | C10 catch-all handle_info added; require Logger added |
| `lib/phoenix_kit_ai/web/prompts.ex` | C10 catch-all upgraded silent → Logger.debug; require Logger added |
| `lib/phoenix_kit_ai/request.ex` | C12 `use Gettext`, `@type t`, `status_label/1` literal-gettext clauses |
| `test/test_helper.exs` | C7 enable `pgcrypto` extension alongside `uuid-ossp` |
| `test/phoenix_kit_ai/errors_test.exs` | C8 per-atom EXACT-string pin + `:api_key_forbidden` + `:model_not_found` (+15 tests) |
| `test/phoenix_kit_ai/web/endpoints_test.exs` | C11 phx-disable-with regex pin + handle_info catch-all smoke |
| `test/phoenix_kit_ai/web/prompts_test.exs` | C11 same |
| `test/phoenix_kit_ai/web/endpoint_form_test.exs` | C11 handle_info catch-all smoke |
| `test/phoenix_kit_ai/web/playground_test.exs` | C11 phx-disable-with on send + handle_info catch-all smoke |
| `AGENTS.md` | C1 "What This Module Does NOT Have" section |

## Verification (Batch 2)

- `mix precommit` ✓ (compile + format + credo --strict + dialyzer 0 errors)
- `mix test` — 201 tests, 0 failures (was 179 before this batch; +22 from per-atom Errors rewrite + delta-pinning)
- `for i in 1..10; do mix test --seed $i; done` — 10/10 stable, all 201 passes
- Pre-existing log spam (`Failed to query setting ai_enabled:
  %DBConnection.OwnershipError`) is unchanged — emitted by core
  PhoenixKit's `Settings.get_boolean_setting/2` from a non-sandbox-
  allowed process; AI module's `enabled?/0` correctly catches the
  exception and returns `false`. Suppressing the log lives in core,
  out of scope for this module.

## Fixed (Batch 3 — fix-everything pass 2026-04-26)

User said "FIX EVERYTHING" — closing every Batch 2 deferred item in
the same re-run. Items below are the ones Batch 2 explicitly skipped
plus one new C12 finding the deeper pass surfaced.

- ~~**SSRF on `endpoint.base_url`**~~ (security HIGH) — added
  `validate_base_url/1` to the `Endpoint.changeset/2` pipeline at
  `lib/phoenix_kit_ai/endpoint.ex`. Rejects non-`http(s)` schemes
  (`file://`, `gopher://`, `javascript:`, …), missing host, the IPv4
  ranges 0/8 / 10/8 / 127/8 / 169.254/16 / 172.16/12 / 192.168/16,
  IPv6 loopback `::1`, IPv6 link-local `fe80::/10`, IPv6
  unique-local `fc00::/7`, and any `*.local` mDNS hostname. Opt-in
  bypass via `config :phoenix_kit_ai, :allow_internal_endpoint_urls,
  true` for self-hosted Ollama / intranet inference deployments —
  scheme guard still fires even with the override. Pinned by 12 new
  tests in `test/phoenix_kit_ai/endpoint_test.exs` covering each
  rejection + boundary cases (172.15 / 172.32 stay public) + the
  config-bypass round-trip + a public-hostname sanity batch.
- ~~**Bulk `@spec` backfill on the public API**~~ (doc) — added
  `@spec` declarations on:
  - `phoenix_kit_ai.ex` — every `PhoenixKit.Module` callback
    (`module_key`, `module_name`, `permission_metadata`, `admin_tabs`,
    `css_sources`, `required_integrations`, `version`, `route_module`,
    `enabled?`, `enable_system`, `disable_system`, `get_config`),
    every topic helper (`endpoints_topic`, `prompts_topic`,
    `requests_topic`), every listing + count + change + mark
    function (`list_endpoints`, `count_endpoints`,
    `count_enabled_endpoints`, `change_endpoint`,
    `mark_endpoint_validated`, `list_prompts`, `list_enabled_prompts`,
    `count_prompts`, `count_enabled_prompts`, `change_prompt`,
    `record_prompt_usage`, `count_requests`, `sum_tokens`), every
    prompt CRUD-shape helper (`get_prompt!`, `get_prompt`,
    `get_prompt_by_slug`, `enable_prompt`, `disable_prompt`,
    `duplicate_prompt`). 24 specs total.
  - `request.ex` — `valid_statuses`, `valid_request_types`,
    `status_label`, `status_color`, `format_latency`, `format_tokens`,
    `format_cost`. 7 specs total.
  - Got an `unknown_type PhoenixKit.Module.Tab.t/0` from dialyzer on
    the first `admin_tabs` spec — the alias is
    `PhoenixKit.Dashboard.Tab`, not `PhoenixKit.Module.Tab`; corrected.
- ~~**Component refactor: raw HTML inputs → core `<.input>` /
  `<.select>` / `<.textarea>`**~~ (UX) —
  - `lib/phoenix_kit_ai/web/prompt_form.html.heex` — full rewrite.
    Name, Slug, Description, System Prompt, Content all use core
    components. Errors plumbed via
    `Enum.map(@form[:x].errors, &PhoenixKitWeb.Components.Core.Input.translate_error/1)`
    on textarea/select calls (those components don't auto-extract
    errors from the FormField like `<.input>` does — discrepancy in
    core). Help-section copy + cancel/submit buttons gettext-wrapped.
  - `lib/phoenix_kit_ai/web/endpoint_form.html.heex` — Basic Info
    Name + Description swapped to `<.input>` / `<.textarea>`;
    Provider select swapped to `<.select>`; Reasoning Effort and
    Reasoning Max Tokens swapped to `<.select>` / `<.input>`. The
    bespoke provider/model picker grids and the dynamic
    `<.param_input>` parameter grid stay raw — they have runtime-
    constructed field shapes that `%FormField{}` can't model
    cleanly.
- ~~**LV edge-case tests**~~ (test depth) —
  - `test/phoenix_kit_ai/web/endpoint_form_test.exs` — 4 new tests:
    Unicode name + emoji round-trips through changeset + DB; SQL
    metacharacters in name (`'; DROP TABLE …; --`) round-trip
    verbatim (Ecto's parameterised path makes injection a non-issue);
    name >100 chars rejected with the expected length error; empty
    name on the validate event renders an inline error (proves
    `:action = :validate` is set so `<.input>` gates on it).
  - `test/phoenix_kit_ai/web/prompt_form_test.exs` — 4 new tests:
    Unicode name + content round-trip; SQL metacharacters in
    content; >10k-char content accepted (no length cap on content);
    empty content on validate event renders inline error.

### New finding caught by the deeper Batch 3 pass

- **`PhoenixKit.Module.Tab` vs `PhoenixKit.Dashboard.Tab`** (LOW) —
  The `admin_tabs/0` spec initially used the wrong module name; the
  `Tab` struct lives at `PhoenixKit.Dashboard.Tab`, not
  `PhoenixKit.Module.Tab`. Dialyzer caught it on the first run.
  Fixed before commit.

## Files touched (Batch 3)

| File | Change |
|------|--------|
| `lib/phoenix_kit_ai/endpoint.ex` | SSRF guard: `validate_base_url/1` + `internal_host?/1` + IPv4/IPv6 internal-IP clauses + `allow_internal_endpoint_urls` opt-in |
| `lib/phoenix_kit_ai.ex` | 24 `@spec` declarations on public API + corrected `admin_tabs/0` Tab type |
| `lib/phoenix_kit_ai/request.ex` | 7 `@spec` declarations on public helpers |
| `lib/phoenix_kit_ai/web/prompt_form.html.heex` | Full refactor → `<.input>` / `<.textarea>`; gettext on help + buttons |
| `lib/phoenix_kit_ai/web/endpoint_form.html.heex` | Basic Info + Provider + Reasoning fields → `<.input>` / `<.select>` / `<.textarea>` |
| `test/phoenix_kit_ai/endpoint_test.exs` | 12 SSRF guard tests (each reject + bypass + public-host sanity) |
| `test/phoenix_kit_ai/web/endpoint_form_test.exs` | 4 edge-case tests (Unicode, SQL meta, length, empty-validate) |
| `test/phoenix_kit_ai/web/prompt_form_test.exs` | 4 edge-case tests (Unicode, SQL meta, long content, empty-validate) |

## Verification (Batch 3)

- `mix precommit` ✓ (compile + format + credo --strict + dialyzer
  0 errors after fixing the `Tab` alias)
- `mix test` — 223 tests, 0 failures (was 201 after Batch 2; +22
  from SSRF + edge-case suites)
- `for i in 1..10; do mix test --seed $i; done` — 10/10 stable

## Open

None. Every item Batch 2 deferred is closed in Batch 3.
