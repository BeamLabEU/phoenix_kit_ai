# Claude Review — PR #59

**Reviewer:** Claude Opus 5.5
**PR:** Image-AI building blocks: embeddings, regions, statement checks, batches, fallbacks (mdon)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `b7087e6`

## Notes for the reviewer

A delegated read of the diff produced the candidates. Each finding below was then
checked against the code, and everything marked **Reproduced** failed a test on the
unfixed code first (`test/phoenix_kit_ai/vision_answer_shapes_test.exs`). None of
this overlaps `GPT_REVIEW.md`, except where noted that a fix recorded there was
incomplete.

## Overall Assessment

**APPROVE with reservations.** Risk: **Medium**. The structure is good: one box type,
the format chosen by the model that answered, and located verbs that reuse
`describe_image/3` instead of copying its gate. The defects sit where a model answers
in a shape nobody planned for, and one of them turned a paid call into a raise.

## Findings

### BUG - HIGH — a JSON array raised out of three verbs after the call was paid (fixed)

`StructuredOutput.parse/2` accepts lists, and lifts `[...]` out of prose. `with_regions`,
`extract_text` and `detect_regions` then read `json["regions"]`, and `Access` raises
`ArgumentError` on a list with a string key. `compare/4` guarded this exact case; its
siblings did not.

The raise comes before the usage row, so the money reached no row, no cap saw it, and
`fallback_models:` never ran. A prose answer as plain as `No text found [0]` was enough
for `extract_text/3`. **Reproduced.**

**Fix:** an internal `:json_object` option says what a verb reads by key
(`images.ex:811`). Another shape is `{:no_json_in_response, _}`, with its row, its
fallback and `:unparsed` in a batch. A caller's own `json: true` still gets an array.

### BUG - MEDIUM — an object without a `regions` list read as "nothing found" (fixed)

`parse_regions(_other, ...)` answers `{[], 0}`, the same as a valid empty answer, so
`{"objects":[...]}` or `{"regions":null}` was a cached success with no fallback.
**Reproduced.** Fixed by the same option: `"regions"` names the list required.

### BUG - MEDIUM — a 200 with no usable answer was a success (fixed)

`safety_errors:` covers 400/403/422 only. `finish_reason: "content_filter"` with null
content gave `{:ok, %{text: nil}}`: a success row, a cached answer, no fallback, and a
batch item `:ok`. Text a filter cut short passed as complete. **Reproduced.**

**Fix:** `Completion.filtered?/1` makes it `{:content_policy, _}`, with a fixed text
rather than the cut-off answer, and blank text is the new `:empty_response`
(`images.ex:780`). Both are billed, so both reach `:on_no_json`, and
`Images.billed_answer?/1` keeps the verb's error branch from writing a second,
zero-cost row. That predicate replaces the clause that listed only the two JSON tags.

### BUG - MEDIUM — a refused fallback model stopped the whole batch (fixed)

`try_models` returned the last attempt's error, and `VisionBatch.fatal?/2` took it as a
refusal every later item would hit. One safety-blocked image with a retired fallback
stopped the batch, every remaining item came back `:skipped` though they worked on the
primary model, and the real reason was lost. **Reproduced.** The fix recorded in
`FOLLOW_UP.md` covered item-level `fallback_models:` only.

**Fix:** a fallback that is itself refused (`:model_not_found`, `{:model_unfit, _}`,
`{:model_unverified, _}`) moves on, and with none left the verb returns the first
model's error (`lib/phoenix_kit_ai.ex:3400`). A cap reached on the attempt still wins.

### BUG - MEDIUM — one bad input failed every item of its group (fixed)

`units/3` only sums bytes, so one unreadable image, unsafe URL or oversized image
refused the whole grouped call, against the moduledoc's "one bad image never fails the
batch". An item with `images: []` was packed too and came back `:ok` with someone
else's answer. **Reproduced.**

**Fix:** a group refused on its input runs its items alone (`vision_batch.ex:233`).
That refusal comes before any provider call, so it costs nothing and writes no row.
Items with no images are not packed (`vision_batch.ex:281`).

**Not changed:** a safety refusal of a grouped call still fails its neighbours. Asking
each alone means paying again, which is the caller's decision (`group:` is opt-in).

### BUG - MEDIUM — a model counting from 0 could put answers on the wrong item (fixed)

The 0-based shift applied only to keys exactly `0..n-1`, so `[0, 1]` for three items
dropped the first answer and moved the second onto item 1 with status `:ok`.
`parse_statements/5` had no shift at all. **Reproduced.** Both now read any 0 as 0-based
(`vision_batch.ex:383`, `regions.ex:336`): numbers start at 1, so a 0 means nothing else.

### BUG - MEDIUM — Qwen's dashed id missed the box table (fixed)

`qwen/qwen-2.5-vl-7b-instruct` matched no prefix, so its boxes would read y-first and
come back transposed. **Reproduced** for the table; that OpenRouter serves this exact
id comes from memory. Harmless either way: `box.ex:53` gains one prefix of a family
already listed. `qwen-2-vl` was not added, as nothing here says how that family writes.

### IMPROVEMENT - MEDIUM — `timeout:`, `retry:` and `concurrency:` never reached a vision call (fixed)

Both allow-lists left them out, while `cacheable/1` dropped them from the key as
delivery options. `timeout: 300_000` still died at 120 s and `concurrency: false` did
nothing, though `transcribe/3`'s doc says "as on every verb". **Reproduced.** Added at
`images.ex:632`, in `compare/4` and in the adapter.

### IMPROVEMENT - MEDIUM — a caller's cache key served verdicts for other statements (fixed)

Statements travel only in the prompt and the schema is constant, so
`check_statements(..., cache: [key: "listing-1"])` after an edit hit the old answer,
and `parse_statements/5` pinned its verdicts by number onto the new texts: misattributed
rather than merely stale. **Reproduced.** The texts are now key material
(`lib/phoenix_kit_ai.ex:3819`), as `images_as:` already was. Same statements still hit.

### IMPROVEMENT - MEDIUM — a call's `box_format:` also applies to the fallback (not changed)

With `box_format: :xy_1000` and a fallback that writes y-first, the fallback's boxes come
back transposed. Left alone: `Box.format_for/2` documents the call's option as winning,
and the fix (per-model formats) is a new option, not a repair.

### NITPICK — `question:` was ignored in a group (fixed)

`group_opts/3` read only `:prompt`, so grouped items got the default question.
**Reproduced.**

### NITPICKS — not changed

- `:api_key_forbidden` in the fatal list never fires from a verb; a plain 403 is
  `{:api_error, 403}`, so such a key does not stop a batch.
- `regions:` with an atom-keyed caller schema builds a mixed-key map.
- `merge_confirmation` drops the second check's `:fallbacks`; `cost` and the journal
  still count it.
- An unconfirmed `:insufficient` keeps `image` and `box`, where the doc says nil.
- Mistral's `model_length` may be a truncation reason. From memory, so unconfirmed.

## Positive Observations

- `Box` gives one coordinate type, and the format comes from the model that answered,
  including on a fallback and on a cache hit.
- Located verbs reuse `describe_image/3`, so gate, cache, row and cost are shared.
- Unparsed and cut-off answers keep their billed row, and that cost reaches the batch
  budget across fallback attempts.
- Logs carry tags rather than provider text.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Very good |
| Security | Good; bytes never reach a row |
| Test coverage | Good on grouped answers; thin on unplanned answer shapes, now covered |
| Consistency | Good; `compare/4` had the guard its siblings lacked |

**Verdict:** APPROVE with reservations; the bugs above are fixed.
