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

## Open (deliberately not fixed)

- **NITPICK** — the Playground's `handle_async` `{:exit, _}` clause resets
  all three busy flags at once. Cosmetic.
- **NITPICK** — the `verify:` vision row does not carry the parent call's
  `user_uuid`. Forward it when a per-user cost report exists.
- **NITPICK** — `edit_capabilities(assigns)` in the template disables change
  tracking for the image-edit block.
- **NITPICK** — `Providers.HTTP.private_address?/1` misses NAT64
  `64:ff9b::/96` and a few reserved IPv4 ranges. Take it together with the
  existing DNS-rebinding TODO in `AGENTS.md`.

## Verification

| Check | Result |
|---|---|
| `mix test` | 984 tests, 0 failures |
| `mix precommit` | clean |
