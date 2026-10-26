# PR #58 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewers:** grok (both rounds); findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

The sweep's rules: a sub-key `<base>.<sub>` is checked with `Scope.can?/2` in `mount/3` and every write
event against the live scope; new sub-keys are backfilled once to current base-key holders, with the
flag set only after every grant succeeded. Round 1 reviewed the whole change, round 2 only the fixes.

## Findings

- BUG-MEDIUM — after `ai.view_usage` was revoked the Usage tab kept refreshing and rendering → fixed in the reload path; round 2 found core decides `:stay` for this page and an open request stayed visible → fixed: `phoenix_kit_scope_changed/1`, tested through core's real refresh.
- BUG-MEDIUM — backfill trusted a swallowing lookup → fixed.
- NITPICK — the endpoint list masked keys as 8+4 → last 4 only; a tab-metadata test was tautological → behavioural.
