# PR #54 — Dollar money and delivery controls

**Reviewer:** GPT / Codex · **Date:** 2026-10-24

**BUG - HIGH (fixed):** the module already reads `Request.cost` and drops the legacy account association, but still admitted core 2.63 through `~> 2.63`. Core V223 first ships in 2.64.0. Raised the dependency floor to `~> 2.64` and extended the conformance test to reject 2.63 versions.

**BUG - MEDIUM (test integration, fixed):** the LiveView harness injected real scopes without session tokens. Core's new session-backed access checks therefore refused authorized guard and pricing fixtures. Real-user scopes now confirm the fixture and log it in; the test hook resolves the token instead of serializing a full user/scope into the cookie. Fake display-only scopes remain supported. Added an explicit revoked-session regression on the task guard.

**BUG - MEDIUM (test integration, fixed):** the Anthropic header test attempted to override a new built-in provider with a module contribution, which core deliberately ranks after its built-ins. The synchronous test now replaces the cached provider fixture and clears the cache afterwards.

Inspected the V4 dollar conversions and precondition, schema compatibility, request log fallback/drain, credential/endpoint cache invalidation and limiter acquire/cancel/release paths. Retained documented limitations: async usage can lag spend checks, caches and concurrency limits are per node, and personal credentials follow the configured cache TTL. No live provider calls were made.

## Validation

- `PHOENIX_KIT_PATH=../phoenix_kit PGPOOL=8 mix test --max-cases 6`: 1,977 tests, 0 failures, with PostgreSQL and local core 2.64.0.
- `PHOENIX_KIT_PATH=../phoenix_kit mix precommit`: passed (warnings-as-errors compilation, unused-lock and Hex audit checks, strict Credo, format check and Dialyzer).
- `PHOENIX_KIT_PATH=../phoenix_kit MIX_ENV=prod mix compile --warnings-as-errors`: passed after rebuilding the local core dependency for production.
- `mix format` and `git diff --check`: passed.

The companion remains prepared locally pending authorization to include its publication. Normal Hex dependency resolution must be refreshed after core 2.64.0 is available.
