# PR #49 — Task declarations can disable per-user limits

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `300555a`

Rechecked the task declaration normalisation, effective limit layers, call-time statuses, settings updates, personal-limit writes and forgiveness, and the Tasks page's hidden user columns. Only literal `false` disables the user scope. Existing user values survive unrelated task-limit saves, and the task-wide limits still apply. Explicit removal of a stored personal exception remains a manager operation. No additional defect found.

Relevant tests: `task_user_limits_off_test.exs` and `web/tasks_user_limits_off_test.exs`.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
