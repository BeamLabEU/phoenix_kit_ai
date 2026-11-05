# Claude Review — PR #55

**Reviewer:** Claude Opus 5.5
**PR:** Endpoint form follows the offered provider on a connection change; Playground shows a call's logged cost (timujinne)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `2abd4f4`

## Overall Assessment

**APPROVE.** Risk: **Low**. No defect in the PR's own code. `follow_offered_provider/2` and
`response_usage/2` hold up: fields clear with `""`, stale results are dropped, the auto-pick
rules match `AGENTS.md`, and the cost read is checked against the row's endpoint. The
findings below are in code next to the diff that predates it.

## Findings

### BUG - MEDIUM — a Playground result could land on the wrong endpoint (fixed; predates this PR)

`handle_async(:image_models | :edit | :describe)` carried no endpoint. Load models on A,
switch to B, and A's list filled B's select and hid B's Load button; picking one sent
`process_image(B, ..., model: <A's id>)`. **Reproduced.**

**Fix:** each task names its endpoint and a mismatched result is dropped
(`web/playground.ex:818`), the pattern `EndpointForm` uses. `cancel_async/2` was rejected:
killing an in-flight edit after the provider billed it would lose its usage row.

### IMPROVEMENT - MEDIUM — a picked connection that becomes usable loads no models (not changed; predates this PR)

Pick a connection with no key, then add the key in another tab: `reload_connections/1`
(`web/endpoint_form.ex:1453`) sets `integration_connected: true` but starts no fetch, and
Retry needs `@models_error`. Unpicking and re-picking works, so it is recorded, not fixed.

### NITPICK — the chip shows the first call's cost on an OpenRouter cache hit (not changed)

The row is read only when `usage.cost` is nil, so a hit shows the stored cost where its row
says $0. The code comment accepts this.

## Positive Observations

- The follow step reuses `maybe_handle_provider_change/2`, so it behaves as if the person
  had chosen the provider, and only on a new endpoint.
- Tests cover a first connection of another provider, the last one removed, an unchanged
  provider and an edited endpoint.

## Summary

| | |
|---|---|
| Code quality | Very good |
| Test coverage | Good |
| Consistency | Good |

**Verdict:** APPROVE.
