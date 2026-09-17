# FOLLOW_UP — PR #28 (Keep the usage row when a request's reference names no row)

Triaged 2026-09-17.

`CLAUDE_REVIEW.md` found:
- one High bug
- one Medium bug
- one Medium improvement
- two nitpicks

The bugs and the improvement are fixed on main and ship in 0.23.1.

## Resolved

- **BUG - HIGH:** the retry raised `in_failed_sql_transaction` inside a
  caller's transaction.
  - `insert_row/1` uses `mode: :savepoint` when `in_transaction?/0`.
  - Covered by "inside a caller's transaction the retry succeeds and the
    transaction survives".
- **BUG - MEDIUM:** only the first dangling reference was dropped.
  - `insert_request/2` retries until no new reference is refused.
  - Covered by "two unresolvable references are both dropped, not just the
    first one reported".
- **IMPROVEMENT - MEDIUM:** the warning was logged before the write.
  - It is now logged once, after a successful insert, with every dropped
    reference.

## Not changed

- **NITPICK:** the V193 index needs a newer core. The pin stays `~> 2.0`,
  because an older core only loses the index speed-up.
- **NITPICK:** per-user caps cannot see unresolved users. This is already
  documented, and the external-subject column is on the TODO list.
