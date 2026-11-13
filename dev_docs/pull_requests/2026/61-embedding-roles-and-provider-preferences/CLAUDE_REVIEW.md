# Claude Review — PR #61

**Reviewer:** Claude Opus 5.5, with the external panel (codex GPT-6.1, zai GLM-5.3, vibe Mistral Medium 3.5)
**PR:** Embedding roles, `embed_many`, `translate_query` and OpenRouter provider preferences (mdon)
**Reviewed:** 2026-11-13, on the branch rebased onto `upstream/main` `b56217a`

## Overall Assessment

**APPROVE after the fixes below.** Risk: **Low**. Everything is opt-in: without the new
options an embedding or chat call sends what it sent before. The cache key keeps a query
vector from answering for a document. The role is in it, and so are the resolved
`input_type`, the instruction and `normalize`, and the templated text is part of the
input; a saved endpoint edit moves `updated_at`, which is in every key. The family table
classifies the real OpenRouter ids correctly. `provider_preferences/2` never raises, and
the guard's `require_parameters` always wins. Batching neither drops nor duplicates an
input, and a batch of more than one input never exceeds the token budget. The defects
were all on edges where a provider answers something unusual, and each was reproduced
before it was fixed.

## Findings

### BUG - MEDIUM — a base64 vector with a NaN or infinity came back shorter (fixed)

`Completion.decode_base64_item/1` decoded with `for <<x::float-32-little <- bytes>>`.
The BEAM has no NaN or infinity float, and a binary generator skips a segment that does
not match, so `<<1.0, NaN, 2.0>>` decoded to `[1.0, 2.0]`. That is a vector of the wrong
dimension, stored as if it were right (reproduced). An undecodable string, or one whose
size is not a multiple of 4, was handed to the caller as the raw string. Both now make the
answer `{:error, :invalid_response_format}`.

### BUG - MEDIUM — `normalize: true` could raise after the paid call (fixed)

`EmbeddingConventions.normalize/1` squared the raw values: `1.0e308` overflows
(`ArithmeticError`), and so does an integer past float range. It runs in `run_embed`
after the provider has answered. It now scales by the largest magnitude first and returns
the vector as it is when even that cannot be done.

### BUG - LOW — `embed_many/3` renumbered vectors when a part answered fewer (fixed)

`merge_embedding_parts/1` sorted by the provider's index, then renumbered from the part's
offset, so a part answering only its second input's vector put that vector at the first
input's index. Each vector's index is now the part's offset plus the provider's own index.

### BUG - LOW — an instruction containing `{text}` got the query inserted into it (fixed)

`apply_template/3` substituted `{instruction}` and then every `{text}`. It now fills both
in one pass.

### BUG - LOW — `translate_query/3`'s length guard measured the padded query (fixed)

With a query of 1 000 spaces and one word, the guard allowed a 4 104-character answer,
not 104. It now measures the trimmed query, the one that was sent.

### IMPROVEMENT - MEDIUM — the live embedding-model list could be asked on every call (fixed)

When the fetch raised, the `rescue` returned the fallback without writing the 60 s retry
entry, and an `exit` (a pool timeout) escaped `fetch_embedding_models/2`, which promises
never to fail. Both now write the fallback entry. A listed field of an unexpected type
(a numeric `name`, a string `pricing`) is taken from the curated entry, so the list keeps
one shape.

### NITPICK — quotes around a translation (fixed)

Curly, low-9 and CJK quotes were not taken off. Only a matched pair around the whole
answer is taken off now: the old trim of `'` also ate the apostrophe in `'tis` or
`'s-Hertogenbosch`.

### Not a defect in this PR

- `test/phoenix_kit_ai/vision_robustness_test.exs` failed once in the full suite. Its
  rows are ordered by `inserted_at`, which has one-second precision. The failure is
  pre-existing and unrelated to this PR; the uuid (UUIDv7) is now the tie-break.
- A caller-supplied `cache: [key: …]` with a template changed on the endpoint (codex):
  does not reproduce, because the key includes the endpoint's `updated_at`.

## Open, for the maintainer

- `mix precommit` stops at `hex.audit` on `upstream/main` too: `grpc_core 1.0.5`,
  EEF-CVE-2026-121808 (HIGH), reached through `xai`. This PR does not touch `mix.lock`.
- With a caller key, `dimensions:` is not part of the key (it predates this PR). One key
  reused with two sizes returns the first size. Adding it would invalidate every existing
  caller-keyed embedding entry once.
- `provider: [only: 'deepinfra']` (a charlist) is sent as a list of code points. That
  is the caller's error, and it is not guarded against.
- `embed_many(max_concurrency: n > 1)` writes each part's row with the task's
  stacktrace; `source` is carried over from the caller.
