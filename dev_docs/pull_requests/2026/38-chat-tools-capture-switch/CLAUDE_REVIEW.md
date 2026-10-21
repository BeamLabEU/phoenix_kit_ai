# Claude Review — PR #38

**Reviewer:** Claude Sonnet 5.5
**PR:** Tool calling in complete/3 and a per-call capture_request_content switch (timujinne)
**Reviewed:** 2026-10-21
**Merge commit:** `e62214a`

## Overall Assessment

**APPROVE with reservations.** Risk: **Low-Medium**. The request side is clean:
`tools:` / `tool_choice:` / `parallel_tool_calls:` are sent only when given
(`completion.ex` `build_chat_body/3`), `normalize_message/1` adds the tool fields
only where the protocol has them and a plain message encodes exactly as before,
`maybe_add/3` drops `[]` so an empty `tool_calls` or `tools` is never sent, and
the per-call `capture_request_content` only narrows the global setting
(`capture_request_content?(false)` / `(_)` in `lib/phoenix_kit_ai.ex`). The
setting is dropped from the cache key in `cacheable/1`. The response side had
two gaps, both fixed in the follow-up.

## Findings

### BUG - MEDIUM — `json: true` / `schema:` together with `tools:` loses the tool calls

`attach_json/2` (`lib/phoenix_kit_ai.ex`, formerly `:3123`) parsed
`extract_content/1` unconditionally. A tool-calling round has `content: nil`
(the PR itself makes `extract_content/1` return `{:ok, nil}` for it), so
`StructuredOutput.parse(nil, true)` returned `{:error, {:no_json_in_response, nil}}`.
The provider call succeeded and was billed, but the caller got an error with no
response in it, so the `tool_calls` were unreachable. Any consumer combining a
JSON answer format with tools (the natural shape for an agent that ends in a
structured result) fails on every round that calls a tool.

**Fix:** a response carrying tool calls is returned as `{:ok, response}` without a
`"json"` key; the final text round is parsed as before. Tests added.

### IMPROVEMENT - MEDIUM — the usage row did not record what the model called

With `content: nil` the row stored `response: nil` and nothing else, and
`request_payload` carries no `tools`. A tool-calling round was therefore
invisible in the Usage log: tokens and cost, no calls.

**Fix:** under the same content gate, `metadata.response_tool_calls` holds the
calls as the provider sent them when there are any (`maybe_put_tool_calls/2`).
They contain user-derived arguments, so they are written only when capture is on,
and the per-call `false` removes them. Tests added. The Usage modal does not
render the key yet.

### NITPICK — the cache comment's rationale is not quite right

`cache_opts_for/1` says a replayed answer "depends on tool results that are not in
the key's material". They are: `messages` (tool-role messages included) are part
of the key. The behaviour is still right, because replaying a `tool_calls` answer
would skip running the tools, so refusing to cache a call with `tools:` is the safe
choice. Not changed beyond noting it here.

### NITPICK — `capture_request_content` only honours the literal `false`

`"false"` or `0` falls through to the global setting. Matches the documented
"only narrows" contract; no change.

## Positive Observations

- The `speak/3` / `embed/3` exception is documented in the moduledoc, the README
  and AGENTS.md, and the option is correctly dropped from the cache key.
- `verify: true` in `process_image/4` forwards the switch to its `compare_images`
  check row, so the check cannot leak what the edit row redacted.
- `chat_tools_test.exs` pins the wire body, the multi-round messages, the cache
  bypass and each verb's redaction.

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Fits the verb/adapter split |
| Security | The gate is respected; tool-call arguments needed the same gate (done) |
| Performance | Neutral |
| Test coverage | Good; the structured-output and row-recording cases were missing |
| Consistency | Docs updated in three places |

**Verdict:** approve; the two response-side gaps are closed in the follow-up.
