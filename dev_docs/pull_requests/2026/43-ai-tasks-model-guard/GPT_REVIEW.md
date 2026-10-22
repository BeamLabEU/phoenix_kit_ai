# GPT review — PR #43

Reviewed 2026-10-22 by Codex. PR: AI tasks and call-time model guard (timujinne).
Merge: `d1a14c3`. Rechecked the merged implementation and Claude's review
against current main (`c1056d2` before these repairs).

### BUG - HIGH — callback failures can expose payloads in logs (fixed)

The new task registry and endpoint callback handlers logged exception messages
and inspected throw/exit reasons. A callback failure may carry credentials or
user content. Log only exception class or failure kind. Invalid declaration
entries are described by shape instead of inspected. Regression tests inject
a secret into raise, throw and exit payloads for both callback paths.

The new parameter-routing 404 handler also interpolated the provider's error
text. Providers may echo request content there; the handler now logs a static
classification, tested with an echoed secret.

### BUG - MEDIUM — cached chat rows can identify an unsent model (fixed)

Authorization correctly ignores `model:` for chat, embeddings and speech,
but the cache wrapper used it to identify cache-hit journal rows. A fresh row
and its cache-hit row could therefore name different models, and an overlong
ignored override could even prevent the hit row being written. The wrapper
now follows the same supported-override verb list as authorization. A test
asserts that both chat rows name the endpoint's actual model. The existing
failed-hit-write test now induces a genuine journal failure through oversized
prompt attribution instead of relying on this model bug.

### Checks and integration validation

Rechecked the endpoint → fitness → task limit → spend cap → cache order,
refusal attribution/sink exclusion, dry runs, admission binding and expiry,
model overrides, Anthropic request shaping and OpenRouter parameter routing.
The test router now expands the actual production callbacks for both locale
and prefixless routes; URL assertions use the route helper. This fixes the
19 baseline failures against the resolved core's language settings without
changing production routing.

### Remaining tradeoffs

Refused calls still write individual journal rows. Aggregating or dropping
those rows would change the usage/audit contract and is outside this repair.

## Validation

See [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md)
for the final full-suite and precommit results.

## Second recheck after PRs #46 and #48

Rechecked at `0f3f879` on 2026-10-22: task discovery, implied requirements,
model-override boundaries, refusal rows, request UUIDs and cache accounting were
cross-checked against native capability support and block admission. No additional
call-routing defect was found. Removed an unused default argument in the request
rules test helper so the suite compiles without that warning.
