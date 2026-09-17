# Claude Review — PR #28

- **Reviewer:** Claude Opus 5
- **PR:** Keep the usage row when a request's reference names no row (mdon/main)
- **Date:** 2026-09-17
- **Merge commit:** `c7d84e4`

## Overall Assessment

**Verdict:** APPROVE with reservations. Both bugs below are fixed on main.
**Risk level:** Low to Medium.

This is the right fix for a real hole. A foreign-key miss on the usage row
used to throw away the record of a call that had already been made and paid
for, and that row then counted toward no spend cap. The approach is sound:

- It retries only on a conclusive `constraint: :foreign` error.
- It keeps the submitted id in `metadata["unresolved_refs"]`.
- Every other changeset error still fails.

The retry rested on two assumptions that do not hold, though: that one
failed insert reports every broken reference, and that a failed insert can
be retried on the same connection.

## Critical Issues

None.

## High Severity

### BUG - HIGH: the retry raises inside a caller's transaction

`lib/phoenix_kit_ai.ex` `create_request/1` → `insert_without_refs/2`

When a verb runs inside a host's `Repo.transaction`, the first insert's FK
violation aborts the whole Postgres transaction. The retry then raises:

```
** (Postgrex.Error) ERROR 25P02 (in_failed_sql_transaction) current transaction is aborted
```

That raise comes out of `PhoenixKitAI.ask/3` (and every other verb) *after*
the provider call has succeeded. It was reproduced with a sandboxed test
that calls `create_request/1` inside `Repo.transaction/1`. Before the PR,
the same case returned `{:error, changeset}` and silently left the host's
transaction poisoned. After the PR, the verb crashes. Neither is acceptable
for a logging side effect.

**Fixed.** `insert_row/1` passes `mode: :savepoint` whenever
`repo().in_transaction?()` is true. A refused insert then rolls back only to
its savepoint, so the retry goes through and the caller's transaction
survives. Outside a transaction, no options are passed and nothing changes.
Test: "inside a caller's transaction the retry succeeds and the transaction
survives". It fails without the fix.

## Medium

### BUG - MEDIUM: only the first dangling reference is dropped

Postgres checks foreign keys with RI triggers and stops at the first
violation. The changeset therefore carries **one** FK error per attempt.
Take a row with a ghost `user_uuid` and an `endpoint_uuid` for an endpoint
deleted mid-call:

1. The first insert reports `endpoint_uuid`.
2. `insert_without_refs/2` drops it and inserts once more.
3. That insert fails on `user_uuid`, and the result is returned as a plain
   error.

So the row is lost: exactly the case the PR set out to close. This was
reproduced.

**Fixed.** `insert_request/2` loops and adds each newly refused reference to
`dropped`. It stops when an insert succeeds or when the error names no
reference it has not already dropped, so there are at most three retries.
`without_refs/2` rebuilds the attrs from the originals each time, which
keeps every submitted id in `unresolved_refs`. Test: "two unresolvable
references are both dropped, not just the first one reported".

### IMPROVEMENT - MEDIUM: the "written without" warning logged before the write

`insert_without_refs/2` logged "usage row written without …" *before* it
attempted the insert. A retry that then failed produced two contradictory
lines, "written without" followed by "not written".

**Fixed.** The warning is logged once, only on `{:ok, _}` when references
were dropped, and it lists all of them. The new two-reference test asserts
that it appears exactly once.

## Low

### NITPICK: the V193 index comment and the core pin

`lib/phoenix_kit_ai/budget.ex:173`: the literal `"success"` matters only
with a core that ships V193 (2.28.x resolves it here). The pin is still
`~> 2.0`, so a host on an older core simply has no index. That is correct
behaviour and only a speed difference, so the pin was left unchanged.

### NITPICK: per-user caps cannot see unresolved users

A caller that passes external visitor ids is never capped per user. The PR
documents this honestly in AGENTS.md, and the real fix (an external-subject
column in core) is already on the TODO list. No change.

## Positive Observations

- Retrying only on `constraint: :foreign` is the right boundary. The
  database's "no such row" is conclusive, and every other error still fails.
- `attr/2` handles both atom-keyed attrs (internal loggers) and string-keyed
  attrs (pass-through params), and a test covers both.
- The FK tests were split correctly into two layers: the changeset guard
  (never a raised `Ecto.ConstraintError`) and the usage-log policy above it.
- `budget_cache_test` now asserts that the unattributed row still moves the
  endpoint cap. That is the behaviour that matters, not just the log line.
- The literal-vs-parameter comment in `Budget.spent/3` records a non-obvious
  planner constraint that would otherwise be "cleaned up".

## Summary

| Area | Rating |
|---|---|
| Code quality | Good |
| Architecture | Good: the policy lives in one place, `create_request/1` |
| Security | No concerns: only uuids are logged, never content |
| Performance | Good: the retry runs only on FK misses (rare) |
| Test coverage | Good; the two gaps above now have tests |
| Migration safety | N/A: no DDL |
| Consistency | Good |

**Strengths:** it closes a real audit and billing gap, the retry boundary
is conservative, and the documentation is updated alongside the code.

**Areas addressed:** the retry inside a transaction, several dangling
references, and the order of the warning.

**Verdict:** APPROVE. The follow-up fixes ship in 0.23.1.
