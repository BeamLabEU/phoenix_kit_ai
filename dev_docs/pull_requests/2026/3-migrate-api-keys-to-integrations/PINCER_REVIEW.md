# PR #3 Review — Migrate API key management to centralized PhoenixKit.Integrations

**Reviewer:** Pincer 🦀
**Date:** 2026-04-06
**Verdict:** Approve

---

## Summary

Migrates the AI module's API key management from local per-endpoint storage to the centralized Integrations system. 7 files, ~460 lines. Endpoints now reference integration connections by UUID, with legacy `api_key` field fallback for backward compatibility.

---

## What Works Well

1. **Clean migration with backward compat** — `build_headers_from_endpoint/1` tries Integrations first, falls back to `endpoint.api_key`. Existing setups won't break.
2. **Integration picker** — endpoint form uses the shared `IntegrationPicker` component instead of a raw password field. Consistent UX.
3. **`required_integrations: ["openrouter"]`** — correctly declares dependency, so the Integrations settings page shows OpenRouter when AI module is enabled.
4. **PubSub subscription** — LiveView subscribes to integration events and refreshes connection list on changes. Real-time UI.
5. **Provider field renamed** — `provider` field now stores connection UUID instead of just "openrouter". More flexible for future multi-provider setups.

---

## Issues and Observations

### 1. OBSERVATION: Legacy `api_key` field kept on endpoint schema
The `api_key` field remains in the endpoint schema for backward compatibility. This is correct for now but should be tracked for removal in a future version once all endpoints are migrated.

### 2. OBSERVATION: No migration guide for existing users
If a user has existing endpoints with `api_key` set, they need to manually set up the OpenRouter integration in Settings and reconnect their endpoints. No automated migration path. Acceptable for now, but worth documenting.

---

## Post-Review Status

No blockers. Clean migration PR. Ready for release.
