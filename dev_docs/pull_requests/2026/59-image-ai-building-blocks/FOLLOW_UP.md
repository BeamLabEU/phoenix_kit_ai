# PR #59 follow-up — 2026-10-29

All five findings in [GPT_REVIEW.md](GPT_REVIEW.md) are resolved:

- Strip argument values from batch exception stacktraces before logging.
- Return zero `"cost"` for cached embeddings, with or without a hit row.
- Enforce the combined inline-image limit for multimodal embeddings.
- Consume failed-confirmation costs once while preserving earlier fallback costs.
- Evaluate fatal refusals across the batch's item overrides, including fallback models.

Six regression tests exercise the fixes through the public verbs and actual
request journal using Req.Test stubs.
