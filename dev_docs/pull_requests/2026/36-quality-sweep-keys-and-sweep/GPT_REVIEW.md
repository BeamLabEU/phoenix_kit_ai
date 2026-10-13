# GPT Review — PR #36 and phoenix_kit_ai 0.25.4

**Reviewer:** Codex (OpenAI)
**Date:** 2026-10-13
**Reviewed commit:** `3d4463e` (release), including merge `68f3f60` (PR #36)

## Release verification

- `mix.exs`, local HEAD, origin/main, and the peeled `v0.25.4` tag agree.
- The live Hex API reports latest/stable `0.25.4`, published on 2026-10-13.
- GitHub release `v0.25.4` exists and points at the same release commit.
- The initial tree was clean. The baseline suite reproduced Claude's result:
  **1,233 tests, zero failures**, including database integration tests.

Claude's translated `:request_failed` message and comment correction are
present. The following fixes are additional, unreleased changes.

## Findings and fixes

### BUG - MEDIUM — switching model type can leave an orphaned spinner

`EndpointForm.handle_event("select_model_type", ...)` cleared the grid but
left loading indicators intact when `integration_connected` was false.
An in-flight response for the old type was then correctly dropped, leaving
nothing to clear the spinner or its slow-loading timer. This is observable
when a connection loses its connected state during discovery.

**Fixed:** Clear loading indicators and the previous error when the switch
cannot start a replacement fetch. Extended the existing blocked-fetch test
to assert that loading and the slow hint both disappear.

### BUG - MEDIUM — discovery can restore stale model details

`apply_model_fetch/2` resolved `selected_model` from the saved endpoint, even
though the operator could change or clear the form's model while the async
request was in flight. A new selection lacked its discovered details, or a
cleared saved model returned as a selected card. Parameter controls could
then describe a different model from the hidden form value.

**Fixed:** Resolve the model from `form[:model].value` when the response
arrives. LiveView tests cover choosing a model mid-fetch and clearing a
saved model, including the explicit `""` form value.

### BUG - MEDIUM — discovery still follows unchecked redirects

The PR disabled redirects for completions and provider adapters, but
`OpenRouterClient.http_get/2` still used Req's default redirect behavior.
A saved public base URL could redirect model or voice discovery to an
internal host, bypassing the host policy applied when the endpoint was saved.

**Fixed:** Set `redirect: false` on the shared discovery HTTP helper. A
stubbed redirect test originally returned a successful model list from the
redirect target; it now returns `{:error, {:api_error, 302}}` and proves that
the second request never occurs. Model, voice, and legacy key-validation
requests share this helper.

### BUG - MEDIUM — failure logs can expose credentials or user content

The endpoint form's model-fetch error handler inspected the raw reason, its
async-exit handler formatted the exception and stack, and its save rescue
formatted a full exception. Discovery's HTTP and transport-error log lines
also inspected raw reasons. Those terms can carry credentials or provider
content. Merely sanitizing the async callback is insufficient: OTP logs a
task's unhandled exception before the callback receives its exit.

**Fixed:** Use `MessageShape.describe/1` in these failure logs, preserving
tags/arity or exception types without the payload. Catch raises, explicit
exits, and throws inside `fetch_models_and_voices/4` before the async task
terminates, returning the translated `:request_failed` error. Tests inject a
canary credential into exception messages, valid transport-error payloads,
exit/throw values, and stack arguments and assert it never reaches captured
logs. Ordinary failure messages still clear the spinner and offer Retry.

## Scope and validation

No dependency, schema, migration, or published-version changes. Custom
discovery APIs that previously relied on redirects now need a direct URL,
consistent with the existing completions policy. Unexpected task failures
display a generic translated message; log diagnostics intentionally exclude
exception text and stack arguments.

- `mix test`: **1,241 tests, zero failures**, including database integration
  tests (no `PK_AI_SKIP_DB` opt-out).
- After the final test-module alias adjustment, its focused suite: **21
  tests, zero failures**.
- `mix precommit`: **passed** (warnings-as-errors compilation, lockfile
  check, Hex audit, formatting, strict Credo, and Dialyzer with the existing
  ignore file).
- `git diff --check`: **passed**.
