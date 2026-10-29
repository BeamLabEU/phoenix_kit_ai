# PR #59 — Image-AI building blocks

Reviewer: GPT / Codex · Date: 2026-10-29 · Merge: `b7087e6`

Reviewed against `e457ea6`, including the fixes already incorporated in the
merge. Of the ten latest merged PRs, #50–#58 already have GPT reviews; #59
was the only new unreviewed PR.

## BUG - HIGH — batch exception logs exposed argument values (fixed)

`VisionBatch.safely/1` omitted the exception message but formatted the original
stacktrace. Erlang frames can include actual arguments instead of an arity:
an `ArgumentError` from `binary_to_integer/1` consequently logged its input,
which could be a caption or credential. Frames now replace argument lists
with their lengths before formatting. Exception class, function, arity and
source location remain available. The regression passes private text through
the real request and checks that its failed conversion leaves no text in the
batch crash log.

## BUG - MEDIUM — embedding cache hits reported the original cost (fixed)

New embedding responses carry a string-keyed `"cost"`, while `hit_value/3`
cleared only atom-keyed `:cost`. Repeated cached embeddings therefore reported
spend even though their journal rows cost zero. The cache now uses the cost
key appropriate to the verb. The regression checks both logged and unlogged
hits, and compares the logged value numerically with its persisted Decimal.
The embedding return documentation also now reflects that asynchronous
logging returns the known cost before the row is written.

## BUG - MEDIUM — embedding image limits were applied per image only (fixed)

Every embedding image was normalized in isolation. Several individually
valid images could exceed `max_total_input_bytes` in one provider request.
Preparation now accumulates the inline bytes across all embedding items and
rejects an oversized request before HTTP or a usage row. Per-image validation
and the existing remote-URL policy remain in place. The regression mixes text
and both tuple/map image inputs and asserts the combined size and limit.

## BUG - MEDIUM — failed confirmations were billed twice in batch totals (fixed)

When a confirmation answer was unusable, `check_statements/4` added its cost
to the returned result and left the same cost in the process accumulator.
The batch then added it again, inflating totals and prematurely skipping
later items under a budget. A compound result now consumes only the costs it
includes; earlier fallback costs stay available for the batch. Two regressions
compare batch totals with `run_costs/2`: one verifies the next item still
starts, and one includes failed fallback attempts before and during the
confirmation.

## BUG - MEDIUM — a default-user refusal skipped other users' items (fixed)

The fatal-stop decision examined only the failing item's overrides. If the
first item inherited the batch's capped user, later items overriding that
user were skipped despite being eligible. A batch containing any identity,
task, admission or model override now stops only for account-wide failures.
This policy applies to grouped calls too. `fallback_models:` is also included
among model overrides. The regression exhausts the default user's cap, then
checks that the next user's item succeeds.

## Validation

Six regression tests reproduced the five defects before repairs. The focused
image suite passes: 1 doctest, 102 tests, 0 failures.

- Full `mix test`: 1 doctest, 2,398 tests, 0 failures.
- `mix precommit`: passed compilation with warnings as errors, unused-lock
  check, Hex audit (no advisories), formatting, strict Credo (no issues), and
  Dialyzer (three existing suppressions; none added or unnecessary).
- `git diff --check`: passed.

The existing test database is at core V224 and cannot migrate directly with
the newly locked core 3.0.0 (floor V225). Validation uses a fresh, isolated
`pk_ai_pr59_review_20261029` database with the locked Hex dependencies,
`PGPOOL=10` and `--max-cases 8`; no database skip or local core override.
The temporary database was removed after validation.

Also traced box format selection, malformed OCR block filtering, statement
confirmation by position, fallback error mapping, grouped answer parsing,
run-tag aggregation, and request-content logging. The suspected OCR-box
alignment issue was ruled out: both block parsers filter to maps before
pairing. No change was needed there. Existing per-node limits, in-flight
budget overshoot and unknown provider costs retain their documented limits.
