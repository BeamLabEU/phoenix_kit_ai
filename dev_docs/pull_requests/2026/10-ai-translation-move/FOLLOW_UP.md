# Follow-up Items for PR #10

Triaged against `main` on 2026-09-14 (quality sweep, Phase 1).

## Fixed (pre-existing)

- ~~M1 — a cross-session `:translation_completed` on the shared per-resource topic patched *any* open form's changeset~~ — apply is gated on `lang in socket.assigns.ai_in_flight` in `lib/phoenix_kit_ai/components/ai_translate/form_glue.ex` (commit `01ebc16`).
- ~~L3 — `extract_section/3` carried a dead third parameter~~ — `extract_section/2` (`lib/phoenix_kit_ai/translation.ex`, commit `01ebc16`).
- ~~precommit remediation (credo AliasOrder / Nesting / AliasUsage, one dialyzer dead clause)~~ — helpers `prompt_options/0`, `insert_job/1`, `validate_source_map/1` are in place.
- L2 — withdrawn by the reviewer: the asymmetric handling of core's `list_endpoints/0` vs `list_prompts/0` return shapes is correct (dialyzer proved the defensive clause dead). Recorded so it is not re-raised.

## Skipped (with rationale)

- N1 — the per-field `Regex` in `parse_response/2` is compiled per call. Markers differ per field, so precompiling buys little at real field counts; accepted at review time.

## Files touched

None in this sweep.

## Verification

`mix precommit` clean; `mix test` 982 tests, 0 failures (2026-09-14).

## Open

- L1 — `enqueue/1` checks `job_in_flight?/1` then inserts non-atomically (`lib/phoenix_kit_ai/translations.ex`), so a double click or two tabs can enqueue twice. Closing it needs a partial unique index on `oban_jobs` args, which lives in core's migration chain — a core change, not this module's.
