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

## Codex follow-up — ships in 0.25.5

An independent review of 0.25.4 found four remaining issues, detailed in
[GPT_REVIEW.md](GPT_REVIEW.md). Fixed the model-type switch's orphaned spinner,
discovery overwriting the current model's details, redirects in model/voice
discovery, and payload-bearing failure logs. Added regression tests covering
the races, redirects, and exceptions/exits/throws with a canary credential.

These changes are recorded under 0.25.5; they are not part of the
already-published 0.25.4 package.

Validation: `mix test` 1,241 tests, zero failures; `mix precommit` passed.
