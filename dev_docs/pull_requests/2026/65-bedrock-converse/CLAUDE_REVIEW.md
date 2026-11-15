# PR #65 — Chat with Claude on Amazon Bedrock through the Converse API

**Author:** timujinne · **Reviewer:** Claude (Opus 5.5) · **Date:** 2026-11-15 ·
**Verdict:** approve; two findings fixed, two recorded

Merged into `main` as d2ad574; it merged cleanly onto the core-floor change (c5846cc).

`Completion.chat_completion/3` now sends a chat call on an `amazon_bedrock` endpoint whose model is not
`openai.*` to `POST <base URL host>/model/<model id>/converse`. The new
`PhoenixKitAI.Providers.BedrockConverse` translates the request from the chat-completions shape and the answer
back into it, so the extractors, `truncated?/1`, `filtered?/1` and the usage rows read it as before. Errors map
into the module's vocabulary while the row keeps Bedrock's own status. The endpoint form's manual model-ID entry
now also sits under a fetched list.

## Checked and fine

- **Same pipeline as the OpenAI path.** `post_converse/4` goes through `Limiter.run/3` and `http_post/4`, so it
  gets the retry policy, `redirect: false` (SSRF), `ProviderError.clear/0` per attempt, the timeout and the
  transport-error tags. The endpoint's stored sampling reaches `BedrockConverse.request/3` because
  `PhoenixKitAI` merges it into `opts` before `chat_completion/3`, as it does for `build_chat_body/3`.
- **Retries on Bedrock bodies.** `retryable?/2` reads the raw `{"message": …}` body. `ProviderError.parse/1`
  gives nil for it, so the decision goes by status: 429 (ThrottlingException, ModelNotReady), 408, 500 and 503
  are retried, and a 400 ValidationException is not. Bedrock has no prepaid balance, so a "money" 429 cannot be
  missed.
- **Error rewriting.** `BedrockConverse.error/2` rewrites the body to `{"error": {"message": …}}` before
  `handle_error_status/3` and `HTTP.error/3` read it. So `ProviderError.class/2`, the `safety_errors` path and
  the row's `provider_error_message` see Bedrock's words, and the status is never rewritten. "Not available for
  this account" (403) falls through to `{:api_error, 403}`: `money?/2` checks codes and types, not the word
  "account".
- **No stale provider note on a local refusal.** A `{:error, :not_supported}` from `request/3` returns before
  any HTTP call, so `ProviderError.clear/0` never runs. The note it could inherit from an earlier call is gone
  anyway: `post_once/4` clears it on every attempt, and the failure logger `take/0`s it.
- **Cost.** `CallCost`'s table source is gated on `Completion.anthropic?/1`, which is false for
  `amazon_bedrock`. So a Bedrock Claude row is never priced at Anthropic's list rates, and only a manual price
  applies, as the PR says.
- **Vision on Bedrock.** The vision verbs reach `chat_completion/3` through the OpenAI-compatible adapter with
  images inlined as `data:` URLs (`Images.normalize_inputs/2`), which is the one image form Converse takes.
  `response_format` is dropped, but `StructuredOutput` always puts the schema in the prompt too.
- **Model id parsing.** `bare_model/1` and `claude_id/1` handle cross-region prefixes, foundation-model ARNs,
  `-v1:0` suffixes and dated ids. An application inference profile ARN names no model, so it gets generic
  sampling (documented).
