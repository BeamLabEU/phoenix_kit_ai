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
