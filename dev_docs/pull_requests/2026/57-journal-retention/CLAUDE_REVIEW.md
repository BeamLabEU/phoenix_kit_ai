# Claude Review — PR #57

**Reviewer:** Claude Opus 5.5
**PR:** Add journal retention settings and cleanup (timujinne)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `74ad481`

## Notes for the reviewer

A delegated read went through this PR with deletion first in mind. Its SQL conclusions come
from reading the queries, not running them against a large table.

## Overall Assessment

**APPROVE.** Risk: **Low**. Nothing was found that deletes or clears more than it was asked
to. The default deletes nothing, anything in doubt reads as forever, one floor sits under
every boundary, and the foreign-key check refuses rather than spreads. The one finding worth
fixing is about a decision changing while a job waits.

## Findings

### IMPROVEMENT - MEDIUM — a queued manual job ignored a period changed after it (fixed)

`run_now/2` freezes absolute boundaries into the job's arguments, and the manual `perform/1`
never looked at the settings again. A run that failed a chunk and waited to retry, or sat
behind a busy queue, would go on to delete by a period the owner had since lengthened or set
to forever, with "Retention periods saved" on screen and no way to stop it. Irreversible, and
against the newer decision. **Reproduced.**

**Fix:** a kind whose `changed_at` is after the job's `inserted_at` is left out; with nothing
left the job cancels, stamped `periods_changed` (`journal_prune_worker.ex:104`). Kinds nobody
touched still run, and a period changed before queueing is what the job was asked under.

### IMPROVEMENT - MEDIUM — a run killed mid-way leaves no audit trail (not changed)

The stamp, the permanent `journal.pruned` entry and `rows_deleted_before` are written once, at
the end, while each chunk commits alone. A deploy during the 03:17 run can remove rows with no
trace, and a one-off manual run leaves "all time" totals standing. Nothing wrong is deleted,
and content tracking is unaffected. Left alone because the fix is new behaviour to design (a
`journal.prune_started` entry or an `in_progress` stamp), not a repair. Recorded in `AGENTS.md`.

### NITPICK — `pending_job/0` passed Oban's prefix through raw (fixed)

With `prefix: false` the query named a `"false"` schema, the rescue answered nil, and the
pending line never showed. Now `ObanQuery.scoped/1`; see
[PR #12's review](../12-schema-prefix/CLAUDE_REVIEW.md).

### NITPICK — two pieces of personal data were missing from the "what clearing leaves" list (fixed)

`metadata.unresolved_refs` and `metadata.provider_error.message` survive the content step.
`AGENTS.md` now lists both. New rows carry the provider's words in a content key instead; see
[PR #53's review](../53-provider-error-bodies/CLAUDE_REVIEW.md).

### Checked, no finding

Boundaries across DST, month ends and a zone change; keyset order on equal `inserted_at`; the
`MATERIALIZED` CTEs; `content_done_before` and `content_resume` (a claim of "cleared" is never
false, the worst case is a re-walk); `check_foreign_keys/1`; Oban uniqueness, JSON args and the
time budget; per-event rights, previews and confirmation; the settings' read-modify-write;
`content_keys/0` against every row writer, the transcription rows included.

## Positive Observations

- Chunks are their own transactions with database timeouts that fire before the client's.
- A probe decides what is left, never a short chunk.
- The differential content-keys test is what caught the capture gap of PR #53 here.

## Summary

| | |
|---|---|
| Code quality | Excellent |
| Architecture | Very good |
| Security | Very good; rights checked per event |
| Performance | Very good; bounded chunks and time slices |
| Test coverage | Very good |
| Migration safety | Very good; deletes nothing by default |
| Consistency | Very good |

**Verdict:** APPROVE.
