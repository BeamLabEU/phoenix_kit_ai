# Claude Review — PR #54

**Reviewer:** Claude Opus 5.5
**PR:** Retries, concurrency limiter, per-call model, lookup cache, async usage log; money in plain dollars (mdon)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `cfff27f`

## Notes for the reviewer

A delegated read of the diff produced the candidates. Each was then checked against the
code; **Reproduced** means a test failed on the unfixed code first.

## Overall Assessment

**APPROVE with reservations.** Risk: **Medium**. The limiter protocol, the generation
counters and the fail-closed money module are careful work, and no money was found
misread. The defects are at the edges of the options: a per-call list that takes a
different path from no list, and a reader of stored values reused on input.

## Findings

### BUG - MEDIUM — a `concurrency:` list without a key escaped the endpoint's limit (fixed)

With no `:key`, the key defaulted to the provider while the limit came from a different
rule, so "most specific key wins" was skipped. With `"provider:openrouter" => 8` and
`"endpoint:Label reader" => 2`, `concurrency: [notify: pid]` got the provider's 8, and
`notify:` is the documented way to show a place in line. With only the endpoint key the
call got a pool of its own beside the plain calls, so up to 4 ran at once. **Reproduced.**

**Fix:** options that name neither `key:` nor `limit:` only change how the call waits
(`limiter.ex:80`).

### BUG - MEDIUM — writing a money limit in the old unit returned `{:ok, _}` and removed the limit (fixed)

`normalize/1` reads stored values and also parsed input. An integer, a float or a digit
string became `:unmigrated`, `stored/1` wrote the atom as the JSON word, and on read-back
that word was no amount: `update_settings(..., 5_000_000)` succeeded and the cap vanished,
the opposite of "an integer amount is refused". The `@doc` still said "amounts as numbers
or strings". **Reproduced.** The Tasks page was safe, since it passes Decimals.

**Fix:** both writers refuse it with `{:error, :ambiguous_amount}`
(`task_limits.ex:857`), which now has a message of its own.

### BUG - MEDIUM — `retry: nil` switched off the configured policy (fixed)

`Keyword.get(opts, :retry, default)` keeps a present `nil`, and `run_transcribe` always
passes `retry: opts[:retry]`, so `config :phoenix_kit_ai, retry: true` did nothing on the
`/audio/transcriptions` path. The call site is from `760018e`; the semantics from this
PR. **Reproduced.** Fixed where it is read (`completion.ex:1261`); `false` still means no.

### BUG - MEDIUM — `{:no_provider_for_params, params}` named parameters nobody can remove (fixed)

This PR added `usage` to every OpenRouter chat body and `models` to fallbacks, without
adding them to `with_sent_params/2`'s drop list. Every such refusal told the operator to
remove `usage` from the endpoint. **Reproduced.** Fixed at `completion.ex:260`.

### BUG - MEDIUM — vision verbs dropped `timeout:`, `retry:` and `concurrency:` (fixed)

See [PR #59's review](../59-image-ai-building-blocks/CLAUDE_REVIEW.md), where the vision
verbs landed.

### IMPROVEMENT - MEDIUM — `retry:` missed a transient the module knows (partly fixed)

OpenRouter's 402 with `openrouter_in_flight_budget` is classed `:rate_limited` and
documented as "wait for Retry-After and retry", yet returned on the first attempt.
**Reproduced.** Fixed at `completion.ex:1304`; money still gives up at once.

**Not changed:** a 200 with `{"error":{"code":502}}` is parsed after the retry loop, so
it is not retried. Nothing is lost, and retrying it means classifying bodies inside the
loop.

### IMPROVEMENT - MEDIUM — `latency_ms` includes the limiter's wait and retry backoff (not changed)

`start_time` is taken before `Limiter.run` at five call sites (`completion.ex:118`), so a
1 s answer after a 25 s wait logs 26 s and `Recommendations.worked/2` reads the model as
slow. Left alone because it is a decision first: moving the clock changes what every
existing row's number means, and the honest version stores the wait separately. Recorded
in `AGENTS.md`'s TODOs.

### NITPICKS — not changed

- `Cache.store/4` checks and inserts non-atomically; the window is a few instructions,
  and the stale entry lasts at most the TTL.
- `concurrency: [wait: :infinity]` raises under contention. `wait:` is documented as
  milliseconds.

## Positive Observations

- The limiter uses client-made refs, cancel-as-call with a mailbox flush, and monitors on
  holders and waiters, with no per-key growth.
- Generation counters stop a stale fill after an invalidation.
- The async log falls back to synchronous writes rather than dropping rows.
- Money fails closed, and V4 converts by shape, so a re-run converts nothing twice.

## Summary

| | |
|---|---|
| Code quality | Very good |
| Architecture | Very good |
| Security | Good |
| Performance | Good; the limiter never sits on a caller's wait |
| Test coverage | Good; the option edges were the gap |
| Migration safety | Very good |
| Consistency | Good |

**Verdict:** APPROVE with reservations; the bugs above are fixed.
