# FOLLOW_UP — PR #27 (Translation-engine fixes for shop translation control)

Triaged 2026-09-15.

`CLAUDE_REVIEW.md` found:
- two High bugs
- two Medium bugs
- two Medium improvements
- four nitpicks

All the bugs and improvements are fixed on main and ship in 0.23.0.

## Resolved

- **BUG - HIGH** (1): the §9.5 and §9.6 retries replayed the cached answer.
  - `Completion.parse_success_response/2` classifies `{"error": {"code":
    N}}` through `handle_error_status/2`. The result is an error: never
    cached, and logged as a failure row.
  - `Translation.translate_fields/6` passes `:cache` through.
  - `TranslateWorker.retry_cache_mode/1` sends `cache: :refresh` from
    attempt 2 when the host's cache is on.
  - Covered by:
    - "an error body is never cached, so the retry reaches the provider"
    - "a cached missing-fields answer replays until the caller refreshes it"
    - `retry_cache_mode/1` (worker test)
    - the §9.6 end-to-end test, which now asserts `status == "error"`
- **BUG - HIGH** (2): `mix test` aborted when the role cannot connect to
  `postgres`. This was reproduced in the review container.
  - `run_tests/1` rescues `Mix.Error` from `ecto.create`. The
    `test_helper.exs` preflight still aborts on an unusable database.
- **BUG - MEDIUM** (3): in-body 429/401/402 errors skipped the error
  vocabulary.
  - Fixed by (1)'s change.
  - Covered by "a 429 in a 200 body is :rate_limited, which the worker
    snoozes".
- **BUG - MEDIUM** (4): the placeholder guard scanned caller content,
  outside the PII gate.
  - New `Prompt.unbound_placeholders/2` scans the template only. Both call
    sites use it.
  - Covered by `unbound_placeholders/2` (prompt test) and "a {{...}} inside
    a bound value is caller content, not an unbound slot".
- **IMPROVEMENT - MEDIUM** (5): the cache hit row dropped
  `unbound_placeholders`, and the key was part of the cache key.
  - `cached_row/4` now copies it, and `cacheable/1` drops it.
  - Covered by "a cache hit's row carries the same unbound_placeholders as
    the fresh row".
- **IMPROVEMENT - MEDIUM** (6): AGENTS.md documented the removed auto-skip.
  Commands and Testing are updated.

## Open

- **NITPICK** (7): comments cite an external design doc's section numbers.
  Left as-is, since rewriting them is churn.
- **NITPICK** (8): stale `phoenix_kit ~> 1.7` and memory-file references in
  the `test_helper.exs` comments. They predate the PR.
- **NITPICK** (9): the `enabled?/0` integration test duplicates
  `CoverageTest`. Harmless.
- **NITPICK** (10): a `missing_fields` retry is a paid call, up to 3×
  before failing. This is the intended trade-off.

## Verification

| Check | Result |
|---|---|
| `mix test` at the merge (baseline) | Aborted before any test: `ecto.create` denied CONNECT on `postgres` (finding 2) |
| New/changed tests with the `lib/` changes stashed | 11 of 12 fail (the remaining one — "error body is never cached" — passes pre-fix only because `cache:` never reached the call, which the §9.5 test covers) |
| `mix test` after the fixes | 1088 tests, 0 failures |
| `mix precommit` | clean |
| `mix hex.audit` | no retired or advisory packages |
