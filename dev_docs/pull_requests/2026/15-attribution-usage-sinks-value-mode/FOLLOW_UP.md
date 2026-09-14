# Follow-up Items for PR #15

Triaged against `main` on 2026-09-14 (quality sweep, Phase 1).

## No findings

CLAUDE_REVIEW found no defects; it is a verification record. Re-checked the
current tree: the usage-sink loop keeps its double guard
(`lib/phoenix_kit_ai.ex`, `rescue` + `catch` around each sink), the
attribution helpers `normalize_attribution/1` / `maybe_put_attribution/2`
are intact, and the optional `source_fields/2` callback that enables value
mode on unsaved forms is declared in `form_binding.ex` and consumed in
`form_glue.ex`.

## Skipped (with rationale)

Two observations the review marked "noted, not blocking" are still true by
choice:

- "Nanodollar" names a 1e-6 dollar unit (strictly a microdollar). Renaming
  would ripple through `TtsPricing.cost_nanodollars/3` and every consumer;
  the arithmetic is right either way.
- Value-mode translation tasks are started unlinked and outlive a closed
  LiveView, billing for output nobody sees — the same behaviour as the
  Oban path, which does not cancel on disconnect either.

## Open

None.
