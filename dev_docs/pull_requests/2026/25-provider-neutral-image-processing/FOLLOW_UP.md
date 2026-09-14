# FOLLOW_UP — PR #25 (Provider-neutral image processing)

Triaged 2026-09-14.

`CLAUDE_REVIEW.md` found one Medium bug and four nitpicks.

## Resolved

- **BUG - MEDIUM** — fixed on main. Chat-completions edits (the
  OpenAI-compatible default adapter, and OpenRouter with `transport: :chat`)
  were fitted against option sets they never send. Options were silently
  lost, and `:remove_background` kept its transparent wording.
  - Added the optional `Provider.image_edit_options/2` callback and the
    `Provider.edit_options/3` resolver.
  - `fit_options/4` now requires the adapter's set as well as the listing.
  - `process/4` layers endpoint defaults from the edit set.
  - Three regression tests in `images_test.exs` fail without the fix.

- **NITPICK** — fixed in a follow-up. The Playground's `handle_async`
  `{:exit, _}` handling is one clause per task, so a crashed model listing
  no longer clears an in-flight edit's busy state. Covered by a
  `playground_test.exs` test that holds an edit open while the listing
  crashes.
- **NITPICK** — fixed in a follow-up. `process_image(…, verify:)` forwards
  `user_uuid` to the verification's `vision` row; the `idempotency_key`
  stays on the edit's row. Asserted in the `verify: true` test.
- **NITPICK** — fixed in a follow-up. `@edit_capabilities` is an assign
  recomputed on listing, override and endpoint changes; the template no
  longer passes `assigns` to a function. Asserted by the option selects
  following a model override.
- **NITPICK** — fixed in a follow-up. `Providers.HTTP.private_address?/1`
  now refuses 192.0.0.0/24, 198.18.0.0/15, 224.0.0.0 and up, local-use NAT64
  and IPv6 multicast. It judges mapped, translated, compatible, NAT64 and
  6to4 IPv6 forms by their embedded IPv4. Covered by the new
  `providers/http_test.exs`.

## Open

- DNS rebinding between the host check and the connection stays the
  existing TODO in `AGENTS.md`.

## Verification

| Check | Result |
|---|---|
| `mix test` (after the nitpick follow-up) | 989 tests, 0 failures |
| New nitpick tests with the `lib/` changes stashed | 5 failures |
| `mix precommit` | clean |
