# Claude Review — PR #33

**Reviewer:** Claude Sonnet 5.5
**PR:** Move the AI admin pages onto core components; add endpoint lookup by name and a per-user call cap
**Author:** Dmitri Don (`mdon/main`)
**Date:** 2026-10-01
**Merge commit:** `8ef484d`

## Notes for the author

- Reviewed against the core the repo actually resolves: Hex `phoenix_kit` 2.42.1
  (`mix.lock`), not the sibling `../phoenix_kit` checkout. Those two differ, and
  that difference is the main finding.
- The affected pages were not clicked through in a browser. Findings come from
  the compile output and from reading the component sources in `deps/`.

## Overall Assessment

**APPROVE with reservations.** The context and budget work is clean and
well tested. The UI migration depends on two core changes that are on core's
`main` but not in any Hex release, so against released core it dropped both
"New …" buttons and compiled with warnings that fail `mix precommit`.

**Risk level:** Medium. The fix is small and has been applied.

## High Severity

### BUG - HIGH — UI migration needs unreleased core

Compiling against Hex core 2.42.1 gives three warnings:

```
undefined slot "toolbar_primary" for component ...TableDefault.table_default/1
    lib/phoenix_kit_ai/web/prompts.html.heex:40
undefined slot "toolbar_primary" for component ...TableDefault.table_default/1
    lib/phoenix_kit_ai/web/endpoints.html.heex:30
missing required attribute "title" for component ...FormSection.form_section/1
    lib/phoenix_kit_ai/web/prompt_form.html.heex:7
```

- `table_default` in Hex 2.42.1 only declares `:toolbar_actions`. `:toolbar_primary`
  and the optional `form_section` `title` exist only in the unreleased
  `../phoenix_kit` checkout, which also reports version 2.42.1.
- Effect on a host running released core: the **New Endpoint** and **New Prompt**
  buttons are not rendered at all (an undeclared slot is silently dropped), and
  `mix compile --warnings-as-errors` (the first step of `mix precommit`) fails.
- The `~> 2.38` floor in `mix.exs` would not have protected anyone, because no
  released core has these features.

**Fixed.** The two toolbars use `:toolbar_actions` again and the prompt form
keeps its plain `card`. Both work on released and newer core. Move to
`:toolbar_primary` and the untitled `form_section` once core ships them, raising
the floor in the same commit. Until then it needs `PHOENIX_KIT_PATH` to compile
clean, which is the trap this PR fell into.

## Medium

### IMPROVEMENT - MEDIUM — name lookup tie-break was non-deterministic

`lib/phoenix_kit_ai.ex` `get_endpoint_by_name/1`: when no endpoint matches the
name exactly, the unique index on `lower(name)` still allows
`" Twin"` and `"Twin "` to coexist, and `ORDER BY exact DESC LIMIT 1` then
returns either one. That is a nasty thing to have a spend-bearing call resolve
by. **Fixed** by adding `asc: e.inserted_at` as the second sort key, with a test.

## Low

- **NITPICK** — `get_endpoint_by_name/1` trims with `String.trim/1` in Elixir
  (any Unicode whitespace) but with `btrim` in SQL (spaces only), and downcases
  with `String.downcase/1` against Postgres `lower()`. A name carrying a tab, or
  non-ASCII case folding that differs by locale, will not match. Not changed:
  names are typed in a form, and the lookup is a convenience.
- **NITPICK** — `lower(btrim(name))` cannot use the `lower(name)` index. A
  sequential scan over an endpoints table of a few dozen rows is fine.
- **NITPICK** — `Request.status_color/1` is no longer called anywhere in `lib/`.
  It is public, so left in place.
- **NITPICK** — the `badge_status/1` test sat inside the
  `get_endpoint_by_name/1` describe block. Moved to its own.
- **NITPICK** — `Budget.settings/0` comment still says "the four settings"; it
  reads five keys. Cosmetic, not changed.
- **NITPICK** — `caller_material/2` keys `images_as: :pages` differently from
  omitting it, though the prompt is identical. Costs one extra model call after
  upgrade for callers who pass it explicitly; harmless.

## Positive Observations

- `:user_calls` is added through the existing `@scopes` / `@settings` tables,
  with a separate `@user_scopes` guard in `status/2`. Warn-once flags are keyed by
  scope, so `:user` and `:user_calls` cannot clear each other.
- The unit difference is documented where it bites: the moduledoc and the
  `:warning` telemetry note that `spent` / `limit` are call counts for
  `:user_calls`, and the log line says "calls" rather than "nanodollars".
- `calls/2` keeps `status == "success"` as a literal so the core partial index
  still applies, with the existing comment explaining why. `spent/3` keeps its
  fail-open `rescue` / `catch :exit`, so a malformed `user_uuid` yields `0`, not a
  crash.
- `source_prefix:` escapes `\`, `%` and `_`, and there is a test for the
  wildcard case. Empty and `nil` prefixes are no-ops.
- `images_as:` only touches the cache key when given, so existing entries keep
  their keys. Test coverage includes the cache-key interaction.
- The new `{:budget_exceeded, :user_calls}` message has `et` and `ru`
  translations. `mix gettext.extract --merge` produces no drift.
- Gettext coverage of the modal labels (`ID`, `Status`, `Latency`, …) and the
  `ngettext` conversions are real i18n fixes.

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good |
| Architecture | Good; the UI half assumed an unreleased dependency |
| Security | No concerns; LIKE input escaped, no new SQL interpolation |
| Performance | Fine; one seq scan on a tiny table |
| Test coverage | Good for budget, name lookup, `source_prefix`, `images_as` |
| Migration safety | n/a, no migrations |
| Consistency | UI pages now match core components |

## Verdict

Approve once the unreleased-core dependency is removed, which this review
does. Ships in 0.25.0.
