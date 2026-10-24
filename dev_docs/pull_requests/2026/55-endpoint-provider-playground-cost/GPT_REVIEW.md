# PR #55 — Provider changes and Playground costs

**Reviewer:** GPT / Codex · **Date:** 2026-10-24

Rechecked `follow_offered_provider/2` and `response_usage/2`. A new endpoint follows the offered provider while preserving typed params; existing endpoints retain their saved provider. A provider-free cost is read from a usage row only when it belongs to the expected endpoint. Async logging may leave no row at the instant of the read, in which case no cost is displayed, as the code documents. No additional defect found.

## Validation

- `PHOENIX_KIT_PATH=../phoenix_kit PGPOOL=8 mix test --max-cases 6`: 1,977 tests, 0 failures, with PostgreSQL and local core 2.64.0.
- `PHOENIX_KIT_PATH=../phoenix_kit mix precommit`: passed (warnings-as-errors compilation, unused-lock and Hex audit checks, strict Credo, format check and Dialyzer).
- `PHOENIX_KIT_PATH=../phoenix_kit MIX_ENV=prod mix compile --warnings-as-errors`: passed after rebuilding the local core dependency for production.
- `mix format` and `git diff --check`: passed.

The companion remains prepared locally pending authorization to include its publication. Normal Hex dependency resolution must be refreshed after core 2.64.0 is available.
