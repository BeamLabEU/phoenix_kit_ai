# Claude Maintainer Review — PR #61

**Reviewer:** Claude Fable 5.2 (maintainer-side sweep, independent of the contributor's
[CLAUDE_REVIEW.md](CLAUDE_REVIEW.md))
**PR:** Embedding roles, `embed_many`, `translate_query` and OpenRouter provider preferences (mdon)
**Reviewed:** 2026-11-14, on the PR head `02af792` merged with `main` `e508b50`

## Overall Assessment

**APPROVE with the fixes below.** The opt-in claim holds: without a new option, request
bodies and automatic cache keys are what they were (the one exception, `mistral-embed` no
longer getting `dimensions`, was a 422 before). Role, `input_type`, instruction and
`normalize` are in both key forms. Non-OpenRouter endpoints cannot receive `provider`.
One real defect was left: a caller cache key on `embed_many/3`.

Suite on the merged tree before the fixes: 7 doctests, 2,669 tests, 0 failures.

## Findings

### BUG - HIGH — `embed_many/3` with `cache: [key: …]` answered every part with the first part's vectors (fixed)

Every part went through `embed/3` with the same options, and a caller key replaces the
input in the cache key, so all parts shared one entry.
`embed_many(ep, ~w(1 2 3 4), batch_size: 2, cache: [key: "doc:1"])` returned the vectors
of inputs 1 and 2 twice, as `{:ok, …}`: wrong vectors stored against documents, for any
list over the model's limit (96 or 100 inputs). With more than one part, each part is now
cached under the key plus its place in the list (first index and length, so another
`batch_size:` under the same key is another entry). A list that fits one request keeps the
bare key and stays interchangeable with `embed/3`.

### BUG - LOW — a part that raised under `max_concurrency > 1` took the caller down (fixed)

`Task.async_stream` links its tasks, so the `{:exit, reason}` clause was reachable only for
a caller that traps exits; any other caller was killed, past its own `rescue`. The task
body now turns a raise, throw or exit into `{:error, {:embedding_batch_exit, reason}}`, and
`Errors.message/1` has a clause for it (the reason can carry a stacktrace, so the message
leaves it out). The `@doc` now says that parts still in flight when one fails are stopped
and not cached.

### BUG - LOW — `provider:` as a struct raised, against "a preference never fails the call" (fixed)

`json_preferences/2` guarded on `is_map/1`, which a struct passes: a `Date` raised
`Protocol.UndefinedError`, a `Range` or `MapSet` `FunctionClauseError`, before any row was
written. A struct is now ignored with the same warning as any other non-map.

### NITPICK — `role: :query` and `role: "query"` were cached apart (fixed)

The raw option went into the key. The resolved role is put back into the options before
keying; atom callers keep their entries.

### NITPICK — `role:` leaves an image's caption untemplated (documented)

`embed(ep, [{:image, url, "a caption"}], role: :query)` sends the caption as given while
`"convention"` reports the role. The prefixes are documented by the providers for text
inputs only and were not tried on captions, so the behaviour stays and the `@doc` says so.

## Not changed, on record

- `translate_query/3` returns the query untranslated on any failure and logs nothing; a
  model that refuses `temperature: 0`, or spends the small `max_tokens` on reasoning, would
  fail on every call without a trace. Not reproduced against a live model.
- `fetch_embedding_models/2` has no single-flight: concurrent callers on expiry each fetch
  and each write `:persistent_term`. Nothing in `lib/` calls it on a hot path.
- `embed_many`'s `"cost"` sums only parts with a known price; `"usage"` counts a cache-hit
  part's original tokens while its cost is 0.
- `test/phoenix_kit_ai/oban_prefix_test.exs:199` failed once in a full run after these
  changes and passes alone (3 of 3): it reads a global Oban instance another test leaves
  running. Pre-existing, unrelated to this PR.
