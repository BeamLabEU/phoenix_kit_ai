# PR #65 follow-up

Claude review completed on 2026-11-15; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** "Or enter a model ID the list does not show" extracted into the catalogues and translated in all
  seven non-English languages (it rendered in English everywhere).
- **Fixed:** `tool_choice: "none"` on Converse leaves the call's tools out instead of offering them all; a tool
  round in the history still declares the tools it called. Test, moduledoc and AGENTS.md updated.
- **Open, waiting on a live check:** an empty tool result goes out as `{"text": ""}`, which Converse probably
  refuses; the accepted substitute is not confirmed.
- **Open, for the maintainer:** `mix gettext.extract --check-up-to-date` in `precommit` would catch a missing
  msgid, but it also fails on line shifts in the reference comments.
- **Not changed:** the OpenRouter-shaped placeholder of the manual model-ID entry; unmapped Converse cache token
  counts (always 0 while no `cachePoint` is sent).
