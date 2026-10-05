# Claude Review — PR #34

- **Reviewer:** Claude Sonnet 5.5
- **PR:** Fix a translation being queued twice by simultaneous requests (mdon/main)
- **Date:** 2026-10-05
- **Merge commit:** `e00e71f`

## Overall Assessment

**Verdict:** APPROVE. No bugs found; two nitpicks and two limitations recorded.
**Risk level:** Low.

`Translations.enqueue/1` used to run "is a job in flight?" and the insert as two
separate statements, so a double click or two open tabs queued one translation
twice (two billed model calls, the second overwriting the first). The PR wraps
both in one transaction holding `pg_advisory_xact_lock(hashtextextended(identity, 0))`
(`lib/phoenix_kit_ai/translations.ex:489-540`). The second caller waits for the
first to commit, then sees the job and answers `conflict?: true`.

Checked and sound:

- **Visibility after the wait.** Postgres runs `READ COMMITTED` by default, so
  `job_in_flight?/1` takes a fresh snapshot once the lock is granted and sees the
  first caller's committed job. No `SERIALIZABLE` needed.
- **Return shape.** `check_then_insert/1` returns `{:ok, outcome}`; the
  transaction fun returns `outcome`, so `repo.transaction/1` yields
  `{:ok, %{conflict?: _}}`. Errors go through `repo.rollback/1` to `{:error, reason}`.
  Both match the `@spec`.
- **Lock identity** is `(resource_type, resource_uuid, scope, target_lang)`, the
  same tuple `job_in_flight?/1` checks, with the scope normalised the same way,
  so the two cannot disagree. Other languages and resources hash to other keys.
- **Lock scope.** The lock is transaction-level and released on commit or
  rollback. It also works behind a transaction-mode pgbouncer, which a
  session-level lock would not.
- **Nested callers.** `repo.in_transaction?()` skips the lock and the inner
  transaction, so a caller's own transaction is neither extended nor poisoned.
- **Fail-open.** An error raised under the lock retries the check and insert once
  without it, with a `Logger.warning`.
- **Tests.** The race test runs outside the sandbox, on real committing
  connections, with `on_exit` cleanup that restores `:manual` mode. It asserts
  exactly one `conflict?: false` out of 16 callers, one row in `oban_jobs`, and
  that different languages neither wait nor conflict. The comment explaining why
  the sandbox cannot show this race is correct and worth keeping.

## Findings

### NITPICK — comment named the wrong in-transaction caller

`translations.ex:490` and the race test said "a sweep tick queues many jobs in
one transaction". `TranslationSweep` opens no transaction, and it runs inside an
Oban `perform`. The callers that actually reach the `in_transaction?` branch are
a host's own transaction and every `DataCase`/`LiveCase` test, because the
sandbox wraps the test in one. Reworded both comments.

*Addressed in this release.*

### NITPICK — sandboxed tests never exercise the lock

Because of the above, every sandboxed test that enqueues takes the unlocked
`check_then_insert/1` path. Only `translations_enqueue_race_test.exs` covers
`enqueue_locked/2`. That is the right split, but a future edit to the locked
branch is covered by one file. Left as is; the file's moduledoc says so.

### LIMITATION — waiters hold a pool connection

Each concurrent caller on the same identity holds a checked-out connection while
it waits on the lock. A burst larger than the pool size on one resource and
language could queue behind pool checkout, and a wait beyond the 15s default
timeout raises, which falls through to the unlocked retry (a duplicate becomes
possible again). Realistic bursts are a few clicks, and the lock holder only
does one `SELECT` and one insert, so this is acceptable. Not changed.

### LIMITATION — callers already in a transaction are not serialised

By design (see the comment at `translations.ex:490`). Two hosts racing, each
inside its own transaction, can still double-queue. Not a regression, since that
was the behaviour before the PR.

## Positive Observations

- The race is reproduced for real rather than asserted through a mock, and the
  fix comes with the explanation of why the sandbox hides it.
- The fail-open choice is stated and logged instead of silent.
- The follow-up commit (`d74712e`) caught the nested-transaction case before
  release.

## Summary

| Area | Rating |
|---|---|
| Code quality | Good |
| Architecture | Good — one lock, no new table, no new process |
| Security | n/a (identity is hashed server-side and bound as a parameter) |
| Performance | Good — per-identity key, no global serialisation |
| Test coverage | Good — real concurrency, nested and independent-key cases |
| Migration safety | n/a |
| Consistency | Good |

**Gate:** `mix test` 1176 tests, 0 failures; `mix precommit` clean.
