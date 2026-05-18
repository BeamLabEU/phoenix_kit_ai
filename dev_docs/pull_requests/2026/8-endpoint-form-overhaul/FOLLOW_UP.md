# FOLLOW_UP — PR #8 (Endpoint form overhaul)

Triaged 2026-05-18 against the post-merge state.

## Fixed (pre-existing)

The CLAUDE_REVIEW.md already documents two post-merge sweep commits
that closed the actionable Mediums:

- ~~M1 — `format_price/1` integer crash~~ — closed in `dfdd456`.
  Force float coercion via `value * 1.0` before
  `:erlang.float_to_binary/2`. Pinning tests added at
  `endpoint_form_test.exs:836-844` for `format_price(0)` and
  `format_price(2)`.
- ~~M3 — `:fetch_models` unused `uuid` payload~~ — closed in
  `dfdd456` (stale-fetch guard added) + `eeae0ad` (initial `cond`
  rewritten to `if/else` per credo single-real-branch).
- ~~M4 — `provider_options_for/2` keeps `current_provider` on `:new`
  mount~~ — closed in `dfdd456`. `refresh_provider_options/2` now
  derives `editing?` and only pads `current_provider` into the
  dropdown when editing. Regression test at
  `endpoint_form_test.exs:694-710`.
- ~~Pre-existing dialyzer dead-clause warning + 7 of 12 credo
  findings~~ — closed in `eeae0ad`.

Re-verified 2026-05-18: the closure annotations in CLAUDE_REVIEW.md
match the current code at the cited lines.

## Skipped (with rationale)

- **H1 — Inline `<script>` hook registration breaks on
  `live_redirect`** — confirmed still live in
  `endpoint_form.html.heex:723-757`. Structural; the fix requires
  either (a) moving `ManualModelInput` / `ModelGridSearch` into the
  host app's `app.js` (or a static asset that `app.js` imports), or
  (b) adopting Phoenix 1.8+ colocated hooks. Both are
  consumer-side / framework-version changes that don't belong in
  the AI module alone. Tracked here so the next consumer-side
  `app.js` migration sweep can close it.
- **M2 — `validate-then-fetch` doubles picker latency** — defensible
  tradeoff per the reviewer's own assessment. Cost is acceptable
  at the current provider list (OpenRouter, Mistral, DeepSeek);
  revisit when adding the next provider whose `validation.url`
  overlaps `/models`. Document the request-collapse pattern in the
  multi-provider docs at that point.
- **L1–L5** — polish only. None worth a churn commit on their own;
  fold into the next purposeful sweep of `endpoint_form` if the
  files are open anyway.
- **5 remaining credo cyclomatic / nesting-depth findings** — see
  the "Known debt" table in CLAUDE_REVIEW.md. All five are real
  branching logic in `migrate_endpoint_group/3`,
  `sweep_provider_string_to_integration_uuid/0`,
  `load_endpoint/2`, `reload_connections/2`, and
  `integration_warning/1`. Each needs a thoughtful split-into-helpers
  pass with the integration test suite in hand, not a mechanical
  rewrite. Carried across multiple PRs; maintainer-tolerated.

## Files touched

No new file changes in this triage pass — all actionable items were
already closed in `dfdd456` / `eeae0ad` per the post-merge notes.

## Verification

Re-verified by code inspection 2026-05-18:

| Check | Result |
|---|---|
| H1 inline `<script>` still live | confirmed at `endpoint_form.html.heex:723` |
| `format_price/1` float coercion | confirmed at `endpoint_form.ex` (M1 closed) |
| `:fetch_models` stale guard | confirmed (M3 closed) |
| `refresh_provider_options/2` editing-only padding | confirmed (M4 closed) |

`mix test` not re-run in this sweep — the post-merge tests added in
`dfdd456` exercise the closed paths; no new code introduced here.

## Open

- **H1** — Inline `<script>` hook registration. Awaiting a
  consumer-side `app.js` migration or LV 1.1 colocated-hooks
  adoption.
