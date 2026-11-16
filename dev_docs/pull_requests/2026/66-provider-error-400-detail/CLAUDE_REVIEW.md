# PR #66 — Read Anthropic's credit-balance 400 as money and keep provider request ids

**Author:** timujinne · **Reviewer:** Claude (Opus 5.5) · **Date:** 2026-11-16 ·
**Verdict:** approve; three findings fixed, one recorded

Merged into `main` as 9144f1a (four commits: 9204cc6, 9902394, aca2e00, b09796b).

The PR does three things:

- `ProviderError` reads an Anthropic 400 whose message starts "Your credit balance is too low" as
  `:insufficient_credits`.
- Both HTTP doors keep the provider's request id (`request-id`, then `x-request-id`) on the row under
  `metadata.provider_error.request_id`, through `put_response/1` (formerly `put_retry_after/1`).
- The failure log lines name the kind of call and the endpoint's provider (`Completion.call_label/2`), plus the
  provider's code. A refusal read as a class now gets one line too, ending in `read as <class>`.

## Checked and fine

- **Every non-2xx path ends in `ProviderError.note/3`.** The id is put on any non-2xx response, so a path that
  skipped `note/3` would leave a row with `provider_error.request_id` but no `status`. Each caller of
  `post_once/4` and `Providers.HTTP.request/4` was traced to `handle_error_status/3`, `HTTP.error/3` or
  `converse_error`. All of them note. `HTTP.fetch_image/2` (fetching output URLs) never touches `ProviderError`,
  so a CDN's `x-request-id` cannot reach a row.
- **No stale id across attempts.** `post_once/4` and `HTTP.request/4` call `ProviderError.clear/0` before every
  attempt. A retried 429 whose final attempt succeeds leaves nothing behind, and a final attempt without headers
  does not inherit an earlier attempt's id.
- **Money keeps the id, not the Retry-After.** `drop_retry_after/2` removes only `retry_after_s`.
- **The credit-balance match.** It needs `status == 400` and is anchored and case-sensitive, so a 429 that quotes
  the same words stays `:rate_limited` and is still retried. The tests pin all three properties.
- **No words in the log.** Both log lines carry only `ProviderError.code/2`'s output: a token of at most 64
  characters that `redact/1` leaves unchanged. An integer code now goes through the same check (aca2e00).
- **One line per failed call.** `log_classified/4` runs only for an atom result, so the 404
  `{:no_provider_for_params, []}` branch and `generic_error_status/3` never log twice. Retries happen below
  `handle_error_status/3`, so a retried call logs once.
- **`call_label/2` on legacy providers.** `Endpoint.base_provider/1` takes the part before `:`. A legacy row
  holding a UUID in `provider` logs the UUID, which is harmless.
- **Request ids are not content.** `provider_error` is not in `Retention.content_keys/0`, which is correct, and
  the id stays on the row with capture off, like `status` and `code`.

## Findings

### BUG - MEDIUM — any integer `error.code` in a 200 was taken as the HTTP status (fixed)

`Completion.error_code/1` (`completion.ex:274`) returned any integer `error.code`, and `error_in_body/4` used it as
the status. `OpenAICompatible.decode_chat_images/3` (`openai_compatible.ex:208`) did the same with
`when is_integer(code)`. A 200 carrying a provider's own number therefore became a pseudo-status:

- Z.ai's business codes are four digits (1113, 1302).
- An overlong integer can be up to 1024 digits, the most Jason decodes.

The fallout:

- The result was `{:api_error, 1113}`.
- The row's `provider_error.status` was 1113.
- `ProviderError.code/2` then dropped the code because `code == status`, so the one useful fact was lost.
- With 1024 digits, the status, the `error_message` (`"API error: 7777…"`) and the log line each carried a
  kilobyte of digits.

The PR's own review thread found this route. It predates #66, but #66 made integer codes first-class
(`code/2` is now public and logged).

The image chat path had a second gap. A 200 error with a string code or no code fell through to
`:invalid_response_format`. The provider's words and status were then lost, unlike chat, which reads it as a 502.

**Fix:**