- **Endpoint form.** `manual_model_entry/1` is reused in both places. The `PhoenixKitAIManualModelInput` hook
  already re-resolves its sibling button on every patch (see AGENTS.md's landmines), so a second instance under
  the grid is safe.

## Findings

### BUG - MEDIUM — new label never extracted into the catalogues (fixed)

`endpoint_form.html.heex:763` adds `gettext("Or enter a model ID the list does not show")`, but
`mix gettext.extract` was never run. The msgid was in no `.pot` or `.po`, so the label rendered in English in all
seven non-English locales. `gettext_catalogues_test.exs` only checks entries that exist, so it could not see an
entry that is missing.

**Fix:** extracted and merged (exactly one new message), and filled de/es/et/fr/it/ru/zh in the register
AGENTS.md sets for each language.

**Not changed:** adding `mix gettext.extract --check-up-to-date` to `precommit` would catch this class of
mistake, but checked here it also fails on a mere line shift (reference comments carry line numbers). Every
commit would then need a re-extract. That is a policy call for the maintainer, possibly paired with
`write_reference_line_numbers: false`.

### IMPROVEMENT - MEDIUM — `tool_choice: "none"` still offered every tool (fixed)

`Completion`'s documented `:tool_choice` takes `"none"`, which means the model must not call a tool. Converse has
no `"none"`, and the adapter sent the full `toolConfig` without a `toolChoice`. That is Converse's `auto`, so the
model could call the very tools the caller had just excluded. An agent loop that forces a final answer with
`"none"` could get another tool round back.

**Fix:** `tool_config/3` leaves the caller's tools out when the choice is `"none"`. A history that holds a tool
round still declares the tools it called, by name only, as Converse requires (the existing history clause). That
leaves a much narrower opening than offering the full tool set. The test that asserted "no `toolChoice`" now
asserts that there is no `toolConfig` at all, and that a tool round declares only the called tool. The moduledoc
and AGENTS.md are updated.

### IMPROVEMENT - MEDIUM — an empty tool result is sent as an empty text block (recorded)

`translate/1` for a `tool` message sends `content: [%{"text" => tool_text(content)}]`, and `tool_text(nil)` /
`tool_text("")` is `""`. The adapter's own `text_block/1` drops blank user text because "Converse refuses an
empty text block", and the Anthropic API behind it refuses empty text blocks inside `tool_result` too. A tool that
returns nothing, such as a side-effect tool, therefore probably turns the next call into a 400.

**Not changed:** the right substitute (`content: []`, a `json` block, or a placeholder text) cannot be confirmed
without a live account, and a wrong guess is a 400 of its own. Trigger: the first live check against Bedrock.
Send a tool result of `""` and keep whichever form Converse accepts.

### NITPICK — the manual entry's placeholder is OpenRouter-shaped (recorded)

`manual_model_entry/1` keeps "Enter model ID (e.g., anthropic/claude-3-haiku)". On a Bedrock endpoint the form
of the id it now invites is `eu.anthropic.claude-sonnet-4-6`. It is cosmetic, and changing it means a new msgid
in eight catalogues. Left as is.

### NITPICK — Converse's cache token counts are not mapped (recorded)

`usage/1` ignores `cacheReadInputTokens` / `cacheWriteInputTokens`. The adapter sends no `cachePoint`, so they
are always 0 today. They need mapping only once prompt caching is sent.

## Positive observations

- The chat-shape translation keeps every downstream reader unchanged. No caller learns about Converse.
- The stop-reason mapping is conservative in the right direction: `malformed_*` reads as `"length"`, so
  `truncated?/1` keeps a broken answer from passing as whole.
- The 404 reading is narrowed to wording that says the model is unknown. An access 404 (use-case form, Legacy) is
  not turned into `:model_not_found`, which would send a fallback chain to the next model for the wrong reason.
- The tests are thorough (38, stub-only), and the PR describes a mutation pass and two live passes.
- The `Providers.Shared` split stays recorded as a TODO rather than smuggled into this PR.

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good; small, pattern-matched helpers |
| Architecture | Fits: translation at the edge, same pipeline; the `Completion` ↔ adapter cycle is a recorded TODO |
| Security | No new surface: `redirect: false`, no key or body in the logs, Bearer from the integration |
| Performance | Unchanged |
| Test coverage | Strong; the `"none"` case was asserted the wrong way, now corrected |
| Migration safety | No schema change |
| Consistency | One catalogue miss (fixed) |

**Verdict:** approve. The two fixes are in this follow-up. The empty-tool-result question waits for a live check.
