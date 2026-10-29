# PR #54 — follow-up

## Fixed (pre-existing)

All three findings were fixed inside the PR itself, as the review records; re-verified against current code on 2026-10-28:

- ~~**BUG - HIGH:** the module admitted core 2.63 although it needs V223 (2.64).~~ The pin is now `>= 2.65.0 and < 4.0.0` (`mix.exs:149`, widened for core 3.0), and `test/core_pin_conformance_test.exs` rejects every 2.63.x and 2.64.x version (`@must_reject`).
- ~~**BUG - MEDIUM:** the LiveView harness injected real scopes without session tokens.~~ `test/support/hooks.ex` resolves a `"user_token"` through core's token loader; fake display-only scopes remain supported.
- ~~**BUG - MEDIUM:** the Anthropic header test tried to override a built-in provider through a module contribution.~~ `test/phoenix_kit_ai/anthropic_rules_test.exs` replaces the cached provider fixture and clears the cache afterwards.

## Skipped (with rationale)

The review's retained limitations (async usage lagging spend checks, per-node caches and concurrency limits, personal credentials following the cache TTL) are documented in `AGENTS.md` → Landmines; they are design limits, not open defects.

## Verification

See the PR #58 sweep follow-up and the current branch's `mix precommit` and suite results.

## Open

None.
