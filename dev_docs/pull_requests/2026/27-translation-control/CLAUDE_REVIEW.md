# Claude Review — PR #27

**Reviewer:** Claude Opus 5
**PR:** Fix six translation-engine defects for shop translation control (design §9)
**Author:** timujinne (`timujinne/feature/translation-control`)
**Merge commit:** `c46b796`
**Reviewed:** 2026-09-15
**Verdict:** APPROVE with reservations. Two High and two Medium bugs, all
fixed on main with regression tests. Two of them meant the PR's own retry
fixes (§9.5, §9.6) could not work on a host with the request cache on.

---

## Notes for the reviewer

- Read in full, with surrounding context: the modified parts of
  `phoenix_kit_ai.ex` (`ask_with_prompt/4`, `complete_with_system_prompt/5`,
  `complete/3`, `with_cache/6`, `cached_row/4`, `log_request/7`,
  `log_failed_request/7`), `translation.ex`, `translate_worker.ex`,
  `prompt.ex`, `translatable.ex`, `mix.exs`, `test/test_helper.exs`. Also
  read `completion.ex` (`chat_completion/3`, `handle_error_status/2`) and
  `request_cache.ex`, which the PR does not touch but which decide whether
  its fixes fire.
- The "translation-control design doc" the comments cite (§2, §4.1, §9.x)
  lives outside this repo. The review works from the code.
- No live provider was called. Everything provider-side is `Req.Test` stubs.
- The High bugs in finding 1 need `config :phoenix_kit_ai, request_cache:
  [default: true]` (or a caller passing `cache:`). The cache is off by
  default, so hosts on defaults were not affected.

## Overall assessment

The PR is well aimed. Every change is additive:
- a `{{SourceFields}}` variable
- `:source_fields` in `put_translation/4` opts
- attribution on the failure row
- a new retry class
- in-body error normalisation

The test_helper rewrite (fail loud instead of silently excluding 550 tests)
is a real improvement.

The problems are all at the edges, where a change meets a subsystem it
didn't look at:
- the request cache, which stores what the retries need to re-ask
- the PII gate, which the placeholder scan stepped around
- Postgres role permissions, which the new `test` alias assumes

**Risk level:** Medium before the fixes, Low after.

---

## High Severity

### 1. BUG - HIGH — The §9.5 and §9.6 retries replay the cached answer instead of asking again

`lib/phoenix_kit_ai/completion.ex:102` (`parse_success_response/2`),
`lib/phoenix_kit_ai/request_cache.ex:226`, `lib/phoenix_kit_ai/translation.ex:178`

**§9.6.** A 200 carrying `{"error": {"code": 504}}` came back from
`Completion.chat_completion/3` as `{:ok, body}`. `run_complete/5` logged it as
a **success** row (0 tokens), and `with_cache/6` stored it, because the cache
stores any `{:ok, _}`. `Translation.handle_ai_response/2` turned it into
`{:api_error, 504}`, and `TranslateWorker` retried. The retry hit the cache
entry, got the same error body back at zero cost, and did the same again on
attempt 3. The job then failed terminally. The error stays in the cache for
the TTL (24 h by default), so every re-enqueue fails the same way.

**§9.5.** A `missing_fields` answer is a successful completion. It was
cached on attempt 1, and each retry parsed the same stored text. Retrying
could never fix it, which is the only thing the new
`retryable?({:parse_error, {:missing_fields, _}})` clause exists to do. The
caller also had no way to opt out: `do_translate/6` kept only `:source` and
`:attribution` from its opts, so `cache:` never reached the call.

**Fix applied:**
- `parse_success_response/2` treats `%{"error" => %{"code" => integer}}`
  with no `"choices"` as an error, through `handle_error_status/2`. Nothing
  is cached. The row goes through `log_failed_request/7`, attribution
  included, and is a failure. A non-integer code becomes
  `:invalid_response_format`.
- `Translation.translate_fields/6` passes `:cache` through (documented).
- `TranslateWorker.retry_cache_mode/1` sends `cache: :refresh` from attempt
  2 on, but only when the host's cache is on. `:refresh` stores
  unconditionally, so passing it on a cache-off host would switch caching
  on.
