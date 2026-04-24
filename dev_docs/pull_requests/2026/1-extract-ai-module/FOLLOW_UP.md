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

## Open

None from the original review.
