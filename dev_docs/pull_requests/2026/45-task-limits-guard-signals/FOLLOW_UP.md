# FOLLOW_UP — PR #45 (Task limits, guard signals, ai.manage)

Triaged 2026-10-22. `CLAUDE_REVIEW.md` found one bug, five improvements and
five nitpicks.

## Fixed

- **BUG - MEDIUM:** a `user_uuid:` that is not a uuid made the usage count raise
  and `check/3` fail open for every limit, the task's own included.
  `TaskLimits.check/3` now reads such an id as no user
  (`lib/phoenix_kit_ai/task_limits.ex`); test in
  `test/phoenix_kit_ai/task_limits_test.exs`; AGENTS.md landmine updated.
- **IMPROVEMENT - MEDIUM:** `TranslateWorker` reported a task-limit, budget or
  model refusal as `unclassified`; it now carries a static tag
  (`task_limit_exceeded`, `budget_exceeded`, `model_unfit`, `model_unverified`)
  (`lib/phoenix_kit_ai/translate_worker.ex`); test in
  `test/phoenix_kit_ai/translate_worker_failure_classification_test.exs`.

## Not changed

- **IMPROVEMENT - MEDIUM:** `oban_crons/0` needs core 2.63, the pin is `~> 2.38`.
  Raising the floor also means `core_pin_conformance_test.exs` and the AGENTS.md
  Depends-on line, and excludes hosts on 2.38–2.62: the maintainer's call.
- **IMPROVEMENT - MEDIUM:** no way to lift a module's declared `default_limits`
  from the Tasks page; the page text ("An empty limit is none") disagrees.
- **IMPROVEMENT - MEDIUM:** forgiving a limit does not re-arm its once-per-window
  signal.
- **IMPROVEMENT - MEDIUM:** a limited task pays three journal queries per call,
  one over the month's rows. Needs a usage cache or counters.
- **NITPICK:** first save of a task's settings or a user's limits can raise
  `Ecto.ConstraintError` on a race (no `unique_constraint/3`).
- **NITPICK:** `form_limits/1` raises on a tampered non-scalar value.
- **NITPICK:** V2 columns and `TaskSpec` fields for unbuilt guard parts are now
  permanent in an additive-only chain.
- **NITPICK:** all personal limits of a task are one cache entry, copied per
  lookup.
- **NITPICK:** AGENTS.md says "nanodollars" for what is 1/1,000,000 of a dollar.

## GPT recheck — 2026-10-22

Re-armed warning/reached signals after forgiveness; mapped uniqueness conflicts; rejected malformed limit shapes without losing saved caps; normalized visitor ids in usage/status reads; raised the core floor to 2.63; corrected blank-limit inheritance wording.

See [GPT_REVIEW.md](GPT_REVIEW.md) for evidence, regression coverage and the
remaining design tradeoffs. This section supersedes the corresponding earlier
“Not changed” entries; Claude's review is preserved.
