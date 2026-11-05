# PR #60 follow-up

Claude review completed on 2026-11-05; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** `:budget_month_cache_ttl` added to `AGENTS.md`'s config table;
  `budget_refused/4`'s `@doc` corrected.
- **Open, for the maintainer:** a monthly cap raised and reached again the same month
  sends no event or notice. Recorded as deliberate in the guide, so left unchanged.
