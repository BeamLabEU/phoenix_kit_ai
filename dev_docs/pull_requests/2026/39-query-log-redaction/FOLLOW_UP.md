# FOLLOW_UP — PR #39 (Keep usage rows, endpoint api keys and prompt texts out of the query log)

Triaged 2026-10-21. `CLAUDE_REVIEW.md` found no bugs and two nitpicks.

## Not changed

- **NITPICK:** `log: false` does not suppress the repo's query telemetry event;
  that belongs to the host.
- **NITPICK:** no conformance check that future writes carry the flag; the
  behavioural test covers current sites.
