# PR #51 — Deterministic endpoint lookup by name

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `e280fa1`

Rechecked the exact-name preference, trimmed and case-insensitive matching, oldest-first ordering and UUID tiebreaker against the current context query. The UUID makes ties deterministic; it does not promise creation order within a UUIDv7 millisecond. The later #52 test correction handles that distinction. Existing request pagination also carries a deterministic UUID secondary order. No additional defect found.

Relevant tests: `endpoint_name_and_source_prefix_test.exs` and `request_order_test.exs`.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
