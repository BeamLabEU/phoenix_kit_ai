# FOLLOW_UP — PR #30 (Add a terminology glossary to AI translation prompts)

Triaged 2026-09-23.

`CLAUDE_REVIEW.md` found:
- no bugs
- two Medium improvements
- three nitpicks

Ships in 0.23.2.

## Resolved

- **IMPROVEMENT - MEDIUM:** the glossary is silently inert on existing installs.
  - Documented in AGENTS.md and in the CHANGELOG upgrade note.
  - No runtime detection yet (see the review for the trigger).
- **IMPROVEMENT - MEDIUM:** settings keys and reserved variables were undocumented.
  - AGENTS.md updated.
- Added an end-to-end render test of the shipped template in
  `translation_glossary_prompt_test.exs`.

## Not changed

- **NITPICK:** no `de-DE` → `de` fallback. This would be a contract change, so
  it waits for a host that needs it.
- **NITPICK:** the settings reads are uncached, the same as the sibling
  endpoint and prompt keys.
- **NITPICK:** an empty slot leaves an extra blank paragraph. Harmless.
