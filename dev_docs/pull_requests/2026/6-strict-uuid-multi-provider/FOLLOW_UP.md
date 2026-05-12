# FOLLOW_UP — PR #6 (Strict-UUID Integrations + multi-provider + reasoning capture + UX polish)

Triaged 2026-05-12 (Phase 1).

`CLAUDE_REVIEW.md` opens with `APPROVE` and documents an inline
post-merge follow-up sweep on `40d4fb2` (2026-05-02) that addressed
six of eight numbered findings. This FOLLOW_UP captures the final
status of the three deferred items.

## Fixed (pre-existing — post-merge sweep on `40d4fb2`)

Documented inline in `CLAUDE_REVIEW.md` under "Addressed Findings"
(2026-05-02). Verified against current code:

- ~~**#1** — Model-fetch `base_url` resolution wrong after provider
  switch in edit mode.~~ `current_models_base_url/1` now compares
  `endpoint.provider == current_provider` before reusing
  `endpoint.base_url`; regression test in
  `endpoint_form_coverage_test.exs` pins the Mistral host.
  (`endpoint_form.ex:1246`)
- ~~**#3** — `migrate_legacy/0` masks `:error` from the reference
  sweep.~~ Top-level case flips to `{:error, {:sweep_failed,
  summary}}` when the inner sweep returns `:error`; inner rescue
  logs a `Logger.warning` with `exception=` context.
  (`phoenix_kit_ai.ex:721`)
- ~~**#4** — Lazy-promotion writes spam logs on a stuck endpoint.~~
  New `warn_promotion_failed_once/2` rate-limits via
  `:persistent_term`, same shape as `warn_legacy_api_key/1`.
  (`openrouter_client.ex:469,562`)
- ~~**#5** — `lookup_integration_uuid/2` was an N+1 across migration
  groups.~~ `snapshot_connection_uuids("openrouter")` runs once
  before the group loop; `migrate_endpoint_group/4` consults the
  map on `{:error, :already_exists}` instead of re-querying.
  (`phoenix_kit_ai.ex:526,541`)
- ~~**#6** — Two API-key masking helpers with incompatible shapes.~~
  `PhoenixKitAI.Web.Endpoints.mask_api_key/1` deleted;
  `PhoenixKitAI.Endpoint.masked_api_key/1` rewritten to the
  head + ellipsis + tail shape and reused everywhere.
- ~~**#7** — `select_provider_connection` deselect bypassed the
  changeset.~~ Deselect handler now builds `change_endpoint |>
  Map.put(:action, :validate) |> to_form/1`, matching the shape
  of `clear_model`.

## Fixed (Batch 2 — 2026-05-12)

- ~~**#2** — `validate_endpoint` no longer enforces
  `Integrations.connected?/1` (intentional behaviour change).~~
  Added a moduledoc comment on `endpoint_credential_status/1`
  (`phoenix_kit_ai.ex:2393`) documenting why the connected?
  short-circuit was deliberately dropped: the strict-UUID
  transition lets the upstream provider be the source of truth
  on whether the key authenticates, matching how the request
  path resolves credentials. Callers who specifically want "is
  this key healthy right now" should call
  `PhoenixKit.Integrations.validate_connection/2` directly —
  `endpoint_credential_status/1` is the
  `is this endpoint dispatchable` check, not a health check.
- ~~**#8** — `do_run_legacy_api_key_migration` doc was vague about
  the "any integration exists" gate being OpenRouter-only.~~
  Tightened the inline comment in `phoenix_kit_ai.ex:474` to
  spell out the scope: the gate is OpenRouter-only because the
  auto-migrator's target population is OpenRouter endpoints. A
  multi-provider deployment with a Mistral integration but
  unmigrated OpenRouter `api_key` rows will not trip the guard;
  the migration runs normally for the OpenRouter rows.
- ~~**#9** — `extract_reasoning/1` didn't honour `reasoning_exclude:
  true` on the response side.~~ Documented the intentional
  behaviour in the `extract_reasoning/1` `@doc` block
  (`completion.ex:196`): when a provider sends reasoning despite
  `reasoning_exclude: true` in the request, we deliberately
  capture it as a buggy-provider breadcrumb rather than filtering
  on the response side. Operators can correlate
  `metadata.response_reasoning` against a specific provider +
  model + request id when investigating provider compliance.
  PII / retention is still gated by `capture_request_content?/0`
  — when content capture is off, response_reasoning is dropped
  too.

## Files touched (Batch 2)

| File | Change |
|---|---|
| `lib/phoenix_kit_ai.ex` | `endpoint_credential_status/1` moduledoc paragraph documents the intentional drop of the `connected?/1` short-circuit. `do_run_legacy_api_key_migration` inline comment spells out the OpenRouter-only scope. |
| `lib/phoenix_kit_ai/completion.ex` | `extract_reasoning/1` `@doc` block explains the "buggy-provider breadcrumb" rationale for capturing reasoning that the request asked the provider to exclude. |

## Verification

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | clean |
| `mix test` | 680 tests, 0 failures |

No production-code behaviour changes in Batch 2 — pure documentation.
Existing test suite continues to pin the actual behaviours.

## Open

None.
