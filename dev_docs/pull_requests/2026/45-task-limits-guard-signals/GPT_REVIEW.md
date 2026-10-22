# GPT review — PR #45

Reviewed 2026-10-22 by Codex. PR: Task limits, guard signals and ai.manage (timujinne).
Merge: `ac2a41c`. Rechecked the merged implementation and Claude's review
against current main (`c1056d2` before these repairs).

### BUG - MEDIUM — forgiving usage leaves subsequent alerts suppressed (fixed)

Counts restarted but the dedupe key remained taken for the whole calendar
window. Carry the forgiveness timestamp from the existing usage read into
limit statuses and include it in post-forgiveness event keys. Unforgiven keys
and the date/month suffix stay compatible; reached-user discovery still works.
Tests cross both warning and reached thresholds before/after forgiveness,
check a repeated refusal stays deduplicated, and verify watcher/user notices.
There is no additional database query per check.

### BUG - MEDIUM — concurrent first saves raise instead of returning errors (fixed)

Task and personal settings had database uniqueness without changeset constraint
mapping. Add both unique constraints. Deterministic interleaving tests insert
a competing row after each initial SELECT and assert `{:error, changeset}`
instead of `Ecto.ConstraintError`.

### BUG - MEDIUM — malformed limit submissions crash or clear limits (fixed)

A map/list amount crashed `to_string/1`; malformed nested containers were
silently skipped and could save an empty limits map. Validate container shapes
and scalar amounts before parsing/saving. LiveView tests exercise malformed
roots, scopes, units and values, verify the process survives, and verify the
previously saved cap remains intact.

### BUG - MEDIUM — declared core compatibility omits a required callback (fixed)

The package admitted core 2.38–2.62 although the new `@impl oban_crons/0`
requires 2.63 and earlier cores do not schedule pruning. Raise the two-segment
floor to `~> 2.63`, retaining support for later 2.x minors. Update the conformance
test and repository guidance. Validation uses the locked Hex core 2.63.0,
without a local override. This intentionally excludes older hosts.

### IMPROVEMENT - MEDIUM — usage/status APIs still reject visitor ids (fixed)

Claude fixed the call-time check's invalid-UUID fail-open path. Apply the same
normalization to public usage/status reads: an external id gets task totals
and no user scope instead of an Ecto cast error. Regression assertions extend
Claude's original visitor-id scenario.

### IMPROVEMENT - MEDIUM — blank-limit guidance contradicts inheritance (fixed)

The UI said a blank cell meant no limit, although it inherits a stored or
declared default. Correct the module/UI wording and all three locales. The
existing JSON semantics are preserved; an explicit unlimited override is not
introduced in this repair.

### Checks / remaining tradeoffs

Rechecked calendar windows/DST, success/cache/refusal counting, permission
checks including active-session revocation, cache generation/TTL/broadcasts,
V2 SQL/rollback/prefix behavior, event deduplication and pruning. Claude's
translation classification fix is retained. Concurrent usage may overshoot;
counting remains fail-open on database errors. Limited calls still aggregate
journal usage; rollups/reservations need a separate storage/concurrency design.
Forgiveness retains the journal's existing second-level time precision.

## Validation

See [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md)
for the final full-suite and precommit results.
