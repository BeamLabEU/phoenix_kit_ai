# Journal retention

How long the AI module keeps its journal, and how the cleanup that applies
it behaves on a host. The code is `PhoenixKitAI.Retention` (the policy, the
boundaries, the preview, the chunked cleanup) and
`PhoenixKitAI.JournalPruneWorker` (the Oban job); the admin surface is the
"Journal retention" card on **AI → Usage**.

**By default nothing is deleted.** Journal data goes only (a) at night, by a
period a person chose after seeing a preview, no earlier than a day after
choosing it, or (b) by "Clean up now", after a preview and a confirmation.

## What is kept

- **The request journal** (`phoenix_kit_ai_requests`): one row per call —
  endpoint, model, tokens, latency, cost, status, `error_message` — and a
  `metadata` map. With `capture_request_content` on (the default),
  `metadata` also holds the call's content: messages, the request payload,
  the response, reasoning, tool calls, inputs; outside that gate it holds
  debug context (`stacktrace`, `caller_context`, an image failure's
  `error_reason`). The spend caps, task limits, Usage totals and model
  recommendations all read this table.
- **The guard's events** (`phoenix_kit_ai_guard_events`): limit warnings,
  limits reached and forgiven, off-purpose flags (with a `reason` that can
  echo the user's words), anomalies, models that stopped fitting, blocks
  and lifts.

## Three periods

Each kind has its own period: "keep forever" (the default) or N days,
months or years (up to 36 500 days, 1 200 months, 100 years).

| Kind | What a period does |
|---|---|
| Content of journal entries | Rows older than the period lose the content keys (`Retention.content_keys/0`) from `metadata` and get `metadata.content_pruned_at`. The row, its cost, tokens, model and every small key stay, so the money and limit readers count exactly as before. The `reason` of an `off_purpose` event older than the boundary is cleared too. |
| Journal entries | Rows older than the period are deleted, cost included. |
| Guard events | Events older than the period are deleted. |

Any combination is allowed. Content never outlives its row: with content
kept longer than the rows (or forever while the rows are not), the card
says the content "will live as long as its entry does".

Boundaries are taken in the site time zone (an empty or unusable zone is
UTC): N days is local midnight N days before today, N months the start of
the local month N months before the current one, N years the same with
12·N months. So:

- **"1 year" keeps 12 full months plus the current one.**
- **"1 day" keeps 24 to 48 hours** of content: the boundary is the start
  of yesterday (local midnight), wherever in today "now" falls.

## The floor

One technical guard sits under every boundary, whatever its origin — the
nightly run, a preview, "Clean up now", a job's own arguments:

- **Journal rows and guard events** newer than local midnight two days
  before the first of the current month are never deleted (on 25 October:
  nothing from 29 September on). The day and month task limits read the
  current month; the trailing 24-hour spend cap reaches into the previous
  month during the 1st; a month's forgiven limits are `limit_forgiven`
  events read from the month's start — deleting one would undo the
  forgiving. The two days cover a change of the site's time zone and clock
  skew between nodes; midnight lets the preview name the date.
- **Content** newer than 24 hours is never cleared.

A shorter period is not refused: its boundary is held at the floor, and the
preview says so ("The period is shorter than the current month: entries
from … on are not deleted — the spend limits read them"). A boundary in the
future is refused (`{:cutoff_in_future, kind}`).

The event a block was set from is neither deleted nor cleared while the
block stands; once it is lifted, the event follows the period like any
other.

## The nightly cleanup and the crontab

`PhoenixKitAI.oban_crons/0` declares
`{"17 3 * * *", PhoenixKitAI.JournalPruneWorker}`, in core's `default` queue.
`mix phoenix_kit.install` writes it into the host's Oban crontab and
`mix phoenix_kit.update` adds it when it is missing. A host that does not
want it comments the entry out: the installer reads a commented entry as
declined and does not offer it again. Adding the entry deletes nothing by
itself — every period starts as "keep forever".

Each night the job reads the periods and skips a kind kept forever or
changed less than 24 hours ago (a day to change one's mind). With the AI
module off the night is recorded as `skipped`.

**Once a night.** A night whose previous scheduled run ended `ok` less than
20 hours ago does nothing and records nothing. That absorbs a duplicated
crontab entry and the old worker's shim — and also a second schedule the
host added on purpose: a run more often than every 20 hours does not
happen. Use "Clean up now" for an extra run.

**One at a time.** The nightly and the manual job share one Oban uniqueness
(the worker, in any state but finished), so a night while a manual run is
queued or running does not start, and a second manual run is refused with
"A journal cleanup is already running".

**The old worker.** `PhoenixKitAI.GuardEventsPruneWorker` used to delete
guard events after 180 days. It is now a shim that only queues
`JournalPruneWorker` and deletes nothing, and it is no longer in
`oban_crons/0`. A crontab that still lists it, next to the new entry the
update adds, runs one cleanup a night: the shim's job conflicts with the
nightly one or meets the once-a-night rule. A host that had commented the
old entry out to keep its guard events is offered the new entry on the
next update — accepting it is safe, since guard events are now kept until
a period is set for them.

## A run

In this order: journal rows, content, off-purpose reasons, guard events.
Rows that will be deleted are not cleared first.

- **Before anything**, the foreign keys pointing at the journal and the
  events (`pg_constraint`, by schema-qualified name) are checked: each must
  be `ON DELETE SET NULL`, on one nullable column, with a valid index
  leading with that column. Anything else — `RESTRICT` / `NO ACTION` would
  fail every chunk, `CASCADE` would silently delete another module's rows,
  no index would scan the other table for each deleted row — refuses the
  run (`{:foreign_key_blocks, table}`) with nothing deleted. The preview
  reports it too.
- **Short chunks**, each its own transaction with a 30 s statement timeout
  and a 5 s lock timeout, so a stuck chunk fails with an error the run
  records instead of being killed by the job's timeout. A 50 ms pause
  between chunks.
- **Journal rows**: keyset by `(inserted_at, uuid)`, 1 000 per chunk, locked
  rows skipped (`FOR UPDATE SKIP LOCKED`); whether rows are left is a probe,
  not a short chunk.
- **Content**: windows of 500 rows, clearing the ones that carry content and
  waiting for a locked row rather than skipping it. A chunk that hits the
  statement timeout halves the window, down to 50. The point below which
  content is already cleared is kept, so the next run starts from it.
- **Guard reasons and events**: small, unordered chunks.
- **Time slices**: journal rows 10 minutes, content 6, reasons 1, events 2,
  and at most 1 000 000 rows per counter per run. What is left is reported
  as "More is left" and continued by the next night or the next manual run.
  The job's timeout is 25 minutes, under the 60 minutes after which Oban's
  Lifeline (by default) would rescue it and start it a second time.

Rows written during a run, `request_log_mode: :async` included, are newer
than any boundary and are not touched.

The sizes, pauses and slices are options: `config :phoenix_kit_ai,
:journal_prune, request_batch: …, content_batch: …, content_min_batch: …,
event_batch: …, pause_ms: …, max_rows: …, statement_timeout_ms: …,
lock_timeout_ms: …, time_limits: %{requests: …, content: …, guard_reasons:
…, guard_events: …}` (ms), plus `preview_timeout_ms:` (60 000) for the
preview's counts. An invalid value falls back to its default with a
warning, and a `pause_ms` above 5 000 is 5 000, with a warning. Each
counter may run past its slice by one pause, one chunk and one probe (and
the content step starts no later range of its walk once its slice is
over), so the budget is the slices plus, per counter, one pause and two
statements at `statement_timeout_ms` + 5 s, plus a minute for the checks
and the stamp. Time slices that would not fit in the 25-minute timeout
that way fall back as a whole. A `statement_timeout_ms` too long for even
the default slices (32 500 − `pause_ms` / 2 or more: 32 475 at the default
pause) is lowered to the largest that fits, with a warning naming the
option, so a run's budget stays under the job's timeout.

A failed check (a foreign key, a boundary in the future) cancels the job
without retries and records `failed`. A failed chunk is an error: Oban
retries the job (3 attempts), each attempt counting from zero; the chunks
committed before the failure stay done.

## By hand

"Clean up now" on the card, per kind: leave as it is, by the saved period,
or a value for this run only (not saved; the floor applies the same way).
"Count" runs the preview in the background — rows and events older than
each boundary, and "up to" N rows whose content would be removed (counted
by time, without reading `metadata`, from the later of the rows' boundary
and the point already cleared — the date the line names). It also counts
off-purpose flag reasons that the content step clears, excluding active
blocks' origins. Those reasons alone are enough to enable a cleanup when
no journal rows remain. "Delete" opens a confirmation with
the same numbers and dates; the job gets the boundaries the preview used,
held at the floor again when it runs. If the count does not finish within
60 s the card says so and still lets the run go ahead: the boundaries are
checked again and the numbers will be in the outcome.

Saving a shorter period (or the first finite one) goes through the same
preview and confirmation, with the date of the first nightly cleanup.

From code: `PhoenixKitAI.Retention.run_now(scope, %{requests: cutoff})`
queues a run, `preview(scope, cutoffs)` counts, and
`put_settings(scope, periods, loaded)` saves periods; each checks the
scope's right and answers an error atom rendered by
`PhoenixKitAI.Errors.message/1`.

## Rights

Changing the periods, the preview and a cleanup by hand — all three kinds —
need `ai.manage` or an Owner. Seeing the periods and the outcome of the
runs on the Usage tab needs `ai.view_usage` as well as the `ai` module
permission; without `ai.manage` the card is
read-only. The context functions check the right, and the card checks it
again on every acting event against the scope as it is now, so a right
withdrawn while the page is open stops working at the next click. Core's
scope refresh also removes the controls and pending previews immediately;
regaining the right does not restore a discarded confirmation.

## Audit

- Every manual run, and every night that deleted or cleared something:
  `journal.pruned` in the Activity feed, under module `ai`, `mode` `manual`
  or `cron`, the person of a manual run, with the counts, the boundaries
  used and whether more is left — no row ids, no content. Entries are
  written `permanent: true`, so core's own Activity pruning keeps them.
- A failure: `journal.prune_failed` with the failure's class (a database
  error code or an exception name, never the database's message) and the
  counts already done. A nightly refusal that repeats night after night
  (the same foreign key, say) is written to Activity once per 20 hours per
  class; the card shows every night's.
- A change of periods: core's `setting.changed` entry for
  `ai_journal_retention`, with the person and the old and new values.

The outcome of the last nightly and manual runs is also the setting
`ai_journal_retention_last_run`, written without settings history.

## What the card shows

- The periods, and warnings while editing: journal rows kept less than 3
  months (nothing left to check the provider's invoice against before the
  boundary), any kind kept less than 30 days (the 30-day windows — model
  recommendations, token medians, flags of the last 30 days, the 30-day
  totals — see less), guard events kept less than 3 months (flags and
  forgiven limits before the boundary go).
- The nightly line: automatic cleanup off (everything kept forever); the
  first cleanup of a kind changed less than a day ago, not before a date;
  the last night within 36 hours with what it did and "More is left"; a
  failed night with its reason; or "The nightly cleanup has not run" — check
  that `PhoenixKitAI.JournalPruneWorker` is in the crontab, or clean up by
  hand.
- The last manual run, and a cleanup job not finished yet (read from
  `oban_jobs`, so a job stuck in `executing` on a host without Lifeline
  shows instead of only refusing the next run).
- A period stored without the time it was set (edited by hand) is read as
  "keep forever"; the line names the stored period, and the form shows it,
  so saving the form as it is applies that period (through the preview, as
  any first finite period) — or change it before saving.

Once rows may have been deleted, the totals on the Endpoints and Usage tabs
say "For the retained period, since <date>", and a request whose content was
cleared says so in its details.

## What stays after the content is cleared

- `error_message` on a failed call: the error's text plus the provider's
  answer, cut and masked; for a content-policy refusal that is the
  provider's text, which can paraphrase the request. It goes only with the
  row, by the journal entries' period.
- The reasons and lift notes of blocks (`phoenix_kit_ai_guard_blocks`),
  written by people; no period covers them.

## Before the first period on a large journal

- **Back up first**, and look at the preview — ideally on a copy of
  production — before saving the first finite period or running the first
  manual cleanup.
- **Deleting does not shrink the files.** Deleted rows and cleared content
  leave dead tuples; autovacuum makes the space reusable, it does not give
  it back to the disk. The module never runs `VACUUM`.
- **The first run writes a lot of WAL**: replicas lag, WAL archives and
  incremental backups grow, the disk must hold it. The 1 000 000-row cap
  and the time slices spread a large backlog over several nights; lower
  `max_rows` or the slices to spread it further.

## A block set from an event being deleted

Each chunk runs in `READ COMMITTED` and sees the blocks committed before its
statement began. A block set from an old flag at the very moment a chunk
deletes that flag is not seen by it: the event goes, and the block's
`origin_event_uuid` is set to `NULL` by its foreign key — the block itself,
with its own reason, stands. If the event goes between the block reading it
and writing itself, setting the block fails on that foreign key and can
simply be done again (then without a link to the flag). Clearing
off-purpose reasons races the same way: the flag a block was just set from
can lose its reason, while the block keeps its own. Only events older than
the boundary are exposed, and the guard-events boundary never reaches into
the current month.
