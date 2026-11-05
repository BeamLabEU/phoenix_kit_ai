# PR #13 follow-up

Claude review completed on 2026-11-05; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** `any_openrouter_integration_exists?/0` reads through
  `PhoenixKit.Settings.Setting`, so it works on a named-schema install.
- **Not changed:** `rescue _ -> true` still marks the migration complete after a
  passing read failure; rare, with the fallback intact. Reasons in the review.
- **For an affected install:** one that ran this on a named schema holds a marker for
  a migration that never ran. Deleting `ai_legacy_api_key_migration_completed_at` lets
  it run on the next boot.
