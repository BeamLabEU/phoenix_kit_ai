# PR #58 — AI sub-permissions, task providers and task disablement

Reviewer: GPT / Codex · Date: 2026-10-27 · Merge: `5b1fbf1`

### BUG - MEDIUM — private task reasons remained visible after losing ai.manage (fixed)

The Tasks page had event-time checks but no `phoenix_kit_scope_changed/1` callback. Core keeps a viewer who still holds base `ai` on the page after revoking a sub-key. Already-loaded private flag/block reasons, management controls and editors consequently remained rendered. The page now rebuilds its permission-dependent data and clears editors on every scope change. The regression uses core's real hook, opens a lift editor, revokes `ai.manage`, and checks that both private reasons and the editor disappear; regrant reveals the permitted reasons without restoring the editor.

### BUG - MEDIUM — revoking endpoint management left the endpoint form open (fixed)

The form checked `ai.manage_endpoints` at mount and save, but core's base-key route gate allowed the live page to stay after a revoke. Other form events could still drive model discovery with the endpoint's connection. The form now leaves through `phoenix_kit_scope_changed/1` as soon as that sub-key is lost. While the form remains authorised, it also refreshes manual-pricing and capability-declaration controls. A core-hook regression asserts the redirect after a real role-permission revoke.

Also traced the once-only role backfills and failure flags, stored-key masking, translation Embed authorisation, task-provider precedence, callback isolation/timeout/re-entry, and task-disable checks on calls and realtime sends. No additional change to those paths. The retention callback integration is recorded in the #57 review.

### IMPROVEMENT - HIGH — clear the existing dependency audit failures (fixed)

Validation initially found security advisories in the existing lockfile. Resolved within the current dependency constraints: Bandit 1.13.1 → 1.14.0, Hackney 4.8.6 → 4.9.1, and its QUIC dependency 2.1.1 → 2.1.3. `mix hex.audit` now reports no retired or security-advisory packages. No dependency requirement or package version was changed.

## Validation

- `mix test`: 2,291 tests, 0 failures, 5 existing exclusions, using PostgreSQL and the Hex dependency configuration.
- `mix precommit`: passed warnings-as-errors compilation, unused-lock check, Hex audit, formatting, strict Credo and Dialyzer (three existing configured suppressions, no unnecessary suppressions).
- Focused checks of the retention and scope-refresh fixes: 162 tests, 0 failures. The final full run also covers the pricing override regression.
- `git diff --check`: passed.
