# PR #52 — Remove UUIDv7 timing assumptions from endpoint-name tests

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `427e7a5`

Reviewed the complete test-only diff against the production query from #51. The age test now assigns distinct timestamps, and the tie test sorts the generated UUIDs before touching the lower one last. Neither test assumes two UUIDv7 values generated in one millisecond reflect call order. No additional defect found.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
