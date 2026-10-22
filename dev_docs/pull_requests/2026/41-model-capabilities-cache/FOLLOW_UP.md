# FOLLOW_UP — PR #41 (Model capabilities cache)

Triaged 2026-10-22. `CLAUDE_REVIEW.md` found no bugs, one improvement and two
nitpicks.

## Not changed

- **IMPROVEMENT - MEDIUM:** the cache refreshes while the module is off. Needs a
  decision on whether `enabled?/0` should gate the refresh (a re-enable would
  then start cold).
- **NITPICK:** `lookup/2` and the refresh pick "has a catalogue" by different
  rules (host only vs provider key and host).
- **NITPICK:** every miss casts to the GenServer.
