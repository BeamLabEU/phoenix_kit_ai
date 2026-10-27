# PR #57 — Journal retention settings and bounded cleanup

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `74ad481`

### BUG - MEDIUM — manual content cleanup could not run for flag reasons alone (fixed)

The content pass also clears old off-purpose reasons, but its preview counted only journal rows. With the journal empty and old reasons still present, every preview count was zero and `runnable?/1` disabled cleanup. Those reasons could only be cleared by a scheduled run or an internal call.

The preview now includes `guard_reasons`, using the same SQL predicate as the clearing pass, and the card displays the count and enables cleanup for it. Active blocks' origin events, recent flags and other event kinds remain excluded. The context test checks those exclusions; the LiveView test starts with no journal rows, confirms the cleanup, executes its Oban job and verifies the reason is gone. English, Estonian and Russian messages are supplied.

### BUG - MEDIUM — retention controls and previews survived live permission revocation (fixed)

The Usage page refreshed `ai.view_usage` on core's scope callback, but left `retention_can_manage` and pending confirmations untouched when only `ai.manage` was lost. Context checks prevented a write, but the page still offered management and retained a preview from the former scope. The callback now refreshes retention access and discards forms and previews on loss. A real core-hook test checks revoke and regrant without restoring the old confirmation.

Also reviewed the deletion floor, FK/index checks, keyset progress, content resume markers, chunk timeouts, worker arguments, grace period and once-per-night behaviour. No schema migration is required for these fixes.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
