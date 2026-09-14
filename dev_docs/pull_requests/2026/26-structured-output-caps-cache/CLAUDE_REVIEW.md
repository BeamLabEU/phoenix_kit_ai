# Claude Review — PR #26

**Reviewer:** Claude Opus 5
**PR:** Structured output, spend caps, request cache, host translatables, extract_text/3, quality sweep (+ reorder audit fix)
**Author:** Max Don (`mdon/main`)
**Merge commit:** `71e793d`
**Reviewed:** 2026-09-14
**Verdict:** APPROVE with reservations. Two Medium bugs and one Medium improvement fixed on main with regression tests; nitpicks on record.

---

## Notes for the reviewer

- Every new module (`budget.ex`, `request_cache.ex`, `structured_output.ex`)
  was read in full, and so was the modified code in `phoenix_kit_ai.ex`,
  `images.ex`, `translatables.ex` and `providers/openai_compatible.ex`,
  with its surrounding context. Also read: the new guide
  `dev_docs/guides/spend-caps-and-caching.md`.
- No live provider was called. All provider behaviour is `Req.Test` stubs.
- The spend caps are a brake, not an invoice ceiling: no reservation, and
  they fail open. The PR says so itself, in the moduledoc and the guide. So
  the findings below are about the brake **not engaging when it should**, not
  about overshoot under concurrency.

## Overall assessment

The design is sound and consistent.
- **One gate.** Every verb goes through `authorize/2` (now `/3`).
- **One cache wrapper.** `with_cache/6` handles key, lookup and the zero-cost
  hit row.
- **Parse inside the closure.** Structured output is parsed inside the cached
  closure, so a prose answer is never stored as a success.
- **Lazy key.** The key is built only when caching is on, so image bytes are
  not hashed for nothing.
- **Tag-only telemetry.** It never carries content, and the `on_hit`
  callback is stripped from event metadata.

The two real defects are both about the budget losing sight of spend. A
stray option skipped the cap on verbs that do not honour it. A paid vision
call left no costed row.

**Risk level:** Medium before the fixes (caps that silently fail to count
or apply); Low after.

---

## Critical issues

None.

## High severity

None.

## Medium

### BUG - MEDIUM — `dry_run:` lifted the spend cap on every verb *(fixed on main)*

`authorize/2` (`lib/phoenix_kit_ai.ex:3683`) skipped `Budget.check/2`
whenever `opts[:dry_run]` was truthy:

```elixir
:ok <- if(opts[:dry_run], do: :ok, else: Budget.check(endpoint, opts))
```

`authorize/2` runs for all nine verbs. Only `process_image/4` honours
`dry_run:`; `Images.process/4` is the one reader (`images.ex:319`).
`complete/3`, `ask/3`, `embed/3`, `speak/3`, `generate_image/3`,
`edit_image/4` and the vision verbs ignore the option: they call the
provider, log the cost, and would even cache the answer.

So `ask(ep, "…", dry_run: true)` on a site past its daily cap went
straight to the provider. That can happen through a shared option list, or
a caller copying `process_image/4`'s options.

The caps are documented as a stop switch ("a runaway site goes quiet").
Here, one keyword turned the switch off without a trace.

**Fix.** `authorize(endpoint, opts, spends? \\ true)`. Only `process_image/4`
passes `!Keyword.get(opts, :dry_run, false)`
(`lib/phoenix_kit_ai.ex:3216`), matching how `Images.process/4` reads it.

**Tests.**
- `budget_cache_test.exs:109` "dry_run: does not lift the cap on a verb that
  ignores it" fails without the fix.
- `images_test.exs:969` now also asserts that a `process_image/4` dry run
  still passes at a spent cap.

The guide and AGENTS.md said "dry runs skip the check". They now name
`process_image/4`.

### BUG - MEDIUM — A prose answer to a JSON vision request lost its cost *(fixed on main)*

`Images.describe/3` returned `{:error, {:no_json_in_response, text}}` from
inside a `with` whenever the parse failed. The provider response, and its
usage and cost with it, were thrown away. The verbs' error branches then
called `log_failed_unless_input_error/6`, which wrote an `"error"` row with
0 tokens and no cost.

The guide promised the opposite: "The provider call is logged with its
usage in that case". That is true for `complete/3`, where `run_complete/5`
logs before `attach_json/2`, but it was false for the vision verbs.

It matters more after this PR than before:
- `extract_text/3` **always** asks for JSON, so every prose answer from a
  model that ignores the schema was paid for and invisible.
- `Budget.spent/3` sums `status == "success"` rows only, so that spend
  never counted against any cap.
- `compare_images/4` had a second variant: a JSON *array* parses, but is no
  verdict.

**Fix.**
- `Images.describe/3` builds the result before parsing. On a parse failure
  it hands the result, usage and sent `:prompt` included, to an
  `:on_no_json` one-arity callback, then returns the same error
  (`images.ex:630`, `notify_no_json/2` at `images.ex:927`).
- `Images.compare/4` forwards the callback and calls it for the array case
  (`images.ex:986`).
- `describe_image/3`, `extract_text/3` and `compare_images/4` install the
  callback through `log_unparsed_answer/5` (`lib/phoenix_kit_ai.ex:2392`),
  which writes the normal success row.
- `log_failed_unless_input_error/6` no longer writes a second, failure row
  for `{:no_json_in_response, _}` (`lib/phoenix_kit_ai.ex:3276`).
