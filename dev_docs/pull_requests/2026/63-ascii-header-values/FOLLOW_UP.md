# PR #63 follow-up

Claude review completed on 2026-11-13; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** tests for a title with CR/LF inside (sent as one encoded value) and a whitespace-only title or referer
  (no header).
- **Open, for the maintainer:** the `site_url` / `project_title` fallback sends `HTTP-Referer` / `X-Title` to every
  provider, not only OpenRouter (pre-existing).
- **Not changed:** OpenRouter shows a non-ASCII title percent-encoded; an endpoint's own ASCII `x_title` override
  avoids it.
