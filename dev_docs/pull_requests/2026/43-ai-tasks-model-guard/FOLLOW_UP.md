# FOLLOW_UP — PR #43 (AI tasks and the model check)

Triaged 2026-10-22. `CLAUDE_REVIEW.md` found no bugs, one improvement and one
nitpick. The translation-failure classification gap that the new refusals
opened is fixed under PR #45.

## Not changed

- **IMPROVEMENT - MEDIUM:** one synchronous usage row per refused call; a
  public caller past a cap turns each request into an `INSERT`. Needs a journal
  design change (aggregate or rate-limit refusal rows).
- **NITPICK:** the 404 → `{:no_provider_for_params, []}` rule is shared with
  callers that never send `require_parameters`; it cannot fire there.

## GPT recheck — 2026-10-22

Removed callback/provider payloads from new failure logs, corrected cached-row model identity, and aligned the test router with both production route callbacks.

See [GPT_REVIEW.md](GPT_REVIEW.md) for evidence, regression coverage and the
remaining design tradeoffs. This section supersedes the corresponding earlier
“Not changed” entries; Claude's review is preserved.
