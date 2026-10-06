# FOLLOW_UP — PR #35 (Fix legacy api_key migration marker being rewritten)

Triaged 2026-10-06.

`CLAUDE_REVIEW.md` found no bugs, one nitpick and one limitation.

Ships in 0.25.3.

## Resolved

- **NITPICK:** the `run_legacy_api_key_migration/0` docs said the `api_key`
  column is never cleared. Reworded: it is cleared to `""` in the same `UPDATE`
  that sets `provider` and `integration_uuid`.

## Not changed

- **LIMITATION:** the marker is written even when every group was skipped, so
  those endpoints are not retried by the auto-migrator. Same as before the PR;
  they keep working through the `api_key` column fallback. Recovery is deleting
  the marker setting.
