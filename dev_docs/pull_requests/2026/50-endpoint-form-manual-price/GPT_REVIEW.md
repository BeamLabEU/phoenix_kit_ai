# PR #50 — Endpoint forms, manual prices and cost-source order

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `96ff131`

### BUG - MEDIUM — configured Anthropic prices were ignored above a built-in tier threshold (fixed)

`AnthropicPricing.rate/2` merged operator overrides into the base table, then preferred the built-in tier over that merged result. An override for `claude-haiku-5-5` therefore worked at 100,000 input tokens but silently reverted to the shipped rate at 100,001. This could undercount usage and loosen money limits even after an operator corrected a stale price.

Configured rates now take precedence over the complete built-in pricing rule, including tiers. The regression checks both sides of the threshold, a million-token prompt, the `-latest` alias and the Decimal rate used by `CallCost`. Before the fix it failed with 0.0525005 versus the configured 0.208002 dollars.

Also checked provider/catalogue/manual/table source selection, model-bound manual-price validation and the context's `ai.manage` checks. The provider's current published rates were not re-audited; this finding concerns the documented override mechanism.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
