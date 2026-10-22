# Recheck of all 2026-10-22 PR merges

Reviewed by Codex. GitHub's merge timestamps (UTC) identify exactly four PRs:
#41 at 18:47:20, #43 at 18:47:43, #44 at 18:47:57 and #45 at 18:48:11.
The starting tree was clean at `c1056d2`, including Claude's post-merge fixes.
Each PR was reviewed with its surrounding implementation and cross-PR callers.

| PR | Scope | Independent findings and repairs |
|---|---|---|
| [#41](../pull_requests/2026/41-model-capabilities-cache/GPT_REVIEW.md) | Capability cache | Legacy provider names behind gateways |
| [#43](../pull_requests/2026/43-ai-tasks-model-guard/GPT_REVIEW.md) | Task registry and call guard | Payload leakage in failure logs; incorrect cache-hit model identity; production-route test parity |
| [#44](../pull_requests/2026/44-model-recommendations/GPT_REVIEW.md) | Recommendations and picker | Lost gateway URL/provider; zero-limit ranking; misleading success wording |
| [#45](../pull_requests/2026/45-task-limits-guard-signals/GPT_REVIEW.md) | Limits, signals and permissions | Alert re-arming; first-save races; malformed forms; core floor; visitor-id reads; inheritance wording |

## Validation

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
