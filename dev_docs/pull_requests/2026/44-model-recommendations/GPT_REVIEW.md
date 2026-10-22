# GPT review — PR #44

Reviewed 2026-10-22 by Codex. PR: Model recommendations and endpoint picker (timujinne).
Merge: `98c0bdd`. Rechecked the merged implementation and Claude's review
against current main (`c1056d2` before these repairs).

### BUG - MEDIUM — creating a recommended endpoint loses its gateway URL (fixed)

A recommendation belongs to a specific base URL, but its create link carried
only model, name and integration. Creating it from a gateway catalogue sent
model discovery and the resulting endpoint toward the provider's default URL.
Sources/rows now retain the source endpoint uuid; the link passes that uuid,
and the form resolves the saved URL on the server. The URL is shown in a form
field and retained through ordinary form submission. Model discovery uses the
saved source while the provider still matches. No raw URL from the query
string is trusted for an automatic credentialed fetch. Links also retain the
provider when no integration is known.

Tests cover source identity through ranking and links, the form's URL, ignoring
an arbitrary query-string URL, and an actual stubbed model fetch to the gateway.

### BUG - MEDIUM — `limit: 0` returns models (fixed)

Reserving a place for an unpriced row made `take_priced` negative at zero,
and `Enum.take/2` interprets negative amounts as taking from the end. Return
an empty list for nonpositive integer limits. The test supplies both priced
and unpriced models.

### IMPROVEMENT - MEDIUM — the history heading promises successful models (fixed)

The history query intentionally includes failed provider calls so operators
can see their error share. Rename “Already worked in this task” to “Models
used in this task”, preserving those useful rows. English, Estonian and Russian
catalogues and translation assertions are updated.

### Checks / remaining tradeoffs

Rechecked fitness filtering, lifecycle/output restrictions, price units,
median estimates, free/unpriced ranking, journal refusal/cache exclusions,
permission-gated links and escaped prefills. Snapshot rows remain unpriced
until the first catalogue refresh. Consumers should still pass precomputed
recommendations to frequently rerendered forms, as documented.

## Validation

See [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md)
for the final full-suite and precommit results.

## Second recheck after PRs #46 and #48

Rechecked at `0f3f879` on 2026-10-22: the extracted recommendation panel retains
gateway/provider prefill, task call estimates, refusal/cache-hit exclusions and
caller-selected capability filters. Price ranking and native unpriced models
were checked against PR #46's grouping changes. No additional defect found here.
