# Claude Review — PR #23

**Reviewer:** Claude Opus 5.5
**PR:** Standardize AGENTS.md; single-source the version and green the suite (mdon)
**Reviewed:** 2026-11-05 (post-merge, against current `main`)
**Merge commit:** `1e965cb`

## Overall Assessment

**APPROVE.** Risk: **Low**. No open finding. Moving the inline hooks into the bundle
fixed a real failure (morphdom does not run a script tag it inserts, so the hooks
vanished after `live_redirect`), and the namespaced names avoid the last-write-wins
fold.

## Findings

None open. Checked against current `main`:

- **`@version Mix.Project.config()[:version]`** is read at compile time, when Mix has
  this project on its stack, also when built as a dep. Nothing reads it at run time.
- **Hooks clean up.** `PhoenixKitAIManualModelInput`, `PhoenixKitAIModelGridSearch` and
  `PhoenixKitAIScrollIntoView` each remove their listeners in `destroyed()`, and the
  grid's observer is disconnected. No hook binds to `document` without removing it.
- **The hooks as moved resolved once at `mounted()`.** Both were later made to reapply
  on every patch; `AGENTS.md` records that as a landmine.
- **Preflight:** a broken test database now stops the run with the reason, as this
  review's first run showed.

## Positive Observations

- The new preflight's comment explains what `psql -lqt` got wrong: it asked as the
  shell's user over a socket, not as the configured role.
- The scroll listener moved to a container hook that unbinds in `destroyed()`.
  `AGENTS.md` now points at it as the shape to copy for a page-level listener.

**Verdict:** APPROVE.
