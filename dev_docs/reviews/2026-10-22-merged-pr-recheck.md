# Recheck of all 2026-10-22 PR merges

Reviewed by Codex. GitHub's merge timestamps (UTC) identify six PRs today:
#41 at 18:47:20, #43 at 18:47:43, #44 at 18:47:57, #45 at 18:48:11,
and #46 and #48 at 21:09:18. The first pass started at `c1056d2` and covered
the first four. The second pass started from a clean, up-to-date main at
`0f3f879`, rechecked those four, and reviewed #46 and #48 with their callers.

| PR | Scope | Independent findings and repairs |
|---|---|---|
| [#41](../pull_requests/2026/41-model-capabilities-cache/GPT_REVIEW.md) | Capability cache | Legacy provider names behind gateways |
| [#43](../pull_requests/2026/43-ai-tasks-model-guard/GPT_REVIEW.md) | Task registry and call guard | Payload leakage in failure logs; incorrect cache-hit model identity; production-route test parity |
| [#44](../pull_requests/2026/44-model-recommendations/GPT_REVIEW.md) | Recommendations and picker | Lost gateway URL/provider; zero-limit ranking; misleading success wording |
| [#45](../pull_requests/2026/45-task-limits-guard-signals/GPT_REVIEW.md) | Limits, signals and permissions | Alert re-arming; first-save races; malformed forms; core floor; visitor-id reads; inheritance wording |
| [#46](../pull_requests/2026/46-native-model-capabilities/GPT_REVIEW.md) | Native catalogues and capability groups | Native model filters ignored capabilities; embeddings in chat list; missing native vision/image models |
| [#48](../pull_requests/2026/48-off-purpose-blocks/GPT_REVIEW.md) | Flags, anomaly signals and group blocks | Uppercase UUID block bypass; stale live administration; database exits escaping guard fallbacks (also #45) |

## Second-pass findings

- **BUG - HIGH:** blocked users could pass an uppercase UUID to bypass the
  cache lookup, including turn admission. Cast identities before cache access.
- **BUG - MEDIUM:** filter model lists using native catalogue capabilities and
  output modalities. Preserve text-only chat output, TTS exclusions and the
  fallback for providers without capability metadata.
- **BUG - MEDIUM:** subscribe the Tasks LiveView to existing guard change
  messages so another administrator's blocks, lifts and settings update it.
  Recheck management rights when refreshing private views.
- **BUG - MEDIUM:** catch database exits at the settings, block, task-limit and
  anomaly boundaries, preserving their documented defaults and fail-open result.
  Log the failure class without the exit payload.

Removed two compiler warnings in existing tests: an unused helper default and a
floating-point zero pattern. These do not alter runtime behavior.

## Second-pass validation

- Baseline `mix test`: **1,670 tests, 0 failures**, with PostgreSQL.
- Before repairs, the four initial regression tests failed: two native model
  filters, live block updates, and UUID lookup. The separate repository-exit
  regression also failed before repairing the guard boundaries.
- Final `mix test`: **1,678 tests, 0 failures**, with PostgreSQL and no compiler
  warnings. Includes eight new regression tests and an expanded output-modality
  fixture.
- Final `mix precommit`: **passed** — warnings-as-errors compilation, unused
  dependency check, Hex retirement/security audit, formatting check, strict Credo
  and Dialyzer. Credo found no issues. The three existing Dialyzer suppressions
  remain unchanged; no suppression was added.
- `git diff --check`: passed.
- No provider traffic was needed: HTTP behavior uses Req.Test stubs. No local
  core override or database skip was used. No new gettext strings were added.

## First-pass validation

- `mix test`: **1,554 tests, 0 failures** (including PostgreSQL integration tests).
- Final focused endpoint-form verification after extracting the prefill lookup:
  **94 tests, 0 failures**, including saving the gateway URL and fetching its models.
- `mix precommit`: **passed** — warnings-as-errors compilation, formatting,
  dependency retirement/security audit, strict Credo and Dialyzer. Credo found
  no issues. Dialyzer uses the existing Gettext opaque-type suppression;
  no suppression was added or broadened.
- `mix gettext.extract && mix gettext.merge priv/gettext`: all 575 messages
  merged without fuzzy entries from this change; new/changed strings are
  translated in English, Estonian and Russian.
- `git diff --check`: passed.

Initial baseline: 1,543 tests, 19 failures caused by locale-only test routing
against a core that emits prefixless primary paths. The test router now expands
both production route callbacks. Database-backed tests use the locked Hex core
2.63.0 and the configured PostgreSQL instance; no `PK_AI_SKIP_DB` or local core
override is used.

## Boundaries

No release/version/changelog change or migration rewrite. Existing fail-open
counts and in-flight overshoot remain documented behavior. Journal rollups,
atomic reservations, a new explicit unlimited JSON sentinel and refusal-row
aggregation are separate design changes, recorded in the individual reviews.
