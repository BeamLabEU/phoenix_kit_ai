# PR #59 — Image-AI building blocks

Author: @mdon · Merged: 2026-10-29 · Merge: `b7087e6`

[GitHub PR](https://github.com/BeamLabEU/phoenix_kit_ai/pull/59)

Adds multimodal embeddings, located image regions, OCR boxes, statement
checks with optional confirmation, model fallbacks, grouped vision batches,
and run/step totals from the usage journal. These reuse the existing endpoint,
guard, cache and request-log paths. No schema migration is introduced.

Implementation and caller examples: [image-processing guide](../../../guides/image-processing.md).

- [GPT review](GPT_REVIEW.md)
- [Finding resolutions](FOLLOW_UP.md)
