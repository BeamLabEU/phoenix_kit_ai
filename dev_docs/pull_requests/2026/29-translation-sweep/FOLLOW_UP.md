# FOLLOW_UP — PR #29 (TranslationSweep: one engine behind every module's AI translation sweep)

Triaged 2026-09-24.

`CLAUDE_REVIEW.md` found:
- one Critical bug
- one Medium improvement
- four nitpicks

Ships in 0.24.0.

## Resolved

- **BUG - CRITICAL:** `Activity.log/3` and `PhoenixKitWeb.Actor` need core 2.38.
  - The pin is raised to `~> 2.38` in `mix.exs`.
  - `test/core_pin_conformance_test.exs` now guards the new floor.
- **IMPROVEMENT - MEDIUM:** a non-positive sweep interval made the chain spin.
  - The interval is clamped to one minute in `TranslationSweep.settings/1`.
  - Test added.
- **NITPICK:** the `perform/1` doc now says what happens when a tick raises.
- **NITPICK:** the AGENTS.md conformance-test paths are corrected.

## Not changed

- **NITPICK:** concurrent manual runs can overshoot `max_in_flight` once. An
  advisory lock is too heavy for a soft cap.
- **NITPICK:** no fallback interval when `sweep_settings/0` raises while a
  successor is being scheduled. Consumers re-seed the chain themselves.
