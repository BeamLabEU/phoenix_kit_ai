# Review of the week's changes, and a hardening pass of the call path

Reviewer: Claude (Opus 5.5), 2026-11-08. Scope: everything since `11945e8`
(2026-10-29) up to `13c1ca7` — the monthly cap (#60), speech to text
(`transcribe/3`, `Transcription`), `Dictate`, `MessageParts`, the Playground
changes — plus the shared call path every verb goes through (`authorize/5`,
`with_cache/6`, the row writers, `Completion`, `Limiter`, `Cache`,
`Providers.HTTP`), the gettext catalogues, and what the admin can test of
speech to text. Three parallel read-only reviews (spend caps, call path,
translations) fed findings back; each one below was checked against the code
before it was fixed, and each fix has a test.

**Verdict:** the week's features are sound: no defect found in
`Transcription`, `Dictate` or `MessageParts` beyond one log line. The shared
call path had two high findings, a credential and answer leak through
`{:connection_error, exception}` and a usage row that could raise after a paid
call, and several medium ones. All are fixed. Risk of the changes: low to
medium. Every failure path still returns `{:error, _}`, and no public
signature lost an arity (`Budget.check/3` defaults its new argument).

## Findings and resolutions

### BUG - HIGH: client HTTP errors carried the bearer token and the answer

`Completion.post_once/4` passed every non-transport `Req` error through
unchanged. `Logger.error` then inspected it, `Errors.message({:connection_error,
r})` rendered `inspect(r)` into flashes and the row's `error_message`, and the
chat, embedding and TTS failure writers stored `inspect(reason)` in
`metadata.error_reason` without the content gate.

- **The key:** an endpoint key with a trailing newline (pasted) gives
  `%Req.HTTPError{reason: {:invalid_header_value, "authorization", "Bearer sk-…"}}`.
- **The answer:** a truncated JSON 200 gave `%Jason.DecodeError{data: body}`,
  logged four times with capture off, and retried as a transport error (paid
  three times).

Fixed:

- `post_once` sets `decode_body: false`, so Req never decodes and every caller
  already decodes itself.
- Any other error leaves as `{:http_error, module, tag}`
  (`Providers.HTTP.error_tag/1`, also used by the image adapters' door), and is
  never retried.
- `Errors.message({:connection_error, _})` names only the kind.
- One `error_reason/2` for every failure writer keeps the whole reason only
  under the gate or when it holds no text.
- `OpenRouterClient.build_headers/2` trims the key.

Test: `test/phoenix_kit_ai/call_path_hardening_test.exs`.

### BUG - HIGH: a value PostgreSQL refuses raised after a paid call, or lost the row

A NUL character in a message or an answer (jsonb refuses `\u0000`), or a
per-call `model:` over 150 characters (`varchar(150)`), raised `Postgrex.Error`
out of `complete/3` after the provider was paid; in async mode the row was
dropped, so caps and task limits never saw the call.

Fixed:

- `Request.changeset/2` cuts `model` / `endpoint_name` / `prompt_name` to their
  columns and drops NUL from every string (`Request.without_nul/1`).
- `log_usage/1` rescues database errors in the synchronous write and logs the
  class and the Postgres code.

The cache-hit test that relied on a too-long `prompt_name` failing the insert
(`guard_test.exs`) now asserts that the row is written with the name cut.

### BUG - MEDIUM (call path)

- **A 200 body that is JSON but not an object** (`[]`, `42`) raised
  `BadMapError` from `complete/3` and `embed/3`. It is now
  `:invalid_response_format`.
- **A 200 `{"error": …}` without an integer code** was a success, cached for its
  whole TTL; TTS returned it as audio bytes. Now any `error` without
  `choices`/`data` is an error: the code's status, or a 502.
- **`retry: [max_attempts: nil]`** retried for ever while holding the limiter
  slot. `max_delay: nil` slept for any Retry-After, and `base_delay: nil` raised.
  Each setting now falls back to its default with a warning.
- **`concurrency: [wait: :infinity]`** raised after the call was queued, and the
  place became a slot nobody released. `:infinity` now waits; any other
  non-integer value is the default, checked before queueing.
- **`Cache`** read ETS after `table?/0` without a rescue, so a call racing a
  cache restart raised. Each ETS step now counts as a miss.
- **`model: ""`** on the vision and image verbs named `""` on the row, the cache
  key and the request. `call_model_opts/1` now runs for them too.

### BUG - MEDIUM (spend caps, `budget.ex`)

- **One clock per check.** `Budget.check/2` took its month from one
  `utc_now()` and `GuardEvents.budget_refused/3` from a later one. A refusal
  checked just before midnight keyed its once-a-month event to the next month,
  so that month's real refusal had no notice. `budget/2` now passes one `now`
  to `Budget.check/3` and `budget_refused/4`.
- **A `user_uuid:` that is not a uuid** (a visitor id, `""`) summed against the
  uuid column, raised `Ecto.Query.CastError`, and was logged as the database
  failing, again after every real user's call. Such an id now has no user
  scope, as in `TaskLimits`.

### IMPROVEMENT - MEDIUM / NITPICK (spend caps)

- **A failed read clears the warn flag:** a failed read reads as zero, which
  cleared the flag, so the same crossing warned again after every blip. A failed
  read (`take_unread/0`) now neither sets nor clears the flag.
- **The monthly warn flag** is now keyed by month.
- **The month-scan lease** is taken atomically (`insert_new`, then a
  compare-and-swap of a lapsed one), and a slower scan can no longer write an
  older sum over a newer one.
- **`{:budget_unmigrated, _}`** now stops a vision batch whose items carry their
  own options (`VisionBatch.account_wide?/1`).

Test: `test/phoenix_kit_ai/budget_now_and_visitors_test.exs`.

### BUG - MEDIUM: logs that could carry user content (Playground, Dictate, EndpointForm)

- **The Playground's realtime debug line** inspected every xAI event, and a
  `text.done` echo carries the typed words. It now logs the event type only.
- **Task exits** were logged with `inspect(reason)` (Playground) or as
  `"tuple/2"` (Dictate, EndpointForm), which is useless.
  `MessageShape.describe_exit/1` now logs the exception's module and place,
  never its message or arguments. MessageShape's doctests now run
  (`test/phoenix_kit_ai/web/message_shape_test.exs`).

### Playground chat ran in the LiveView process

`handle_info(:do_send)` blocked the page for up to 120 s. Chat now runs in
`start_async(:chat)` like the image calls, and a second send while one runs is
ignored instead of dropping the first paid answer.

### Translations

- **191 et/ru entries corrected**, against one glossary, now
  `dev_docs/guides/translation-glossary.md` (AGENTS.md points to it). The main
  problems:
  - et "märk" for token;
  - et "kuine", not a word;
  - ru "запрос" for prompt;
  - ru "лимит «дневной лимит»" doubling;
  - masculine verbs agreeing with a bare e-mail;
  - et "Räägi" on a button that reads text aloud;
  - drifting terms: et otspunkt / lõpp-punkt, ru AI / ИИ, эндпоинт;
  - et formal plural imperatives mixed with the singular.
- **Strings that were never translated are now wrapped:** the endpoint form's
  generation parameter labels and placeholders, the model card badges, the voice
  language names, "My Application", the prompt syntax example, and the
  permission description (anchored in `translatable_labels/0`).
- **Counts now use `ngettext`:** "Showing %{shown} of %{count} requests",
  "Context / Max output: %{tokens} tokens", the translate button's counts, and
  the bytes of image data. After an abbreviated total ("1.5K") the plural is
  that of many.
- **Numbers follow the locale** (`PhoenixKitAI.Numbers`): et/ru group with a
  no-break space and use a decimal comma, where `128,000` read as 128.
- **Unclear English reworded:** "The check found changes", "could not be
  detected", "Who is notified", "Disabled prompts cannot be used for AI
  calls", the run-name error, and "Last used" (was in two casings).
- **Catalogues:** no fuzzy and no untranslated entries in en/et/ru;
  `gettext.extract --check-up-to-date` passes. Sixteen stale en fuzzy
  `msgstr`s were cleared (one said "Send" for "Seed").

## New: speech to text in the Playground

A "Speech to text" card (`Web.Playground`, AGENTS.md "Feature notes"):

- **The clip:** record with core's recorder or pick a file; it is kept and plays
  back.
- **Settings to rerun with:** another model (suggestions from the capability
  cache's hearing models), a language hint, the path (automatic / chat /
  `/audio/transcriptions`) or instructions.
- **Before any call,** a hint says which path the settings take and whether the
  guard knows the model hears.
- **Answers:** the last five are listed with endpoint, model, path, language,
  length, time and cost. Each can be copied or used as the chat message.
- **Dictate:** the chat message now has a `Dictate` button with the card's
  settings, so the component a host embeds can be tried as is.

Tests:

- `test/phoenix_kit_ai/web/playground_transcribe_test.exs`, 17 tests: both
  paths, rerun, endpoint switch, the hint, refusal, empty speech, an unreadable
  clip, the Dictate button and the log line.
- **Real browser:** checked in Chromium with a fake microphone against
  core 3.4.0's recorder (a scratch Bandit + Playwright harness, not committed).
  - Recording, playback, the answer card and the two usage rows (`source`
    `…Playground` and `…Playground.Dictate`) all appear.
  - Dictation lands at the cursor ("Order: Twenty sheets…").
  - "Use as chat message" fills the message.

## Also

- `mix.lock`: `phoenix_kit` 3.0.0 → 3.4.0, the first core with the
  AudioRecorder, and `lazy_html` 0.1.14. The pin is unchanged (`>= 2.65.0 and <
  4.0.0`).
- **Test fix:** `limiter_test.exs` had a race (`assert_received` on a message
  sent from another process); it now waits for that message.

## Not changed (recorded)

- **Usage rows are written inside a caller's transaction** (savepoint), so a
  rollback loses the row of a paid call. Writing it outside needs the async
  writer or a second connection. Trigger: a consumer that wraps AI calls in
  transactions it rolls back.
- **`log_request` records the endpoint's `temperature` / `max_tokens`,** not the
  values a call sent. Trigger: the first report that needs the sent values.
- **A 200 with `{"error": {"code": 504}}` is classified like a 504 but not
  retried,** because retries look at the HTTP status. Trigger: OpenRouter
  upstream timeouts in a retrying consumer.
- **The scan lease is not owner-checked when it is removed:** a scanner without
  a lease can remove another caller's.
- **ASCII `...` msgids** (nine) are kept: tests pin several, and some `refute`s
  would pass trivially after a change.
- **Some sentences are still built from translated fragments around a link**
  (endpoint form, prompt form). The et/ru wording works around them.
- **The test log is noisy:** core's `Cache.Registry` is not started by
  `test_helper.exs`, so it prints "Cache settings unavailable".
- **Idea:** a text-to-speech card (`speak/3`) next to speech to text; the
  Playground only has xAI's realtime voice.

## Verification

| Check | Result |
|---|---|
| `mix test` (fresh database, core 3.4.0) | 7 doctests, 2 613 tests, 0 failures |
| `mix precommit` | passes: compile and docs with warnings as errors, format, `credo --strict`, dialyzer |
| `mix gettext.extract --check-up-to-date` | up to date; 0 fuzzy and 0 untranslated in en/et/ru |
| Chromium, fake microphone | record → answer, playback, dictate at cursor, use as message |