- Tests (`translation_engine_fixes_test.exs`):
  - "an error body is never cached, so the retry reaches the provider"
  - "a cached missing-fields answer replays until the caller refreshes it"
  - The existing §9.6 end-to-end test now asserts `status == "error"`. It
    had pinned `"success"` as the expected behaviour.
- Tests (`translate_worker_test.exs`): `retry_cache_mode/1`.

### 2. BUG - HIGH — The new `mix test` alias aborts before any test runs when the role can't reach `postgres`

`mix.exs:91` (`run_tests/1`)

`ecto.create` connects to the maintenance database (`postgres`) even when
the target database already exists. A role that owns only its test
database is refused (`FATAL 42501 … permission denied for database
"postgres"`). This happens on the shared-database setup AGENTS.md documents
(`PGDATABASE`/`PGPOOL`), and it happened in this container. `Mix.raise`
then ended the run before `test_helper.exs` loaded, with zero tests run.
The PR swapped a silent skip for a guaranteed hard stop on a machine whose
database works fine.

**Fix applied:** `ecto.create` is wrapped in a `rescue Mix.Error` and prints
one line saying it was skipped. The `test_helper.exs` preflight is still
the authority: it aborts on an unusable database, so the PR's fail-loud
intent holds.

---

## Medium

### 3. BUG - MEDIUM — An error in the body skipped the error vocabulary

`lib/phoenix_kit_ai/translation.ex:287`

`handle_ai_response/2` mapped every in-body code to `{:api_error, code}`:
- A 429 became `{:api_error, 429}`. `retryable?/1` then retried it
  immediately and used up an attempt, where the worker would have given
  `:rate_limited` a `{:snooze, 30}`.
- 401 and 402 became `api_error_401` and `api_error_402` in the activity
  log, instead of `invalid_api_key` and `insufficient_credits`.
- A non-integer code slipped past `classify_ai_detail/1`'s `is_integer`
  guard.

**Fix applied:** covered by finding 1's change. Classifying in `Completion`
routes the code through `handle_error_status/2`, the same path a real
status takes. The `Translation` clause stays as a fallback for responses
that don't come through `Completion`, with a comment saying so. Test:
"a 429 in a 200 body is :rate_limited, which the worker snoozes".

### 4. BUG - MEDIUM — The unbound-placeholder guard scanned caller content, outside the PII gate

`lib/phoenix_kit_ai.ex:1757` (`detect_unbound_placeholders/3`)

The guard ran `Prompt.unbound_placeholders/1` over the **rendered** prompt,
which already contains the variable values. For translation, the values are
the source text. A product description with a Liquid or Handlebars snippet
(`Use {{sku}}`) was therefore:

- reported as an unbound template slot (a false positive, on every row for
  that resource),
- echoed into `Logger.warning`,
- written to `metadata.unbound_placeholders` whether or not
  `capture_request_content?/0` was on. AGENTS.md: "Any new field carrying
  user text must sit behind the same gate."

**Fix applied:** new `Prompt.unbound_placeholders/2` (template, variables).
It renders the template with every bound value blanked, then scans what is
left. Only template-authored `{{...}}` can survive, and the key lookup
(string, then atom, `nil` = unbound) is `render_content/2`'s own, so it
cannot drift from `render/2`. Both call sites now pass the templates they
render: `content` + `system_prompt` for `ask_with_prompt/4`, and `content`
for `complete_with_system_prompt/5`. `unbound_placeholders/1` is kept.

Tests:
- `prompt_test.exs`: `unbound_placeholders/2`
- `translation_engine_fixes_test.exs`: "a {{...}} inside a bound value is
  caller content, not an unbound slot"

### 5. IMPROVEMENT - MEDIUM — A cache hit's row dropped `unbound_placeholders`, and the key leaked into the cache key

`lib/phoenix_kit_ai.ex:2524` (`cached_row/4`), `:2889` (`cacheable/1`)

AGENTS.md: "A cache hit's usage row is the fresh row minus cost". Attribution
and the prompt snapshot were copied onto the hit row, but
`unbound_placeholders` was not, so a report filtering on it saw only the
first call. Separately, `:unbound_placeholders` rode along in
`merge_endpoint_opts/2` into the cache-key material. It is tracking data, not
request shape. The effect was harmless, because it is derived from the prompt
and variables already in the key, but it is the kind of thing `cacheable/1`
exists to drop.

