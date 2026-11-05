# Claude Review — PR #60

**Reviewer:** Claude Opus 5.5
**PR:** Add a site-wide monthly spend cap (`ai_monthly_cap`) (timujinne)
**Reviewed:** 2026-11-05
**Merge commit:** `b6071be`

## Overall Assessment

**APPROVE.** Risk: **Low**. No defect found in the cap itself. The cache is the part
of this PR most likely to be wrong, and it holds up: the failure, lease and backoff
paths were each traced by hand against `lib/phoenix_kit_ai/budget.ex`, and the 45
tests in this PR's two new files pin them. Two documentation items were fixed; one behaviour is
left as the author recorded it, with a question for the maintainer.

## Findings

### NITPICK — `:budget_month_cache_ttl` was missing from the config table (fixed)

`AGENTS.md`'s "Application env" table is where this repo lists its config keys. The
new key was documented only in `dev_docs/guides/spend-caps-and-caching.md`. Added.

### NITPICK — `budget_refused/4`'s `@doc` contradicted the guide (fixed)

`lib/phoenix_kit_ai/guard_events.ex:361` said the monthly cap "only lifts when the
month turns". It also lifts when the cap is raised, as the notification text says
(`guard_events.ex:755`) and the guide says. The `@doc` now matches.

### IMPROVEMENT - MEDIUM — a raised cap reached again that month is silent (not changed)

`dedupe_key` for the monthly refusal is `limit_reached:budget:global_month:-:<month>`
(`guard_events.ex:386`). An operator who raises a reached cap on the 10th hears
nothing when the site reaches the new cap on the 20th: calls stop, the journal shows
refusals, and no event or notification follows until the next month. The daily caps
have the same shape, but there the silence ends within a day.

Left alone because it is a recorded decision, not an oversight: the guide says
"That holds even when the cap is raised and reached again in the same month: the
later refusals are refusals as ever, but not a new event or notice", and
`budget_monthly_test.exs:289` pins the key. If it should change, the shape already
exists: forgiving a task limit puts the new count's start in the key so its signals
can fire again (`guard_events.ex` moduledoc). The cap amount in this key would do the
same in about three lines.

### Checked, no finding

- **Every list of scopes knows `:global_month`:** `Errors.message/1`
  (`errors.ex:176`), `budget_scope/1`, `budget_text/2`, `VisionBatch.account_wide?/1`
  (`vision_batch.ex:586`), `TranslateWorker`'s classifier (a wildcard on the scope),
  and `retryable?/1` (not retried, correctly).
- **A bad `time_zone` cannot raise out of the unguarded window computation**
  (`budget.ex:605`): core's `local_date/2` and `date_start/2` read an unresolvable
  zone as UTC.
- **`NaN` and `Infinity`** are refused by `Money.to_decimal/1` before they reach
  `Decimal.compare/2`, which would have raised on every call.
- **Monotonic time can be negative;** the code only ever subtracts and compares.
- **Retention cannot shrink the sum:** the floor keeps every row from two days before
  the month began.
- **Translations:** the three new msgids have `et` and `ru` strings; the rest of the
  `.po` churn is line references.

## Positive Observations

- `scanned_at` is the instant the scan began, so the age of a sum is never
  understated (`budget.ex:589`).
- The 90% zone is tied to the cap and not to `ai_budget_warn_percent`, so turning the
  warning down cannot widen the overshoot.
- A failed scan is never written as a sum. Caching a zero there would have read as
  "nothing spent" for 30 seconds after every blip.
- Keying the entry by month start makes a new month and a changed time zone correct
  with no invalidation at all.
- The month's sum reuses `money/4` rather than a query of its own, so this long scan
  keeps the literal `"success"` that V193's partial indexes need.

## Summary

| | |
|---|---|
| Code quality | Very good |
| Architecture | Fits; one more scope, the cache kept inside `Budget` |
| Security | No user text in any new log line or event |
| Performance | Month scan bounded by the cache and the lease |
| Test coverage | Very good: 45 tests in two new files, failure paths included |
| Migration safety | No migration; the new key has no legacy form |
| Consistency | Good; two documentation gaps, both fixed |

**Verdict:** APPROVE.
