# Claude Review — PR #3

**Reviewer:** Claude Opus 5.5
**PR:** Migrate API key management to centralized PhoenixKit.Integrations (mdon)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `7a2184a`

## Overall Assessment

**APPROVE.** Risk: **Low**. No open finding. Most of this code has since been
rewritten, and the Pincer and Mistral findings are resolved in `FOLLOW_UP.md`.

## Findings

None open. Checked against current `main`:

- **`build_headers/2` with a nil key** sends a request with no `Authorization`. The
  verbs do not reach it that way: `lib/phoenix_kit_ai.ex:5973` answers
  `{:error, :integration_not_configured}` first. It stays as a logged last resort.
- **Dropping `validate_inclusion(:provider, ...)`** is still deliberate; legacy rows
  hold uuids, and `AGENTS.md` says so.
- **Resolution order** is now `integration_uuid`, legacy `provider`, then the
  `api_key` column (`openrouter_client.ex:588`), warning only at the last.

## Positive Observations

- Keeping the column as a fallback let installs move on their own schedule.

**Verdict:** APPROVE.
