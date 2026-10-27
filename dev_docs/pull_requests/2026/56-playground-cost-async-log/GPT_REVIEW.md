# PR #56 — Display logged costs with asynchronous usage logging

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `cf25404`

### BUG - MEDIUM — a full queue skipped the wait for an already queued usage row (fixed)

`Playground.logged_row/1` used `RequestLog.async?/0` to decide whether to flush after a missing row. That predicate checks whether a **new** write can enter the queue. Once this call's own cast filled the queue, it returned false, even though the missing row was still waiting in it. The Playground omitted the cost chip.

The read path now checks `RequestLog.async_mode?/0`, independent of queue capacity; write backpressure still uses `async?/0`. The existing suspended-writer test now covers queue limits of 10,000 and one. The one-message queue reproduced the missing chip before the fix. Endpoint matching and the bounded two-second wait remain enforced.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
