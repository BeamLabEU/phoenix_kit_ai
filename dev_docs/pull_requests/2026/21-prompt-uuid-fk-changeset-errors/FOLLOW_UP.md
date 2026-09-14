# Follow-up Items for PR #21

Triaged against `main` on 2026-09-14 (quality sweep, Phase 1).

## Fixed (pre-existing)

- ~~MEDIUM — the PR failed its own gate on credo `Design.AliasUsage`~~ — `alias PhoenixKit.Test.Fixtures` in `test/phoenix_kit_ai/coverage_test.exs`.
- ~~MEDIUM ×3 — stale tests (`:timestamps` key, nil TTS cost, image-generation stored default)~~ — all repaired (commit `1e5c2ba` and the current `image_generation_test.exs`).
- Declaring both `prompt_uuid` constraint names is correct, not redundant — the rationale comment in `lib/phoenix_kit_ai/request.ex` is what keeps a future clean-up from deleting one; pinned by `request_fk_constraints_test.exs`.

## Files touched

None in this sweep.

## Verification

`mix precommit` clean; `mix test` 982 tests, 0 failures (2026-09-14).

## Open

- IMPROVEMENT - HIGH — nothing runs `mix test` automatically: `precommit` covers compile / format / credo / dialyzer only, and the repo has no `.github/workflows`. The review's failure mode (tests red across several releases, found by hand) can recur. Adding a `test` step to the `precommit` alias or a CI workflow is a repo-policy change — waiting on Max's call.
