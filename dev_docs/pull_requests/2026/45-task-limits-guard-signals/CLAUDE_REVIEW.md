# Claude Review — PR #45

**Reviewer:** Claude Sonnet 5.5
**PR:** Task limits, guard signals and the ai.manage sub-permission: per-task and per-user money, request and token limits by calendar day and month (timujinne)
**Reviewed:** 2026-10-22
**Merge commit:** `ac2a41c`

## Overall Assessment

**APPROVE with one fix applied.** Risk: **Medium**: it adds a database read to
every call of a task that has a limit, a second migration version, an Oban cron
and a permission. The pieces are carefully built: calendar windows in the site
time zone, "first layer that sets a cell wins" resolution, a generation-stamped
per-node cache that a stale write-back cannot resurrect, `ON CONFLICT DO
NOTHING` events whose dedupe key is unique in the database, and a LiveView that
re-checks `ai.manage` on every event against both the mount scope and the
session as it is now. One real defect (a non-UUID `user_uuid:` turned every
limit off), fixed here, plus a classification gap in the translation worker and
several design points worth a decision.

## Findings

### BUG - MEDIUM — a `user_uuid:` that is not a uuid switched all limits off (fixed)

`TaskLimits.check/3` passed `opts[:user_uuid]` to `usage/4`, which filters the
journal with `r.user_uuid == ^user_uuid`. The column is a uuid; a visitor's own
id (`"visitor-42"`) raised `Ecto.Query.CastError`, and the function-level
`rescue` (`task_limits.ex:572`) turned it into `:ok`. Only when a per-user limit
was in force (a declared `default_limits.user` is enough), but then the **task's
own limits were skipped too**, because the count for both scopes is one pass.
AGENTS.md says an external id "counts toward the endpoint and global caps", and
callers are told to cap the task for visitors, so this was the supported
configuration.

