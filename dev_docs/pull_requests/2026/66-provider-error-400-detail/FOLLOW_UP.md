# PR #66 follow-up

Claude review completed on 2026-11-16; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** a 200's integer `error.code` counts as the HTTP status only in 100..599, in `Completion` and in the
  image adapters' chat path. Any other number reads as a 502 and stays the row's `code`. The image chat path
  also reads a string-coded or code-less error in a 200 as a 502, not `:invalid_response_format`, and its log
  line names the provider.
- **Fixed:** Bedrock's `x-amzn-requestid` is kept as the row's `provider_error.request_id`.
- **Fixed:** Bedrock Converse log lines use `call_label/2` and `log_classified/4`
  (`AI completion (amazon_bedrock) failed: 403, read as invalid_api_key`).
- **Added:** a direct `call_label/2` test.
- **Not changed:** the model-list fetch's `OpenRouter models fetch failed` line for other providers. It writes no
  row; the PR records it as out of scope.
