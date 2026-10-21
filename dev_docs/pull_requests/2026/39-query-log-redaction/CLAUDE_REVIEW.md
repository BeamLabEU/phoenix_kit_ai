# Claude Review — PR #39

**Reviewer:** Claude Sonnet 5.5
**PR:** Keep usage rows, endpoint api keys and prompt texts out of the query log (timujinne)
**Reviewed:** 2026-10-21
**Merge commit:** `fabe16d`

## Overall Assessment

**APPROVE.** Risk: **Low**. `log: false` is added to the writes that carry
secrets or user text: `create_endpoint/2` and `update_endpoint/3`
(`lib/phoenix_kit_ai.ex:1373,1398`), `create_prompt/2` and `update_prompt/3`
(`:1587,1609`), and `insert_row/1` for usage rows (`:2397`, including the
savepoint branch). `test/phoenix_kit_ai/query_log_redaction_test.exs` raises the
Logger level to `:debug`, first proves the test repo really logs parameters
(so the later `refute`s are not vacuous), then asserts sentinels never appear.

## Coverage audit

Every `repo().insert/update/update_all` in `lib/` was checked for secret or
user text in its parameters:

| Site | Parameters | Verdict |
|---|---|---|
| `mark_endpoint_validated/1` (`:1441`) | `last_validated_at`, `updated_at` | fine |
| `record_prompt_usage/1` (`:1649`) | counter, timestamp | fine |
| `reset_prompt_usage/2` (`:2052`) | `0`, `nil` | fine |
| legacy `update_all` (`:684`) | writes `api_key: ""`, a provider key and a uuid | fine |
| `promote_provider_to_integration_uuid` (`:847`) | uuids | fine |
| `translation_sweep.ex:179` | `scheduled_at` | fine |

No remaining write leaks. Updates only send changed fields, so an unchanged
`api_key` is not a parameter on `update_endpoint/3`; `log: false` there still
covers a key rotation.

## Findings

### NITPICK — `log: false` silences the Ecto logger only

Ecto still emits the `[:<repo>, :query]` telemetry event with the full parameter
list. A host that attaches its own handler and logs `metadata.params` would
still see the key or prompt text. Out of reach for this package (the repo is the
host's); worth a sentence in AGENTS.md if a host ever reports it. Not changed.

### NITPICK — nothing stops a new write from forgetting the flag

The guarantee is per call site. The behavioural test covers today's sites; a new
write path with user text needs its own `log: false`. Not changed: a conformance
grep would flag the harmless writes above too.

## Positive Observations

- The canary test that proves the log really prints parameters is the part most
  PRs of this kind omit.
- The savepoint branch of `insert_row/1` keeps the flag.
- Each call site carries a one-line reason.

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Fine |
| Security | Improves it: key and prompt text out of debug logs |
| Performance | Neutral |
| Test coverage | Good |
| Consistency | Matches the "no credential or user content in a log line" rule |
