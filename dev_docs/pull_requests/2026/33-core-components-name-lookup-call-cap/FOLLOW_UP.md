# FOLLOW_UP — PR #33 (Core components, endpoint lookup by name, per-user call cap)

Triaged 2026-10-01.

`CLAUDE_REVIEW.md` found:
- one high-severity bug
- one medium improvement
- six nitpicks

Ships in 0.25.0.

## Resolved

- **BUG - HIGH:** the endpoints and prompts pages used `:toolbar_primary` and an
  untitled `form_section`, which exist only in unreleased core.
  - Against Hex core 2.42.1 the New Endpoint / New Prompt buttons vanished and
    `compile --warnings-as-errors` failed.
  - The toolbars use `:toolbar_actions` and the prompt form its plain card
    again. `mix compile` is warning-free on released core.
- **IMPROVEMENT - MEDIUM:** `get_endpoint_by_name/1` breaks a tie between
  non-exact matches by `inserted_at`, oldest first. Test added.
- **NITPICK:** the `badge_status/1` test now has its own describe.

## Not changed

- **NITPICK:** `String.trim` vs `btrim`, and `String.downcase` vs `lower()`.
- **NITPICK:** `lower(btrim(name))` is not indexable; the table is tiny.
- **NITPICK:** `Request.status_color/1` is unused but public.
- **NITPICK:** the stale "four settings" comment in `Budget`.
- **NITPICK:** an explicit `images_as: :pages` has a different cache key from
  leaving it out.

## Pending

- When core ships `toolbar_primary` and the optional `form_section` title, move
  the two toolbars and the prompt form over and raise the `phoenix_kit` floor in
  the same commit.
