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

## GPT recheck — 2026-10-22

Legacy `provider:connection` names now retain catalogue detection at custom base URLs; covered for OpenRouter and Anthropic.

See [GPT_REVIEW.md](GPT_REVIEW.md) for evidence, regression coverage and the
remaining design tradeoffs. This section supersedes the corresponding earlier
“Not changed” entries; Claude's review is preserved.