- The error returned to callers is unchanged.

**Test.** `images_test.exs:536` now runs a prose answer through all three
verbs and asserts four `{"success", 500}` vision rows and no error row. It
fails without the fix.

### IMPROVEMENT - MEDIUM — A caller cache key ignored `extract_text/3`'s `fields:` *(fixed on main)*

With `cache: [key: term]`, the material was
`{:caller_key, key, opts[:schema], opts[:json] == true}`. The docs promise
that "the verb, endpoint, model and JSON shape stay in the key". For
`extract_text/3`, though, the JSON shape is built from `fields:` inside
`Images.extract_text/3`, and top-level `opts[:schema]` is nil.

So `extract_text(ep, img, fields: ["ean"], cache: [key: "label:1"])`
followed by `fields: ["weight"]` with the same key served the first answer:
`fields` was `%{"ean" => …}` and `"weight"` was absent. No error, and no
provider call.

**Fix.** `opts[:fields]` is part of the caller-key material (`with_cache/6`,
`lib/phoenix_kit_ai.ex:2446`). The guide now spells out which options
survive a caller key, and that everything else is the caller's to include.

**Test.** `images_test.exs:733` fails without the fix.

## Low / Nitpicks

### NITPICK — `Translatables.valid_entry?/1` warns on every lookup, not at boot

`translatables.ex:86`. Its comment reads "a typo should not wait for the
first translation job". But `configured/0` runs inside `all/0`, and `all/0`
runs on every `find/1`, which `TranslateWorker` calls once per job
(`translate_worker.ex:243`). The consequences:
- A misconfigured entry warns once per translation job, not once.
- A correct entry costs a `Code.ensure_loaded?` per job.

Not fixed. The spam only happens for a broken config, where noise is
arguably the point, and moving the check to boot needs a hook the module
does not have. Recorded so the comment is not taken at its word.

### NITPICK — `process_image(…, verify:)` re-verifies on every cache hit

`maybe_verify/5` (`lib/phoenix_kit_ai.ex:3294`) runs after `with_cache/6`,
and its `compare_images/4` call gets no `cache:` (`check_opts` at `:3307`).
So a cached edit still pays for a fresh vision verification on each hit.

Not fixed. Whether a stored edit should be re-verified is a product call,
and forwarding the caller's `cache:` would also cache verdicts across
different originals under a caller `key:`. Left as-is and on record.

### NITPICK — URL image inputs key on the URL string

The cache material holds the `%{url: …}` input, not the bytes behind it. A
changed image at a stable URL is served the old answer until the TTL.

Documented in the guide rather than changed. Fetching to hash would defeat
the point of a cache hit.

---

## Positive observations

- **`with_cache/6` + `cached_row/4`.**
  - A hit writes a zero-cost row with the hitter's `user_uuid`, source,
    attribution, prompt link and snapshot. Reports that ignore
    `metadata.cached` still add up.
  - The fresh/cached split in tests avoids a real ordering flake (`51283bb`).
- **Structured output parsed inside the cached closure** (`run_complete/5`).
  A prose answer to a JSON request can never be served from cache as a
  success.
- **ETS placement is right** (per the OTP guidance).
  - The table is public, with `read_concurrency`; reads and writes never
    queue behind the GenServer, which only sweeps.
  - The warn flags live in ETS, deliberately not `persistent_term`, whose
    writes trigger a global GC.
  - The `:infinity` guard in the sweep's match spec is correct.
- **`Budget.status/2` is pure and `check/2` warns.** A dashboard that polls
  it cannot use up the once-per-crossing warning. With no caps set, the
  requests table is never queried.
- **`create_request/1` logs a failed insert.** The FK on `user_uuid` would
  otherwise lose paid usage rows silently.
- **`prompt_snapshot` is a content hash**, not `updated_at`. That timestamp
  moves on every usage increment, which the test at
  `budget_cache_test.exs` "a hit's row is attributed…" pins.
- **`first_existing_uuid/2` closes the PR #9 audit finding.** The reorder
  row no longer names an id `Reorder` silently skipped.
- **`extract_text/3`'s prompt explicitly forbids invented label text.**
  Model-derived values are normalised before they reach the row (the
  `language_tag/1` regex, `confidence` must be a number), so free text
  cannot slip into metadata.

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good: flat verbs, one gate and one wrapper, run_* helpers out of the closures |
| Architecture | Good: cache and budget are cross-cutting without leaking into adapters |
| Security | Good: tag-only telemetry, PII gate kept, no content in cache events |
| Performance | Good: lazy key hashing, no DB touch without caps; per-endpoint cap index is a documented TODO |
| Test coverage | Good: 454-line budget/cache suite; the three gaps above now covered |
| Migration safety | N/A: no DDL; uses existing columns |
| Consistency | Guide, moduledocs and AGENTS.md agree after the follow-up edits |

**Strengths**
- Clear, honest documentation of what caps and cache do *not* promise.
- Caching and structured output compose correctly (the JSON shape is in the
  key; parse failures are never stored).
- Well-scoped tests through the public verbs.

**Areas addressed**
- The cap must not be skippable by an option a verb ignores.
- Paid calls must always leave a costed success row, or the cap cannot see
  them.
- A caller cache key must carry every option that shapes the JSON.

**Verdict:** APPROVE with reservations → fixed on main.
