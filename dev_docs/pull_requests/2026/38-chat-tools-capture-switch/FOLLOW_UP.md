# FOLLOW_UP — PR #38 (Tool calling in complete/3 and a per-call capture_request_content switch)

Triaged 2026-10-21. `CLAUDE_REVIEW.md` found one bug, one improvement and two nitpicks.

## Resolved

- **BUG - MEDIUM:** `attach_json/2` returns a response that carries tool calls
  untouched instead of failing it with `:no_json_in_response`
  (`lib/phoenix_kit_ai.ex`). Tests in `test/phoenix_kit_ai/chat_tools_test.exs`:
  a tool round with `json: true` returns the calls with no `"json"` key; a text
  round with `json: true` and `tools:` still parses.
- **IMPROVEMENT - MEDIUM:** `log_request/8` stores `metadata.response_tool_calls`
  behind the content gate. Tests: present with capture on, absent with
  `capture_request_content: false`.

## Not changed

- **NITPICK:** the `cache_opts_for/1` comment overstates why tool calls are not
  cached; the behaviour is correct.
- **NITPICK:** only the literal `false` narrows the global setting, as documented.
- The Usage modal does not render `response_tool_calls`; the data is in the row
  until someone needs the view.
