# FOLLOW_UP — PR #31 (Refuse a translation response with marker lines nobody asked for)

Triaged 2026-09-24.

`CLAUDE_REVIEW.md` found:
- one high-severity bug
- three nitpicks

Ships in 0.24.1.

## Resolved

- **BUG - HIGH:** content with its own marker-shaped lines
  (`----- Original Message -----`) was rejected on every attempt.
  - `parse_response/3` now takes `sources:`, and `handle_ai_response/2`
    passes the source fields.
  - The response may carry as many read-past (`:line`-kind) marker lines as
    the sources do.
  - Tests are in `translation_markdown_sections_test.exs`.

## Not changed

- **NITPICK:** a boundary-shaped line in the source still fails all three
  attempts. The case is rare, and it is better than persisting a truncated
  field.
- **NITPICK:** the `unexpected_markers` names reach the logs and Oban errors,
  the same exposure as the existing reasons.
- **NITPICK:** `placeholder_echo` is heuristic by design.
