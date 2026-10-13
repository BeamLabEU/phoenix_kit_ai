# FOLLOW_UP — PR #36 (Quality sweep: keys out of messages, bounded sweep and snooze)

Triaged 2026-10-13. Ships in 0.25.4.

## Fixed

- **IMPROVEMENT - MEDIUM:** `:request_failed` (from `validate_and_record/1`)
  had no `Errors.message/1` clause and rendered as
  `Unexpected error: :request_failed`. Added the clause, `et` / `ru`
  translations, and a test in `test/phoenix_kit_ai/errors_test.exs`.
- **NITPICK:** "Three choices" → "Four choices" in the `Endpoint` base-URL guard
  comment.

## Not changed

- `*.internal` names are now refused on save (alignment with the image-fetch
  policy); recorded in `AGENTS.md` and by the PR. Unchanged URLs are not
  re-judged.
- The realtime-start failure log carries a shape only; deliberate.

## Gate

`mix precommit` clean; `mix test` 1233 tests, 0 failures.
