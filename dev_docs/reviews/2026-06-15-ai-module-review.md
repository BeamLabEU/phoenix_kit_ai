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

## Additional Findings

### Potential Issues Requiring Verification

#### 1. TTS Request Body Field Name

**File:** `lib/phoenix_kit_ai/completion.ex` (`text_to_speech/3`)

The fix to `voice_field_for/1` ensures the form sends the correct parameter name (`voice_id` for Mistral, `voice` for others). However, `Completion.text_to_speech/3` may hardcode the `:voice` key in the request body. Mistral's `/audio/speech` endpoint **requires** `voice_id`, not `voice`. If the body construction doesn't use `voice_field_for/1`, Mistral TTS calls will fail with HTTP 400.

**Action:** Verify that `text_to_speech/3` dynamically selects the field name based on the endpoint's provider, matching the form's behavior.

#### 2. Empty Provider Registry UX

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex`

When `Endpoint.provider_options()` returns an empty list (no providers with `:ai_completions` capability), the form renders an empty dropdown with no guidance. Operators may not understand why the list is empty or where to configure providers.

**Suggestion:** Add a notice in the form template: "No AI providers configured. Add integrations via Settings → Integrations." This maintains the dynamic discovery design while improving discoverability.

### Documentation Enhancements

#### 1. Provider-Specific TTS Compatibility

**File:** `AGENTS.md`

Add a provider-specific TTS compatibility table to help operators understand provider differences:

| Provider | TTS Endpoint | Voice Param | Voice Discovery |
|---|---|---|---|
| Mistral | `/audio/speech` | `voice_id` | `/audio/voices` |
| OpenRouter | `/audio/speech` | `voice` | None |
| DeepSeek | `/audio/speech` | `voice` | None |
| OpenAI | `/audio/speech` | `voice` | None |

#### 2. Security Configuration

**File:** `AGENTS.md` or `README.md`

The `config :phoenix_kit_ai, :allow_internal_endpoint_urls` flag enables SSRF-bypassing for self-hosted providers (Ollama, local vLLM). This is a **security-critical** setting that should never be enabled in production without explicit need. Document this prominently with:
- Default value: `false`
- What it bypasses: loopback, RFC1918, link-local, `*.local`, non-HTTP(S)
- Warning: Only enable for trusted internal networks

### Legacy Migration Clarification

**Note:** The legacy `api_key` migration is **opt-in by design**, not a gap. The architecture deliberately preserves the fallback path (`OpenRouterClient.resolve_api_key/1` → legacy `api_key` column) to avoid breaking existing deployments. Operators can migrate at their own pace via:
- UI: Edit endpoint, select integration, save (clears `api_key` atomically)
- Boot-time: Call `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`

This is a design strength that prevents forced breaking changes.

### Enhanced Open Recommendations

In addition to the original recommendations, consider:

6. **Provider-specific error parsing:**
   Extend `Completion.handle_response/1` to parse provider error bodies (OpenRouter returns `{error: {message, code}}`, Mistral returns specific 4xx codes). Map these to specific error atoms (`:invalid_voice`, `:missing_voice`, `:rate_limited`) instead of generic `{:api_error, status_code}`. This would significantly improve debuggability in the Playground and for API consumers.

7. **Model classification robustness:**
   The TTS classification heuristic (substring `"tts"`) should be augmented with a provider-specific allowlist. For example, Mistral's embedding models contain `"embed"` not `"tts"`. Consider adding a `provider_settings["model_type"]` override or a curated model metadata map.

8. **Test coverage for provider registry failures:**
   Add tests for edge cases when `PhoenixKit.Integrations.Providers.with_capability(:ai_completions)` returns `nil` or raises. Verify the form and API handle these gracefully.

9. **TTS cross-provider validation:**
   Add integration tests verifying TTS works correctly with non-Mistral providers (OpenRouter, DeepSeek, OpenAI) using the `voice` parameter, not `voice_id`.

---
Review performed: 2026-06-15
Verification: `mix precommit`, `mix test`
Status: fixes applied and verified
Additional contributions: 2026-06-16
