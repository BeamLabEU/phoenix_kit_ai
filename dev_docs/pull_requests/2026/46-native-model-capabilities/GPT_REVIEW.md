# GPT review — PR #46

Reviewed 2026-10-22 by Codex against main `0f3f879`, including the merge with #48.
Author: @timujinne. [PR #46](https://github.com/BeamLabEU/phoenix_kit_ai/pull/46).

## BUG - MEDIUM — model filters ignore native capability fields (fixed)

Capability parsing understood Mistral's `completion_chat` and `vision` fields,
DeepSeek's native modalities, and Anthropic's native image-input capability.
Model filtering still ran first against OpenRouter's `architecture` alone.
Consequently Mistral embeddings appeared in the chat picker, native vision models
disappeared from `model_type: :vision`, and native image outputs were not reliably
available in the image-generation picker.

Filtering now uses parsed capabilities and native output modalities, retaining
heuristics when the catalogue does not say. Explicit text-only output filtering,
TTS exclusions, and xAI's image-model fallback remain covered. A known native
chat capability also takes precedence over an image-like name. Tests cover
Mistral chat/vision filtering, DeepSeek chat/vision/image filtering, Anthropic
vision filtering, and OpenRouter's mixed audio/text output exclusion.

## Checks

Rechecked catalogue selection, snapshot persistence and fallback, Anthropic paging
and headers, sampling/version parsing, thinking-form selection and budget bounds,
document/image requirements at the guard, recommendation grouping/pricing,
stateful filters, and endpoint-create links after merge conflict resolution.
No provider calls were made during validation; model catalogues use Req.Test.

## Validation

The new native-filter tests failed before the repair. Final test and gate results
are recorded in [the combined recheck](../../../reviews/2026-10-22-merged-pr-recheck.md).
