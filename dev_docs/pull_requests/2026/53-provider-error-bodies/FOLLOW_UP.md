# PR #53 follow-up

GPT review completed on 2026-10-27. No additional confirmed findings; see [the review](GPT_REVIEW.md).

## Claude review — 2026-11-05

See [the review](CLAUDE_REVIEW.md).

- **Fixed:** the provider's words sit behind the capture gate and moved to
  `metadata.provider_error_message` (a content key); `provider_error` keeps status, code
  and Retry-After. Also: no provider text in the log; a non-string message and a NUL no
  longer raise; an error in a 200 is not audio or a bad format; a safety refusal's text is
  masked where it is made; `-MMDD` snapshots.
- **Note for a consumer reading rows:** new rows carry the words at the new key; older
  rows keep `provider_error.message`.
- **Not changed:** Mistral's top-level error shape and Anthropic's and xAI's out-of-money
  bodies, known only from memory; a stale note on a queue-full row.
- **Later, #66:** Anthropic's out-of-money body is read after all: a 400 whose message
  starts "Your credit balance is too low" is `:insufficient_credits`. It is still not on
  Anthropic's error or rate-limits pages; the wording is the one quoted in
  anthropics/anthropic-sdk-typescript#618 and anthropics/anthropic-sdk-python#1646. It is
  matched only on a 400 and only at the start of the message. Mistral and xAI are as above.
