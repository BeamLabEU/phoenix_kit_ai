# Claude Review — PR #53

**Reviewer:** Claude Opus 5.5
**PR:** Tell an account out of money from a rate limit by the provider's error body; keep the provider's words, Retry-After and the answered model on the journal row (timujinne)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `d50b6ae`

## Notes for the reviewer

A delegated read of the diff produced the candidates. Each was then checked against the
code; **Reproduced** means a test failed on the unfixed code first. Provider body shapes
known only from memory are marked and were not acted on.

## Overall Assessment

**APPROVE with reservations.** Risk: **Medium**. Judging money from body fields and
keeping the note in the process, so no caller changed shape, are the right calls. The gap
is what happens to the provider's words afterwards: masked for the row, but not gated,
and not masked everywhere.

## Findings

### BUG - MEDIUM — the provider's words skipped the capture gate (fixed; a shape change)

The image and transcription writers keep a refusal's payload out of `error_reason` when
capture is off, then `with_provider_error/1` wrote the same text to the row anyway. With
`capture_request_content: false`, a 400 reading "Your prompt about <user text> was
rejected" put that text on a row marked `content_redacted: true`. **Reproduced.**

**Fix:** with the gate shut the row keeps the status, code and Retry-After but not the
words (`lib/phoenix_kit_ai.ex:6266`), and a `{:content_policy, _}` row says only what it
was (`phoenix_kit_ai.ex:6315`).

**A shape change, deliberately.** `retention_content_keys_test.exs` requires a gated key to
be a content key, and `retention_test.exs` pins `provider_error` as kept. Both hold only if
the words move out, so they are now `metadata.provider_error_message`, in
`Retention.content_keys/0`, while `provider_error` keeps the facts. No view reads the
nested field. Older rows keep `provider_error.message`, which the content step does not
clear; `AGENTS.md` lists that with the `error_message` column.

### BUG - MEDIUM — raw provider text reached the log (fixed)

`generic_error_status/2` logged the provider's message uncut and unmasked, with capture
off too, against "no credential or user content in a log line". **Reproduced** with a key
and a name in the body.

**Fix:** the status only (`completion.ex:241`). Two tests pinned the message in the log.
They predate that rule, so the rule won and they now assert the opposite. Diagnosis loses
nothing: the row keeps the words.

### BUG - MEDIUM — a non-string `error.message` raised (fixed)

`extract_error_message/1` returned any value, so `{"error":{"message":{...}}}` from a
proxy raised `Protocol.UndefinedError` out of `complete/3`: no failure row, no
`{:error, _}`. **Reproduced.** One guard, `completion.ex:1402`.

### BUG - MEDIUM — a NUL in the provider's words lost the row (fixed)

The reviewer marked this PLAUSIBLE. **Reproduced:** `\u0000` survives into `jsonb`,
Postgres answers 22P05, and the raise comes out of the verb. Stripped at
`provider_error.ex:231`.

### BUG - MEDIUM — a TTS error inside a 200 was taken for audio (fixed)

`decode_audio` treats any JSON without `audio_data` as raw audio, so an error body became
a success row with a price. **Reproduced** against a stub; no provider is known to send
this on that route, but JSON with an `error` key is never audio (`completion.ex:597`).

### IMPROVEMENT - MEDIUM — the chat image path misread an error inside a 200 (fixed)

Money or a 504 in a 200 read as "Invalid response format", with no words on the row.
**Reproduced.** `decode_chat_images` now reads it as the status it names.

### IMPROVEMENT - MEDIUM — a safety refusal's text bypassed the masking (fixed)

`{:content_policy, message}` carried the raw text, so `error_message` could hold a raw
key beside the masked copy, and a long refusal stayed uncut. **Reproduced.** Cleaned once
in `HTTP.error/2`, where the tuple is made (`provider_error.ex:176`).

### IMPROVEMENT - MEDIUM — OpenRouter's transient 402 was never retried (fixed)

See [PR #54's review](../54-retries-concurrency-dollar-money/CLAUDE_REVIEW.md).

### IMPROVEMENT - MEDIUM — false "answered by" on four-digit snapshots (fixed)

`other_model("gpt-3.5-turbo", "gpt-3.5-turbo-0125")` reported another model. Display only.
**Reproduced**; `@dated` takes `-MMDD` (`request.ex:343`). `-latest` on the asked side is
not handled.

### IMPROVEMENT - MEDIUM — Mistral's error shape and two out-of-money bodies (not changed)

Candidates from memory: a top-level `{"object":"error","message":...}`, Anthropic's "Your
credit balance is too low" 400, and xAI's spending-limit 429. Left alone because
`ProviderError` lists only what the providers document, and that rule is what keeps a rate
limit from reading as money. Worth a live check; classification by status still works.

### NITPICK — a queue-full row can show an earlier attempt's words (not changed)

A call rejected by `Limiter.run` never reaches the door that clears the note, so after a
retried 400 the row keeps that 400's words.

## Positive Observations

- The note lives in the calling process, so the `{:error, reason}` shape stayed.
- Money is judged from body fields, not loose phrases.
- Redaction keeps model ids and links readable, and tests use documented bodies.

## Summary

| | |
|---|---|
| Code quality | Very good |
| Security | Fair at merge: masked but not gated; fixed |
| Test coverage | Good on classification; the gate and odd shapes were the gap |
| Consistency | Good |

**Verdict:** APPROVE with reservations; the bugs above are fixed.
