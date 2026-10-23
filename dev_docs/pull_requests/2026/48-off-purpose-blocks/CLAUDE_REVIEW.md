# Claude Review — PR #48

**Reviewer:** Claude Sonnet 5.5
**PR:** Off-purpose use and blocks: consumer self-flag reports, anomaly signals, blocks by task group with privacy of reasons (timujinne)
**Reviewed:** 2026-10-23
**Merge commit:** `0f3f879` (the merge also carries #46's commits; see `../46-native-model-capabilities/`)
**Other reviews:** `GPT_REVIEW.md` (Codex, 2026-10-22) found and fixed UUID spelling bypassing a block, a stale Tasks page, and `:exit` escaping the guard fallbacks. I did not repeat those; I checked that the fixes are in `main`.

## Overall Assessment

**APPROVE with one fix applied.** Risk: **Medium** — a new table (schema V3),
a permission-sensitive write path (who may block and lift whom), and a check on
every call of a task that has a user. The authorization matrix in the
`GuardBlocks` moduledoc matches the code: `authorize_block/2` (needs `ai.manage`;
only an Owner blocks an Owner) and `authorize_lift/2` (Owner always; otherwise
a lifter who is not the blocked person and the block is not an Owner's; an
`agent.manage` holder only for `free_text`). The table is additive, every
statement guards itself, the one-active-block rule is a partial unique index
that `insert/6` maps to `:already_blocked`, and a double lift is settled by
`update_all ... where is_nil(lifted_at)` returning `{0, _}`.

## Findings

### IMPROVEMENT - MEDIUM — the model's off-purpose reason bypassed the request-content gate (fixed)

`Guard.report_off_purpose/4` stores the model's `reason` (≤ 500 code points) in
`phoenix_kit_ai_guard_events.reason` unconditionally. The instruction asks the
model not to quote the user, but nothing enforces it, and a model that explains
*why* a message was off-topic often echoes it. `AGENTS.md` is explicit that
"any new field carrying user text must sit behind the same gate" as message
bodies and responses (`capture_request_content?/0`), so an operator who turned
capture off for retention or PII reasons was still collecting fragments of user
text in a table that is read by every holder of `ai` (reasons of non-private
tasks are visible to them).

Fixed: `report_off_purpose/4` passes the reason through `flag_reason/1`
(`guard.ex`), which keeps it only while `:capture_request_content` is true. The
flag itself, its dedupe, the watchers' notification and the Activity entry are
unchanged — only the free text is dropped. Test: `the reason is kept only while
request content is captured`; `AGENTS.md` updated. (Admin-typed block reasons and
lift notes are not user text and are untouched.)

### NITPICK — `GuardBlock.private` is a snapshot of the group at block time

`insert/6` stores `private: private?(group)`, and `active/3` decides who sees
the reason from that stored flag. If a
declaration later becomes `private: true` (a code change in the consuming
module), reasons of blocks written earlier stay visible to plain `ai` holders
until the block is lifted. Rare — privacy is a static declaration — and
re-deriving it at read time means a registry lookup per row. Left as is; worth a
line in the moduledoc, which today says only "private when any task of the group
is".

### NITPICK — lifting from the Tasks page needs `ai.manage` even where the context allows `agent.manage`

The context lets an `agent.manage` holder lift another person's `free_text`
block, but `Web.Tasks` gates `lift_open`/`lift_block` on `Access.may_manage?/1`
(`ai.manage`) like every other guard event. Harmless — that holder has the
assistant's own screen — but the matrix in the moduledoc reads as if the page
honoured it. Fine to keep; mention it next to the table.

### NITPICK — `calls_per_hour` counts failed and cached calls

`Guard.calls_in_last_hour/2` excludes refusals but counts provider errors and
cache hits as calls. Defensible ("the person made N calls") and cheap, and it
only signals; just worth knowing when picking `max_calls_per_hour`.

### NITPICK — admission tokens keep the caller's spelling of the user uuid

`admit/4` stores `user_uuid` as given and `admitted?/3` compares it with `^`.
After Codex's canonicalisation of the block lookup this can only cost an extra
check (a differently-cased uuid is not recognised as admitted and the call is
checked in full), never skip one. Canonicalising on `admit` would make the token
exact; not needed for correctness.

## Positive Observations

- **The cache is race-safe.** `GuardBlocks.cached/0` reads the generation
  *before* loading and stores it with the entry, so a `forget/0` that lands
  during `load/0` leaves a stale-generation entry that the next call discards;
  a lost broadcast is bounded by the 60 s read-again.
- **No reason in any message, refusal or log.** The refusal names the group
  only, `GuardEvents` texts carry no reason or note, the LiveView catch-all logs
  `MessageShape.describe/1`, and every fail-open path logs the exception *class*.
- **Unicode-correct truncation.** `cut/1` counts code points (what the CHECK
  counts) but never splits a grapheme, with a code-point fallback for a single
  oversize grapheme; tests cover a 600-family-emoji reason.
- **Rights are re-checked per event** in the LiveView against both the mount scope
  and the session as it is now, and again in the context.
- About 1 500 lines of tests across blocks, off-purpose, the LiveView and the migration.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Good — checks sit in `authorize/5` and `admit/4` |
| Security | Good; one PII-gate gap fixed |
| Performance | One cached map lookup per call; one query a minute |
| Test coverage | Very good |
| Migration safety | Good — V3 additive, guarded, `DROP TABLE IF EXISTS` down |
| Consistency | Good |

**Verdict:** APPROVE.
