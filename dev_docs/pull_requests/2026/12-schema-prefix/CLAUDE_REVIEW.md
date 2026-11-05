# Claude Review — PR #12

**Reviewer:** Claude Opus 5.5
**PR:** Add PhoenixKit.SchemaPrefix for runtime named-schema (`--prefix`) support (mdon)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `e1eb027`

## Overall Assessment

**APPROVE with reservations.** Risk: **Medium** on prefixed installs, none on public
ones. What the PR changed is right, and its conformance test has kept every later
schema in line. But `@schema_prefix` only reaches queries built on a schema, and the
module also reads Oban's table, which no schema of ours covers. Those reads were
missed here and by the code added since.

## Findings

### BUG - MEDIUM — Oban's table was read past the prefix, and the failure was silent (fixed)

Core's `--prefix` install keeps `oban_jobs` in the named schema and writes `prefix:`
into the host's Oban config. `Oban.Job` and the `"oban_jobs"` source carry no prefix,
so seven queries went to the search path:

| Read | Where | On a prefixed install |
|---|---|---|
| `job_in_flight?/1` | `translations.ex:583` | Dedupe off: a double click bills twice |
| `in_flight/1` | `translation_sweep.ex:455` | `max_in_flight` ceiling ignored |
| `recently_failed/1` (two queries) | `translation_sweep.ex:476` | A failing pair is retried every tick |
| `next_tick_at/1`, `running?/1` | `translation_sweep.ex:192,205` | No rescue: raises, or reads as nothing there |
| `reschedule/1` | `translation_sweep.ex:172` | The waiting tick is never moved |

The first case is the worst: PR #34's fix for double billing does nothing on such an
install. Where no `public.oban_jobs` exists it is worse still, going by the code (this
branch was not run, since the test database has that table): `job_in_flight?/1` runs
inside `enqueue_locked/2`'s transaction, so its failed query aborts the transaction
even though the rescue swallows the error, `Oban.insert/1` then cannot succeed in it,
and the retry without the lock runs the same failing check.

**Reproduced before fixing.** `test/phoenix_kit_ai/oban_prefix_test.exs` runs Oban in
a schema of its own with `public.oban_jobs` empty. Against the old code a second
enqueue returned `conflict?: false`, the ceiling and the backoff were ignored, and
`next_tick_at/1` returned `nil`, while the control test (the job did land in the named
schema) passed.

**Fix:** `PhoenixKitAI.ObanQuery.scoped/1`, used by all of the above and by
`Retention.pending_job/0`, which alone had it right but passed `prefix: false` through
unchanged. `prefix/0` reads `Oban.config(Oban).prefix`; `false` (legal in Oban) and no
running instance both mean `nil`, the old behaviour.

### IMPROVEMENT - MEDIUM — the conformance test could not see this (fixed)

`schema_prefix_conformance_test.exs` looked only for `schema "phoenix_kit`. It now
also fails on a string source for a kit table and on a query of Oban's table in a file
that does not use `ObanQuery.scoped`. The check is per file, so a second query in a
file that already uses it is not caught, which is the same grain as the existing rule.

## Positive Observations

- Three schemas, one line each, and the conformance test landed with them: the
  invariant has outlived the PR.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Right mechanism; its reach was the gap |
| Test coverage | Good for schemas; extended for what bypasses them |
| Migration safety | No migration |

**Verdict:** APPROVE with reservations; the reservation is resolved.
