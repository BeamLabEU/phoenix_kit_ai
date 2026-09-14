# FOLLOW_UP — PR #26 (Structured output, spend caps, request cache, extract_text)

Triaged 2026-09-14.

`CLAUDE_REVIEW.md` found two Medium bugs, one Medium improvement and three
nitpicks.

## Resolved

- **BUG - MEDIUM** — fixed on main. `dry_run:` lifted the spend cap on
  every verb, but only `process_image/4` honours it.
  - `authorize/3` now takes a `spends?` flag, and only `process_image/4`
    derives it from `dry_run:`.
  - Covered by `budget_cache_test.exs` "dry_run: does not lift the cap on a
    verb that ignores it".
  - The `process_image/4` dry-run test also asserts it still passes at a
    spent cap.
- **BUG - MEDIUM** — fixed on main. A prose answer to a JSON request on
  `describe_image/3`, `extract_text/3` or `compare_images/4` left only a
  zero-cost error row, so the spend caps never saw the paid call.
  - `Images.describe/3` / `compare/4` now hand the unparsed result to
    `:on_no_json`, and the verbs log a normal success row from it.
  - The error branch skips the duplicate failure row.
  - Covered by the extended "free text needs no response_format…" test.
- **IMPROVEMENT - MEDIUM** — fixed on main. A caller cache key on
  `extract_text/3` ignored `fields:`.
  - `fields:` is now part of the caller-key material.
  - Covered by "extract_text under one caller cache key still asks again
    when the fields change".
- **NITPICK** (URL inputs key on the URL string) — documented in
  `dev_docs/guides/spend-caps-and-caching.md`.

## Open

- **NITPICK** — `Translatables.valid_entry?/1` warns on every `find/1`,
  which means once per translation job, not at boot. Left as-is: it only
  fires for a broken config.
- **NITPICK** — `process_image(…, verify:)` re-runs an uncached
  verification on every cache hit of the edit. Whether a stored edit should
  be re-verified is a product call.

## Verification

| Check | Result |
|---|---|
| `mix test` at the merge (baseline) | 1025 tests, 0 failures |
| New/extended tests with the `lib/` changes stashed | 3 failures |
| `mix test` after the fixes | 1027 tests, 0 failures |
| `mix precommit` | clean |
