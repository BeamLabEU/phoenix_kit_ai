# Follow-up Items for PR #9

Triaged against `main` on 2026-09-14 (quality sweep, Phase 1).

## Fixed (pre-existing)

- ~~C1 — `main` would not compile against the locked core~~ — the core pin is `~> 2.0`; `PhoenixKit.Utils.Reorder.reorder/4` resolves at `lib/phoenix_kit_ai.ex` (`reorder_prompts/2`, `reorder_endpoints/2`).
- ~~M1 — `reorder_endpoints/2` catch-all could leak an unmatched error into the LiveView `case`~~ — the only error clause is `{:error, :too_many_uuids}`, matching the `@spec` (commit `e173dd5`).
- ~~M2 — `reorder_prompts/2` kept the old inline transaction~~ — delegates to the shared `Reorder.reorder(Prompt, …)` (commit `227f5f0`).
- ~~M3 — `<.table_default_row class={[…]}>` list into a `:string` attr~~ — `lib/phoenix_kit_ai/web/endpoints.html.heex` joins the classes.
- ~~L1 — `reorder_prompts/2` discarded the transaction result~~ — moot after M2.

## Fixed (Batch 1 — 2026-09-14)

- ~~L2 — `mount/3` assigned `sort_dir: :desc` while `parse_sort_params/1` defaulted `:asc`, so the mount value was dead~~ — `parse_sort_params/1` now defaults `:desc` (`lib/phoenix_kit_ai/web/endpoints.ex`).
- ~~L4 — the LiveView test pinned exact attribute order for the "Manual" sort option~~ — asserted through `has_element?/3` on the `<option>` (`test/phoenix_kit_ai/web/endpoints_test.exs`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ai/web/endpoints.ex` | sort default `:desc` |
| `test/phoenix_kit_ai/web/endpoints_test.exs` | order-independent "Manual" assertion |

## Verification

`mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); `mix test` 982 tests, 0 failures (2026-09-14).

## Open

- L3 — the activity-log `resource_uuid` for a reorder is the first binary of the *input* list, which `Reorder` may have filtered out; now at both `reorder_prompts/2` and `reorder_endpoints/2`. Options: source it from the rows the helper reports as touched, or record `nil`. Waiting on Max's call.
