# Claude Review — PR #29

- **Reviewer:** Claude Opus 5.5
- **PR:** TranslationSweep: one engine behind every module's AI translation sweep (mdon/main)
- **Date:** 2026-09-24
- **Merge commit:** `9378a8e`

## Notes for Max (reviewer)

- The PR also includes `4ba08fe` ("Update actor and activity logging to use core"),
  which is where the one serious finding comes from. The sweep engine itself is sound.
- Tested against Hex core 2.38.0 (`mix test`: 1141 tests, 0 failures, integration
  tests included) and `mix precommit` clean.

## Overall Assessment

**Verdict:** APPROVE. It needed a dependency-floor fix before release, and that
fix is now applied.
**Risk level:** High as merged: every endpoint and prompt mutation would crash on
core below 2.38. Low after the fix.

The PR does two things:

1. It adds `PhoenixKitAI.TranslationSweep`, a self-rescheduling Oban chain.
   Consuming modules (`phoenix_kit_catalogue`, `phoenix_kit_ecommerce`) run their
   background translation top-up through it.
2. It replaces every hand-guarded `PhoenixKit.Activity.log/1` call and the
   hand-rolled actor read with core's new `Activity.log/3` and `PhoenixKitWeb.Actor`.

Behaviour verified against the producing code:

- **Chain uniqueness is correct.** `unique: [period: :infinity, states: [:available, :scheduled]]`
  (`lib/phoenix_kit_ai/translation_sweep.ex:65`) leaves out `executing`, so a
  running tick can insert its successor. It still contains insert states, so
  Oban 2.24's `warn_unique/1` stays quiet and a second waiting tick is detected.
- **`reschedule/1`** (`:169`) runs one guarded `UPDATE ... WHERE state = 'scheduled'`.
  It moves the waiting tick instead of cancelling it, so it cannot kill a tick
  that started between a read and a cancel.
- **The `recently_failed/1` DISTINCT ON** (`:458`): Ecto puts the `distinct`
  expressions in front of `order_by: [desc: id]`, so Postgres accepts it and
  each (type, uuid, lang) resolves to its latest job.
- **Budget admission** (`take_within_budget/3`): an empty candidate cannot reach
  it, because `without_pairs/2` drops a candidate once it has no languages left
  (after `only_targets/2` and the in-flight filter).
- **The outcome record** (`finish/3`, `:487`) compares string-keyed JSON with
  string-keyed JSON. `limit/1` has already turned `:infinity` into an integer,
  so a stored outcome round-trips equal and a steady state writes no settings
  history.

## Critical Issues

### BUG - CRITICAL: the code calls core APIs the `~> 2.0` pin does not guarantee

`lib/phoenix_kit_ai.ex:324`, `:859`, `lib/phoenix_kit_ai/openrouter_client.ex`,
`lib/phoenix_kit_ai/translate_worker.ex:327`/`:355`, `lib/phoenix_kit_ai/translation.ex`
and `lib/phoenix_kit_ai/web/auth_helpers.ex:27` now call
`PhoenixKit.Activity.log/3` and `PhoenixKitWeb.Actor.opts/1` without a guard.
Both first shipped in core **2.38.0**. When the PR merged, the newest core on
Hex was 2.37.5, which has only `log/1` and no `Actor`.

- `mix compile --warnings-as-errors` against 2.37.5 fails: "`PhoenixKit.Activity.log/3`
  is undefined", "`PhoenixKitWeb.Actor.opts/1` is undefined".
- At runtime, the old `Code.ensure_loaded?` guard and `rescue` are gone. On a
  host resolving any core from 2.0 to 2.37, every `create_endpoint` /
  `update_prompt` / toggle raises `UndefinedFunctionError`, and so does every
  admin `actor_opts/1` call. So do the translation-job activity entries, and
  that is after the translation row has already been written, so Oban retries
  a job that succeeded.

Core's own CHANGELOG for this release says modules calling these APIs "must
feature-detect them while they keep the open `~> 2.0` core pin".

**Fixed:** the pin is raised to `pk_dep(:phoenix_kit, "~> 2.38")` (`mix.exs`),
with a floor comment in the same style as the earlier ones. It is still a
two-segment requirement, so every later 2.x minor is admitted.
`test/core_pin_conformance_test.exs` now admits `2.38.0`–`2.99.x` and rejects
`2.0.0` and `2.37.5`. Its old `@must_admit ["2.0.0", …]` would have failed the
new pin, and it now guards the floor too. Feature-detection was the
alternative, but it would have brought back the hand-rolled guards this PR
exists to delete.

