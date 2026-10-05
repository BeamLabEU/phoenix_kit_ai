# FOLLOW_UP — PR #34 (Fix a translation being queued twice by simultaneous requests)

Triaged 2026-10-05.

`CLAUDE_REVIEW.md` found no bugs, two nitpicks and two limitations.

Ships in 0.25.1.

## Resolved

- **NITPICK:** the comments in `translations.ex` and the race test named a sweep
  tick as the in-transaction caller. Reworded to a host's own transaction and
  the Ecto sandbox.

## Not changed

- **NITPICK:** only the race test covers the locked path. It is the one place
  the lock can be exercised, and the moduledoc says why.
- **LIMITATION:** same-identity waiters each hold a pool connection while they
  wait on the lock. Bursts are small and the holder's work is short.
- **LIMITATION:** callers already inside a transaction take no lock. By design;
  the same as before the PR.