Reproduced first (`task limits of "test.limited" not checked:
Ecto.Query.CastError` in the log, `TaskLimits.check/3` returned `:ok` with the
task's request limit reached). Fixed: `check/3` reads the id through
`user_uuid/1` (`task_limits.ex:584`), which keeps a uuid and reads anything else
as "no user", so the task's limits apply and the per-user ones do not. New test
`an id that is no PhoenixKit user does not switch the task's limits off`;
AGENTS.md landmine updated.

### IMPROVEMENT - MEDIUM — translation failures hid why a call was refused (fixed)

`TranslateWorker.classify_reason/1` turns a failure into the static tag the
`ai.translation_failed` activity entry and the log carry. The new refusals
(`{:task_limit_exceeded, …}`, `{:model_unfit, …}`, `{:model_unverified, …}`) and
the older `{:budget_exceeded, _}` are 2- and 4-tuples, so inside `{:ai_error, _}`
they fell through to `classify_ai_detail/1`'s `"unclassified"`. The translation
pipeline is a declared task (`ai.translation`), so a task limit on it ends in a
discarded job whose audit entry said nothing about the cause. `retryable?/1`
already treats them as terminal, which is right. Fixed with four static-tag
clauses (`translate_worker.ex:480`), never the scope, unit or needs; test added.

### IMPROVEMENT - MEDIUM — `oban_crons/0` needs core 2.63, the pin says `~> 2.38`

`PhoenixKitAI.oban_crons/0` (`lib/phoenix_kit_ai.ex:997`) is annotated
`@impl PhoenixKit.Module`, a callback core added in **2.63.0** (its changelog:
"`api_tools/0` and `oban_crons/0`, both optional"). On core 2.38–2.62 the
callback does not exist: a compile warning in the dependency, and
`GuardEventsPruneWorker` is never scheduled, so `phoenix_kit_ai_guard_events`
only grows. I checked only this one callback against core's changelog; the
other new core calls (`Notifications.create_many/2`, `upsert_inapp/3`,
`TimeZone.date_start/2`, `Scope.can?/2`) have no changelog entry to date them by,
so the floor deserves a pass against core's history before the next release.
`Access` shows the intent to support older cores (`SessionRef` is looked up at
run time), so the floor is a policy decision: raise it (and
`core_pin_conformance_test.exs`, `@must_admit` / `@must_reject`, and the
Depends-on line in AGENTS.md), or keep it and treat pruning as best-effort.
Not changed.

### IMPROVEMENT - MEDIUM — an admin cannot lift a module's declared default

`effective/3` merges stored over declared, cell by cell, and an empty stored cell
falls back to the declaration (`task_limits.ex:172`). There is no way to say
"no limit here" against a `default_limits` entry; the page's own text says "An
empty limit is none" (`web/tasks.ex:665`) while the placeholder shows the
declared figure that still applies. The workaround is a very large number.
Not changed: needs a sentinel (or an explicit "unlimited" checkbox) and a
migration of the `limits` JSON shape's meaning.

### IMPROVEMENT - MEDIUM — forgiving does not re-arm the signal

`GuardEvents.limit_event/4` (`guard_events.ex:293`) dedupes on
`kind:task:user:unit:period_key`. After an admin forgives a limit the count
restarts, but a limit reached again in the same window finds its key taken: the
call is refused, and nobody is told, the user included. The refusal itself is
correct. Not changed: re-arming means putting the forgiving's timestamp in the
key and letting `reached_users/2` read it.

### IMPROVEMENT - MEDIUM — three journal queries per call, one over a month of rows

With any limit in force, every call of the task runs `forgiven/3`, then one
aggregate for the task and one for the user, each over `inserted_at` from the
earlier of the day/month start to the end of the month
(`totals_query/4`, `task_limits.ex:422`). The new expression index makes each an
index range, but it still reads the heap of every success row of the month to
sum `cost_cents` and `total_tokens`. The PR documents "the usage is read only
when a limit is in force" and pins the no-limit case at zero queries; it does not
say a limited, busy task pays this on every call. Not changed: a short-TTL
usage cache or rollup counters is a design decision (and would widen the
overshoot the docs already accept).

### NITPICK — first save of a task's settings can raise on a race

`update_settings/3` and `upsert_user_limits/4` build a bare
`Ecto.Changeset.change/2` and `insert_or_update/1` (`task_limits.ex:624,671`);
the unique indexes are not declared as constraints, so two admins saving a task
for the first time within the same moment get an `Ecto.ConstraintError`
instead of an `{:error, changeset}`. Self-healing on retry. Not changed.

### NITPICK — `form_limits/1` calls `to_string/1` on a submitted value

`web/tasks.ex:350`: a tampered form posting a map where a number belongs raises
`Protocol.UndefinedError` and restarts that admin's own LiveView. Needs
`ai.manage` to reach; nothing leaks.

### NITPICK — V2 ships columns and fields nothing reads yet

`phoenix_kit_ai_task_settings` carries `purpose_override`, `guard_mode`,
`classifier_*`, `auto_block_threshold`; the `kind` CHECK lists `off_purpose`,
`anomaly`, `blocked`, `unblocked`; `TaskSpec` accepts nine unused fields. The
chain is additive-only, so these are permanent unless a V3 drops them. Stated in
the moduledocs, so deliberate. A reviewer should know they are not an API yet.

### NITPICK — "nanodollars" in AGENTS.md, micro-dollars in the code

AGENTS.md names the `cost_cents` unit "nanodollars" while defining it as
1/1,000,000 of a dollar, which is a micro-dollar; the new modules (`TaskLimits`,
`TaskSpec`, `GuardEvents.format_usd/1`) say micro-dollars and `$1 = 1_000_000`.
The figures agree; only the name differs. Not changed (the old name appears in
several earlier docs and the `Budget` moduledoc).

### NITPICK — personal limits ride in one cache entry

`load/1` puts every user's personal limits of a task into one entry, and ETS
copies the whole term on each lookup. Fine for a handful of exceptions; a task
with thousands of them would copy that per call.

## Reviewed and sound

- **Windows**: day and month are half-open UTC intervals from the site zone's
  local midnights (`TimeZone.date_start/2`); tests cover a UTC+3 midnight and a
  day with a clock change.
- **Counting**: `status = 'success'` only; cache hits count one request and no
  money; a refusal never counts; the query matches the new expression index
  (`fragment("?->>'task'", …)`).
- **Cache coherence** (`forget/1`, `cached/1`): a load stamped with an old
  generation is unusable even if written back after a change; PubSub plus a 60 s
  TTL bound a lost broadcast, as documented.
- **Signals never fail a call**: `GuardEvents` wraps every signal in `safely/1`
  and logs the exception class only, so the function-level `rescue` in
  `check/3` is reached only by a counting error.
- **PII**: notification texts carry the task, the user's e-mail (to watchers
  only) and the limit's numbers; activity metadata carries uuids, tasks and
  numbers; no reason or content.
- **Authorisation**: every mutating function takes the actor's scope and checks
  `ai.manage`; the LiveView checks mount scope and session scope per event; the
  endpoint form's "declare capabilities" gate is enforced again in
  `guard_declaration/3` against a crafted event.
- **Migration V2**: the journal index is created with a plain `CREATE INDEX`;
  the SHARE-lock caveat, `CONCURRENTLY` impossibility and "measure first" advice
  are written up in AGENTS.md. Down to 1 drops only what V2 added.
- **Oban cron**: `GuardEventsPruneWorker` checks `enabled?/0`, deletes events
  past 180 days, and its dedupe keys are long expired by then.

## Positive Observations

- A "what a call costs the database" test group counts SQL statements, so the
  no-limit path cannot regress to a query per call unnoticed.
- `Guard.admit/4` lets one assistant turn make several calls under one limit
  check without opening a hole: bound to task and user, expiring, never
  skipping the model check or `Budget`.
- Money is shown as dollars and stored as micro-dollars, with `format_usd/1`
  rounding nothing away and a positive amount that would round to 0 refused at
  the form (`amount("money", …)`), so "0 allows nothing" is never typed by
  accident.

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Good; the per-call aggregate is the cost to watch |
| Security | Good; one fail-open path closed |
| Performance | Fine for modest volume; see the per-call queries |
| Test coverage | Very good (718 + 396 + 264 + 172 lines) |
| Migration safety | Good, with the documented lock on a large journal |
| Consistency | One gap: core pin vs `oban_crons/0` |
