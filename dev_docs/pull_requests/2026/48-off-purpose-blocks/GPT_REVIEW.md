# GPT review — PR #48

Reviewed 2026-10-22 by Codex against merge `0f3f879`.
Author: @timujinne. [PR #48](https://github.com/BeamLabEU/phoenix_kit_ai/pull/48).

## BUG - HIGH — UUID spelling bypasses an active block (fixed)

The active-block cache keys use the database's canonical lowercase user UUIDs.
The check used the caller's original string. Passing the same UUID in uppercase
therefore skipped the block, including at turn admission, although the journal
still attributed the request to the blocked user.

Both checks and active-block reads now cast the identity through Ecto.UUID before
lookup. Tests verify uppercase and binary lookup/admission identities, the
uppercase public completion path, refusal before provider HTTP, and invalid
external IDs remaining unblocked.

## BUG - MEDIUM — another administrator's changes leave the page stale (fixed)

The Tasks LiveView subscribed only to capability refreshes. A block, lift, or
guard-mode change made elsewhere invalidated the enforcement cache but left an
open page showing old controls and state indefinitely. It now subscribes to the
existing guard topic and reloads on block and task-setting changes, rechecking
current management rights before deciding whether to show private details.
LiveView tests exercise another administrator's block/lift and self-flag switch;
private reasons remain hidden from an ordinary AI viewer.

## BUG - MEDIUM — database exits escape documented fallbacks (fixed)

Settings lookup, block checking, and post-request anomaly checking rescued
exceptions but did not catch connection-pool exits. A disconnect could terminate
a consumer preparing its prompt, admitting work, or returning a completed call,
contrary to the documented fallback behavior. The same gap existed in #45's
task-limit check.

Each boundary now catches `:exit`, preserving its existing default or fail-open
result and logging only the failure class. A repository failure injection covers
self-flag defaults, instruction generation, blocks, limits, hourly anomaly
counting, and omission of a sentinel private exit payload from logs. It failed
before the repair.

## Checks and boundaries

Rechecked block-group resolution, Owner/self-lift restrictions, `agent.manage`
lifts, stale-row/concurrent lift handling, dedupe, notifications and Activity,
reason visibility, Unicode truncation against database constraints, per-node
cache invalidation, and admitted-turn continuity. Existing database fail-open
semantics and the documented cache visibility bound across transactions remain.

All initial block and live-page regressions failed before their repairs. Final
validation is in [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md).
