# Follow-up Items for PR #3

Triaged MISTRAL_REVIEW and PINCER_REVIEW against `main` on 2026-04-24.
Both reviewers approved with no blockers — items below are the
observations and "suggested improvements" they flagged.

## Fixed (Batch 1 — 2026-04-24)

- ~~**Pincer obs 1 / Mistral suggestion**: legacy `api_key` field lingers
  without deprecation signalling~~ — `endpoint.ex` moduledoc now marks
  `api_key` as **Deprecated**, directs new endpoints to Integrations,
  and flags the field for removal in a future major version.
- ~~**Mistral suggestion**: no runtime signal when the legacy
  `endpoint.api_key` path is hit~~ — `openrouter_client.ex`
  `resolve_api_key/2` now routes the fallback through
  `warn_legacy_api_key/1`, which emits a `Logger.warning` identifying
  the endpoint (name + uuid) when a non-empty legacy key is used. Blank
  keys don't log — quiet for users who have already migrated.
- ~~**Pincer obs 2 / Mistral suggestion**: no migration guide for
  existing users~~ — `AGENTS.md` gained a "Migrating from legacy
  `endpoint.api_key`" section with a three-step walkthrough and
  explanation of the column's deprecation timeline.
- ~~**Mistral suggestion**: validate integration connection before
  endpoint save~~ — opted for a soft warning rather than blocking save,
  to keep legacy endpoints (literal `provider: "openrouter"` + set
  `api_key`) working. `endpoint_form.ex` `save_endpoint/2` now composes
  the flash via `save_success_message/2`, which checks
  `PhoenixKit.Integrations.connected?(provider)` and appends a notice to
  the success flash when the integration is disconnected AND there is
  no legacy `api_key` fallback. Save still succeeds.

## Skipped (with rationale)

- **Mistral suggestion**: data migration script to rewrite existing
  endpoints with `provider: "openrouter"` to use a real integration
  UUID. Skipped — core `PhoenixKit.Integrations` already has
  `run_legacy_migrations/0` covering the settings-key rename path, and
  the AI module's own legacy column is kept working via
  `resolve_api_key/2`. Writing a migration would need product-level
  scoping (which tenant → which connection) that this module can't
  supply.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_ai/endpoint.ex` | Moduledoc: mark `api_key` as deprecated |
| `lib/phoenix_kit_ai/openrouter_client.ex` | `warn_legacy_api_key/1` helper emitting `Logger.warning` on fallback |
| `lib/phoenix_kit_ai/web/endpoint_form.ex` | `save_success_message/2` + `integration_warning/1` — soft warning in post-save flash |
| `AGENTS.md` | New "Migrating from legacy `endpoint.api_key`" section |

## Verification

- `mix compile --warnings-as-errors` ✓
- `mix format --check-formatted` ✓
- `mix credo --strict` — same pre-existing nitpick on `endpoint_form.ex:137`
- `mix test` — 82 tests, 0 failures

## Open

None.