- Both sites accept an integer as a status only in `100..599`.
- Anything else is a 502, like an error that names no code. The number stays the row's `code`, so Z.ai's 1113 is
  now kept where before it was dropped.
- The image chat path reads a code-less or string-coded error in a 200 as a 502 too, and `decode_chat_images` now
  takes the call label, so its line names the provider (`AI images (mistral) failed: 502 …`).
- Two tests: chat with 4711 and with 1024 digits; the image chat path with 4711, a string code and no code.
- AGENTS.md's "Answers that are not answers" now states the range.

### IMPROVEMENT - MEDIUM — Bedrock's request id was not kept (fixed)

The PR listed `x-amzn-requestid` under "left out on purpose" without saying why. Bedrock is the provider that
needs the id most: it reports no cost, and an access 404 or a 403 is only diagnosable from AWS's side with the
id. Bedrock goes through `post_once/4`, so `put_response/1` already sees its headers.

**Fix:** `x-amzn-requestid` is the third header `request_id/1` reads, after `request-id` and `x-request-id`.
Bedrock ids are UUIDs and pass the id shape. Req stores header names in lower case, so AWS's `x-amzn-RequestId`
matches. The moduledoc comment and the `Request` docs list the header. A test checks that a Bedrock 500's row
carries the id.

### NITPICK — Bedrock's log lines kept their own shape (fixed)

The PR moved every request path to `AI <kind> (<provider>) failed: <status> (<code>)` with `, read as <class>`
for a classified refusal. Bedrock Converse kept two older shapes:

- `@converse_label "Bedrock Converse call"`.
- `"… failed: 403 (invalid_api_key)"` for the reasons `BedrockConverse.error/2` reads. Here the parentheses held
  the class, where on every other line they hold the provider's code.

A grep for `AI completion (` or `read as` missed Bedrock chat. The transport line was `Bedrock Converse transport
error`.

**Fix:**

- `converse_error` takes `call_label(endpoint, "completion")`.
- Its classified branch goes through `log_classified/4`, giving `AI completion (amazon_bedrock) failed: 403, read
  as invalid_api_key`.
- Its unclassified branch is `error_status/4`, the same `safety_errors` switch the chat path uses, so there is no
  duplicated `if`.
- The transport line uses the label.
- The two Bedrock log assertions are updated, one-line-per-call is pinned, and a transport-error assertion is
  added.

### NITPICK — the model-list fetch still logs "OpenRouter" for every provider (recorded)

`OpenRouterClient.fetch_openai_models/5` logs `OpenRouter models fetch failed: <status>` for OpenAI, Mistral and
the rest. The PR records this as out of scope: the fetch writes no row and predates the PR. Left as is.

## Also added

- A direct `call_label/2` test: base provider, a named connection (`openrouter:work`), and a nil provider or
  endpoint. The PR thread asked for it.

## Positive observations

- The PR is honest about what it does not know. The credit-balance wording is undocumented, and both the code
  comment and AGENTS.md say so and cite the two SDK issues. The match is narrowed so that a wrong guess
  degrades to the old `{:api_error, 400}`, never to a money class that would stop retries.
- The request-id shape check (`[A-Za-z0-9_.:-]{1,128}`) keeps a hostile or broken header from becoming a
  content channel on a row that stays with capture off. It is tested against eight bad values, including a name.
- The PR body describes a mutation pass in which each assertion was shown to fail when its rule is removed.
- The silent class branch of `handle_error_status/3` now logs. That closes the gap that made the incident
  described in the PR untraceable in the first place.

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good; `put_response/1` composes cleanly with `maybe_put/3` |
| Architecture | Unchanged; the note stays in the calling process |
| Security | Ids are shape-checked; codes are redact-checked before reaching a log line |
| Performance | One more body decode per failure (recorded by the author); negligible |
| Test coverage | Strong; extended for the status range, the image chat path, Bedrock |
| Migration safety | No schema change; the row's `provider_error` map gains a key |
| Consistency | Bedrock's lines brought into the new scheme |

**Verdict:** approve. The fixes are in the follow-up commit.
