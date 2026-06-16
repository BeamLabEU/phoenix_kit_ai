# 2026-06-15 PhoenixKitAI Module Review

## Scope

General review of the `phoenix_kit_ai` module, with focused attention on the
last several commits:

- `724a701` — Discover AI providers from the Integrations registry (0.9.0)
- `a605a42` — Add Mistral TTS voice picker with speaker→mood cascade (0.8.0)
- `d366413` — Add model-kind icon column + compacter endpoints toolbar (0.7.0)
- `4f4bc11` — Add model-type selector (Chat/TTS) + per-endpoint default voice (0.6.0)
- `061aa0e` — Bump phoenix_kit to 1.7.138, leaf to 0.2.22
- `8905625` — Add TTS support: PhoenixKitAI.speak/3 (0.5.0)

## Verification Run

| Check | Command | Result |
|---|---|---|
| Compile | `mix compile --force` | ✅ no warnings |
| Format | `mix format --check-formatted` | ✅ |
| Linter | `mix credo --strict` | ✅ no issues |
| Type checker | `mix dialyzer` | ✅ 0 errors |
| Test suite | `mix test` | ✅ 293 tests, 0 failures (487 excluded)* |

\* Integration tests are excluded because the local test Postgres database is
not running (`localhost:5432` refused connection). This is the same baseline
as before the fixes.

## Findings

### Bugs Fixed

#### 1. `provider_settings` were overwritten on every save

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex` (`handle_event("save", …)`)

The form rebuild `provider_settings` from only the three nested inputs it
renders (`http_referer`, `x_title`, `voice`). Any other keys persisted on the
endpoint were silently wiped every time the form was saved.

**Fix:** merge submitted values into the endpoint's existing
`provider_settings` map so unrendered keys survive.

#### 2. Stale TTS voice survived provider switches

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex`

Switching the provider dropdown cleared `model` and `base_url`, but left
`provider_settings["voice"]` intact. A Mistral voice slug could therefore be
saved onto an OpenRouter endpoint.

**Fix:** clear `provider_settings["voice"]` (and the `voices` /
`selected_speaker` assigns) when the provider changes.

#### 3. Integration change did not clear the stored voice

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex`
(`handle_event("select_provider_connection", …)`)

Picking a different integration cleared the model/voice catalogues but not the
stored default voice. If the new integration pointed at a different provider,
the old voice slug remained valid-looking but wrong.

**Fix:** reset `provider_settings["voice"]` to `""` when a new integration is
selected.

#### 4. Model id was not cleared when switching model type

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex`
(`handle_event("select_model_type", …)`)

The handler cleared `@selected_model` but not `form.params["model"]`. Because
the hidden input is bound to the form params, the old model id could survive
save and turn a TTS endpoint into one carrying a chat model id.

**Fix:** rebuild the form changeset with `model` set to `""` before assigning
the new model type.

#### 5. `voice_field_for/1` only matched exact `"mistral"` provider

**File:** `lib/phoenix_kit_ai.ex`

The helper that decides whether to send `voice` or `voice_id` only matched
`%{provider: "mistral"}`. Legacy rows and named connections store
`"mistral:my-key"`, which fell through to the generic `voice` field and would
fail on Mistral's `/audio/speech` endpoint.

**Fix:** match on `String.starts_with?(provider, "mistral")`.

#### 6. `AGENTS.md` described the old provider model

**File:** `AGENTS.md`

The agent guide still claimed providers were a hardcoded three-item list and
that adding a provider required four edits in this module. Commit `724a701`
moved to capability-driven discovery from the Integrations registry.

**Fix:**
- Rewrote the Project Overview and Multi-provider support sections.
- Added the TTS feature to the overview.
- Clarified that the module *does* use Oban for AI translation.
- Added a dedicated Text-to-speech section.
- Updated the file layout to include translation modules and TTS.

### Documentation Updates

Updated moduledocs to stop advertising an out-of-date feature set:

- `lib/phoenix_kit_ai.ex` — added `speak/3` to the Completion API list.
- `lib/phoenix_kit_ai/completion.ex` — added `/audio/speech` to supported
  endpoints.
- `lib/phoenix_kit_ai/request.ex` — added `"tts"` to `request_type` examples.
- `lib/phoenix_kit_ai/endpoint.ex` — documented `provider_settings["voice"]`.

## Open Recommendations (Not Changed)

1. **Provider changeset validation:**
   `Endpoint.changeset/2` does not call `validate_inclusion(:provider, …)`. I
   did not add it because the `provider` column still stores legacy
   integration UUIDs and `"provider:name"` strings from pre-V107 rows. Strict
   validation would break those endpoints. If/when the legacy column is fully
   migrated and only bare provider keys are stored, add the validation.

2. **TTS model classification heuristic:**
   Models are classified as TTS by checking whether the id/name contains the
   substring `"tts"`. This is pragmatic but fragile. If providers ever expose
   a modality/endpoint field, use that instead.

3. **TTS error specificity:**
   Mistral returns HTTP 400 when `voice_id` is missing, but callers receive
   the generic `{:api_error, 400}` tuple. Consider mapping known provider
   error bodies to a specific error atom (e.g., `:missing_voice`) if the
   playground or public API needs clearer feedback.

4. **Test coverage gaps:**
   The bugs fixed above are not covered by existing LiveView tests. Worth
   adding focused tests for:
   - provider switch clears voice and model,
   - model-type switch clears the model param,
   - `select_provider_connection` clears voice,
   - `voice_field_for` handles `"mistral:..."`.

5. **Empty provider registry behavior:**
   If `PhoenixKit.Integrations.Providers.with_capability(:ai_completions)`
   returns an empty list, the endpoint form renders an empty dropdown. A
   built-in fallback list would keep the form usable during registry
   misconfiguration, but it also re-introduces the hardcoded whitelist the
   recent commit intentionally removed.

## Files Changed

```
AGENTS.md
lib/phoenix_kit_ai.ex
lib/phoenix_kit_ai/completion.ex
lib/phoenix_kit_ai/endpoint.ex
lib/phoenix_kit_ai/request.ex
lib/phoenix_kit_ai/web/endpoint_form.ex
```

## Conclusion

The recent TTS and provider-discovery work is solid overall, but the form
state management around provider/type/voice switches has a few cross-cutting
data-retention bugs. The fixes above close those gaps, bring the agent guide
and module docs back in sync with the new architecture, and leave all
existing tests, credo, and dialyzer passing.

---
Review performed: 2026-06-15
Verification: `mix precommit`, `mix test`
Status: fixes applied and verified
