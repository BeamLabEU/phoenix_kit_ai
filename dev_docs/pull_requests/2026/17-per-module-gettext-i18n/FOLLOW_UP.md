# Follow-up Items for PR #17 (and #18)

Triaged against `main` on 2026-09-14 (quality sweep, Phase 1).

## Fixed (pre-existing)

- ~~HIGH — `Request.changeset/2` declared Ecto-derived `*_fkey` constraint names core never creates, so an FK violation raised instead of returning a changeset~~ — `:fk_ai_requests_endpoint_uuid` / `:fk_ai_requests_user_uuid` in `lib/phoenix_kit_ai/request.ex` (commit `be1c52f`), pinned by `test/phoenix_kit_ai/schema_coverage_test.exs` and `request_fk_constraints_test.exs`.
- ~~MEDIUM — `coverage_test.exs` inserted a request with a made-up `user_uuid`~~ — uses `Fixtures.confirmed_user_fixture/0` (commit `3ee397d`).
- ~~MEDIUM — `tts_test.exs` did not expect the `:timestamps` key~~ — asserts all three keys (commit `1e5c2ba`).
- ~~MEDIUM — `tts_test.exs` expected a nil TTS cost~~ — asserts a positive integer cross-checked against `TtsPricing.cost_nanodollars/3`.
- ~~NITPICK — the image-generation override test only passed `size:`~~ — passes and asserts both `size` and `quality`.
- ~~MEDIUM — `playground_voice_test.exs` set a `send_text_done/1` expectation that was never invoked~~ — mocks signal the test pid, `assert_receive` synchronises (commit `f13c3d9`, PR #22).
- ~~NITPICK — order-sensitive delete-button assertions in `prompts_test.exs` / `endpoints_test.exs`~~ — attributes pinned independently (commit `91d0bb7`, PR #22).
- The two invariants the review established by audit still hold on a larger tree: every `lib/` file that calls gettext carries `use Gettext, backend: PhoenixKitAI.Gettext` (11 files, including the new `images/operations.ex`), and `en`/`et`/`ru` carry equal msgid counts with no fuzzy and no empty `msgstr`.

## Files touched

None in this sweep.

## Verification

`mix precommit` clean; `mix test` 982 tests, 0 failures (2026-09-14).

## Open

- Core creates the `prompt_uuid` FK under two names depending on install age; this module declares both (PR #21) so it works against either. De-duplicating the constraint is a `phoenix_kit` core migration concern.
