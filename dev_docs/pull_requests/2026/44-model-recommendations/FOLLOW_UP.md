# FOLLOW_UP — PR #44 (Model recommendations)

Triaged 2026-10-22. `CLAUDE_REVIEW.md` found no bugs and three nitpicks.

## Not changed

- **NITPICK:** "Already worked" lists a model with only failed calls (its
  error share shows it).
- **NITPICK:** for ~10 s after a restart the panel shows unpriced rows from the
  snapshot instead of an empty list.
- **NITPICK:** the picker queries on every render unless `recommendations` is
  passed; documented, not enforced.
