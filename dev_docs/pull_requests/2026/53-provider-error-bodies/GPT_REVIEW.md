# PR #53 — Provider error classification and journal details

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `d50b6ae`

Traced body-based quota/balance classification through the shared HTTP doors, retry classification and every failed-row writer. Reviewed Retry-After consumption, credential-shaped token masking and truncation, answered-model comparison, and the request view's rendering. The provider note is cleared at the HTTP boundary and consumed once by the row writer. Content-policy errors and provider diagnostic text retain the documented row-lifetime policy. No additional confirmed defect found.

Relevant tests: `provider_error_test.exs`, `translate_worker_failure_logging_test.exs` and `web/usage_answered_model_test.exs`. This review checks the code's classification rules and fixtures; it does not independently certify every provider's live error taxonomy.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
