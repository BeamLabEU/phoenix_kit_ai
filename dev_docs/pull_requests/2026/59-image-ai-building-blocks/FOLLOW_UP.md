# PR #59 follow-up — 2026-10-29

All five findings in [GPT_REVIEW.md](GPT_REVIEW.md) are resolved:

- Strip argument values from batch exception stacktraces before logging.
- Return zero `"cost"` for cached embeddings, with or without a hit row.
- Enforce the combined inline-image limit for multimodal embeddings.
- Consume failed-confirmation costs once while preserving earlier fallback costs.
- Evaluate fatal refusals across the batch's item overrides, including fallback models.

Six regression tests exercise the fixes through the public verbs and actual
request journal using Req.Test stubs.

## Claude review — 2026-11-05

See [the review](CLAUDE_REVIEW.md); regressions in `test/phoenix_kit_ai/vision_answer_shapes_test.exs`.

- **Fixed:** a JSON array no longer raises out of a verb; an object without `regions` is
  unparsed; a content filter and an empty answer are errors with their row; a refused
  fallback no longer stops a batch (the earlier fix covered item-level options only);
  a group's bad input fails one item; 0-based numbering; `qwen-2.5-vl`; delivery
  options on the vision verbs; statement texts in a caller's cache key; `question:` in
  a group.
- **Not changed:** a safety refusal of a grouped call fails its neighbours (re-asking
  costs money, and `group:` is opt-in); `box_format:` applies to fallbacks (documented
  precedence); five nitpicks, listed in the review.
- **Corrected 2026-11-05:** reading any 0 as counting from 0 also moved a right numbering
  that had an extra entry numbered 0. A number that reaches the count now means the model
  counts from 1 (`Regions.counts_from_zero?/2`, shared by groups and statements).
