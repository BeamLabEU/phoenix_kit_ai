# GPT review — PR #41

Reviewed 2026-10-22 by Codex. PR: Model capability cache (timujinne).
Merge: `65eb1b8`. Rechecked the merged implementation and Claude's review
against current main (`c1056d2` before these repairs).

### BUG - MEDIUM — legacy provider names lose catalogue discovery at a proxy (fixed)

`catalogue_kind/2` compared a provider literally with `openrouter` or
`anthropic`. A supported legacy value such as `openrouter:work` at a custom
base URL therefore had no catalogue, even though credential resolution and
completion routing support that value. Normalize through
`Endpoint.base_provider/1` before choosing the catalogue. The regression test
covers both providers behind a proxy.

### Checks

Rechecked snapshot loading/upserts, replacement after a successful catalogue
read, failed/empty catalogue retention, paging, supervised refreshes, retries,
endpoint declarations and catalogue precedence. The subsequent guards and
recommendations were checked against these cache semantics.

### Remaining tradeoffs

The unconditional background refresh while AI is disabled is unchanged: this
keeps re-enabling warm and does not make completion calls. Misses at a proxy
still need an endpoint change, an explicit refresh or the periodic refresh;
`lookup/2` has no provider argument. No extra process/cache protocol was added
for this latency issue.

## Validation

See [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md)
for the final full-suite and precommit results.

## Second recheck after PRs #46 and #48

Rechecked at `0f3f879` on 2026-10-22: cache refresh/retry/snapshot behavior and
declaration precedence remain consistent with the added capability flags and
catalogues. Removed the compiler warning from matching a floating-point zero in
the pricing test; the assertion still checks the returned price. Native model
filtering repairs are documented under PR #46.
