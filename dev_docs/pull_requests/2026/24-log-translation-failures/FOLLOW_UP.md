# FOLLOW_UP — PR #24 (Log `ai.translation_failed` activity entries)

Triaged 2026-09-10.

`CLAUDE_REVIEW.md` found one Medium bug: `classify_reason/1`'s
`{:persist_error, {:bad_put_translation, _}}` clause was shadowed by the
generic `{:persist_error, _reason}` catch-all above it, so every persist
failure logged `reason_detail: nil` instead of distinguishing "adapter
returned a malformed shape" from any other persist error.

## Resolved

- **BUG - MEDIUM** — fixed on main: reordered the `classify_reason/1` clauses
  (specific nested-shape clauses before the generic catch-all), added the
  missing `{:persist_error, {:exception, _}}` clause, removed the dead bare
  `{:bad_put_translation, _other}` clause, corrected the unit test that had
  been exercising the wrong (never-produced) shape, and added a DB-backed
  integration test (`FakeTranslatablePersistFailure` +
  `translate_worker_failure_logging_test.exs`) driving the real `persist/2` →
  `fail/3` path end-to-end so this can't regress silently again.

## Open

None.

## Verification

| Check | Result |
|---|---|
| `mix test test/phoenix_kit_ai/translate_worker*.exs` | 26 tests, 0 failures |
| `mix precommit` | clean |

No further follow-up needed.