## Medium

### IMPROVEMENT - MEDIUM: a zero or negative interval makes the chain spin

`ensure_scheduled/1` schedules `interval_minutes * 60` seconds out. The
callback type says `pos_integer`, but consumers read the value from a setting.
`phoenix_kit_catalogue`'s `sweep_interval_minutes/0` is a bare
`Settings.get_integer_setting/2`, and a hand-edited `0`, a negative number or
`nil` gets through. With `0`, each tick schedules its successor for now: a
chain that never rests, re-running the candidate and in-flight queries
back to back.

**Fixed:** `settings/1` clamps the interval through `interval/1`
(`translation_sweep.ex:561`) to at least one minute. Test: "an interval below a
minute schedules the tick a minute out, never now" (0, −5, `nil`).

## Low

### NITPICK: the `perform/1` doc said "always `:ok`"

It returns `:ok` for every stop reason, but a raise inside `run_tick/2` (a
consumer callback bug, for example) fails the job. That is the right
behaviour, because Oban logs it and the successor is already scheduled, but the
doc claimed otherwise. **Fixed:** the doc now describes both cases.

### NITPICK: two manual runs at once are not excluded (not changed)

`alone/2` (`:241`) refuses a manual run only while a *scheduled* tick is
`executing`. Two operators, or a double-click, can run two manual ticks at
once. Each reads the same in-flight count, so together they can overshoot
`max_in_flight` once. `Translations.enqueue_all_missing/2` still skips a pair
that is already in flight, so the damage is limited to the ceiling. A real
exclusion needs `pg_try_advisory_xact_lock` wrapping the whole tick in a
transaction, which is too heavy for a soft cap. The moduledoc already calls the
enqueue guard "a check, not a constraint".

### NITPICK: the chain relies on its consumer to re-seed after a lost successor (not changed)

The first thing `perform/1` does is schedule the successor. If `sweep_settings/0`
raises at that moment, `ensure_scheduled/1` rescues and returns
`{:error, :schedule_failed}`, and the chain ends until something calls
`ensure_scheduled/1` again. Consumers do call it (from their boot and settings
paths), and when the database is down the insert would fail anyway. A fallback
interval would only help against a consumer bug.

### NITPICK: AGENTS.md pointed at the conformance tests under the wrong directory

They live at `test/core_pin_conformance_test.exs` and
`test/schema_prefix_conformance_test.exs`, not under `test/phoenix_kit_ai/`.
**Fixed** in AGENTS.md.

## Positive Observations

- Scheduling the successor *first* is the right order for a chain with
  `max_attempts: 1`: a crashing tick costs one interval, not the chain.
- Only the resource types a source owns count toward its in-flight total
  (`in_flight/1`), so two modules' sweeps do not throttle each other.
- The back-off keys on the *latest* job per pair, so a later success or a job
  still running clears it without any bookkeeping.
- `finish/3` records only outcome *changes* (0491a3f). Settings keep permanent
  history, and without this an hourly tick would grow that table forever.
- Moving activity logging to core's never-raising `log/3` removes four
  near-identical guard/rescue blocks that had drifted: one silenced
  `undefined_table`, one re-raised, one swallowed everything.
- The legacy-migration test now asserts the activity entry it used to trust.

## Summary

| Area | Rating |
|---|---|
| Code quality | Good. Dense but well-commented; the callbacks are small and typed |
| Architecture | Good. One engine; consumers keep their own worker name for already-scheduled jobs |
| Security | No concerns. The system actor is `nil`, and no PII goes into outcomes |
| Performance | Fine. Two indexed-ish `oban_jobs` scans per tick, filtered by worker |
| Test coverage | Good. Chain, gates, caps, back-off and outcome dedupe are all covered |
| Migration safety | None needed. It stores one setting per source |
| Consistency | Broken on the core pin until fixed; otherwise matches repo conventions |

**Strengths:** a crash-tolerant chain, per-source isolation, and an outcome
record that doesn't grow history.

**Areas to address:** the core floor (fixed) and the interval clamp (fixed).

**Verdict:** APPROVE with the follow-up applied. Ships in 0.24.0.