**Fix applied:** `cached_row/4` pipes through
`maybe_put_unbound_placeholders/2`, and `cacheable/1` drops the key. Test:
"a cache hit's row carries the same unbound_placeholders as the fresh row".

### 6. IMPROVEMENT - MEDIUM — AGENTS.md still documented the auto-skip the PR removed

`AGENTS.md` (Commands; Testing)

Both places still said integration tests "auto-skip without" a database,
"after probing with `psql -lqt`". The PR made that path raise, and added
`PK_AI_SKIP_DB=1` as the only opt-out.

**Fix applied:** both sections now describe the alias, the preflight that
raises, and `PK_AI_SKIP_DB=1`.

---

## Low

### 7. NITPICK — Comments cite a design doc that isn't in this repo

`translation.ex`, `translate_worker.ex`, `phoenix_kit_ai.ex`, the tests

Comments like "§9.3 fix", "see §2 of the translation-control design doc"
and "design doc §4.1/§9.3" point at a document a reader of this repo cannot
open. The comment blocks are also several times denser than the
surrounding code. **Not changed:** rewriting every block is churn with no
behaviour behind it. Worth avoiding next time, by stating the reason inline
and dropping the section numbers.

### 8. NITPICK — Reflowed comments kept stale references in `test/test_helper.exs`

The rewrap kept "Standalone runs against Hex `phoenix_kit ~> 1.7`" (the
floor is `~> 2.0`) and a pointer to a personal `~/.claude` memory file.
Both predate the PR. **Not changed.**

### 9. NITPICK — `enabled?/0 (integration)` repeats `CoverageTest`

The new round-trip in `test/phoenix_kit_ai_test.exs` is the same one
`coverage_test.exs` already pins. It is harmless, and its own comment says
it is there on purpose. **Not changed.**

### 10. NITPICK — A `missing_fields` retry is a paid call

With finding 1 fixed, each of the up to two extra attempts calls the
provider again and counts against spend caps. That is the intended
trade-off, and the clause's comment says so. It is on record here because a
prompt that structurally cannot produce a marker now costs 3× before
failing, where it used to cost 1×.

---

## Positive observations

- **`build_variables/3`** sorts the `{{SourceFields}}` sections by name
  and reuses `marker/1`. The rendered prompt is deterministic, which also
  keeps it cache-key stable, and the marker vocabulary is the same going in
  and coming out.
- **`:source_fields` is captured before the AI call.** A consumer that
  fingerprints the translated source cannot be fooled by an edit made while
  the call was in flight. It is threaded as an opt, not a callback change,
  so existing adapters keep compiling.
- **Attribution on the failure row (§9.4)** fixes a real asymmetry: failed
  calls were the ones you most needed to trace.
- **`maybe_put_unbound_placeholders/2` adds nothing when the list is
  empty**, so request rows stay clean.
- **The test_helper rewrite** replaces a `rescue`/`catch` that had been
  dropping about 550 integration tests while reporting success with an
  explicit, named opt-out. It is the right call, and finding 2 only
  hardens its entry point.
- Good test depth: an HTTP-level file (`translation_engine_fixes_test.exs`)
  on top of the pure unit tests.

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good; comments over-dense, citing an external doc |
| Architecture | Additive and backwards-compatible; missed the cache interaction |
| Security | PII-gate bypass in the placeholder scan (fixed) |
| Performance | Neutral; a `missing_fields` retry is now a real paid call |
| Test coverage | Strong; one test pinned the buggy "success" row |
| Migration safety | No DDL; no consumer action needed |
| Consistency | Error vocabulary bypassed for in-body errors (fixed) |

**Strengths**
- Precise fixes that each target a diagnosed production failure
- Additive contracts: a new variable, a new opt and new metadata
- Fail-loud test infrastructure

**Areas addressed on main**
- Retries now reach the model: error bodies are never cached, and retries
  refresh the entry
- In-body errors are classified at the HTTP layer
- The placeholder scan covers templates only
- The cache hit row matches the fresh row
- `mix test` survives a role without CONNECT on `postgres`
- AGENTS.md is in sync

**Verdict:** APPROVE with reservations; the reservations are resolved on
main. See `FOLLOW_UP.md`.
