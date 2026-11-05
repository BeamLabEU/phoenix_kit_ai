# PR #60 — Add a site-wide monthly spend cap (`ai_monthly_cap`)

**Author:** timujinne · **Merged:** 2026-11-05 · **Merge commit:** `b6071be`

## What

A fifth `PhoenixKitAI.Budget` scope, `:global_month`: every call the module makes,
summed from the local midnight that starts the current month in the site time zone.
It is calendar, not rolling, and sits beside the daily caps ("$8 a day, $100 a
month"); whichever is reached first refuses with
`{:error, {:budget_exceeded, :global_month}}`.

## How

- The window is the month window of `TaskLimits.windows/2`, which now takes the zone
  so a caller reads it once.
- A month of rows is too much to scan per call, so the sum is cached in the flags
  table: 30 s (`:budget_month_cache_ttl`), 2 s from 90% of the cap up to the cap.
- A failed scan is never stored. The last good sum of the month is served, calls do
  not scan again for 5 s, and a sum 10 minutes old is logged again every 10 minutes.
- A scan with an earlier sum to serve leaves a 5 s lease, so a slow scan is not
  repeated by every caller.
- The guard event's window is the local month, and `VisionBatch` stops a batch on the
  cap whoever its items are for.

See [the guide](../../../guides/spend-caps-and-caching.md).
