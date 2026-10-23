# Claude Review — PR #49

**Reviewer:** Claude Sonnet 5.5
**PR:** TaskSpec `user_limits: false` — a task whose module limits its users itself has no per-user scope in the guard (timujinne)
**Reviewed:** 2026-10-23
**Merge commit:** `300555a`

## Overall Assessment

**APPROVE, no defects found.** Risk: **Low**. A new `TaskSpec` field switches
the `:user` scope off for a task. The change is placed at the right seams:
`TaskLimits.effective/3` (`task_limits.ex:188`) returns an empty user scope,
`layers/1` blanks the user part of both the stored and the declared layer,
and every writer of a user value (`update_settings/3`, `put_user_limits/4`,
`forgive/6` of `:user`) answers `{:error, :user_limits_off}`. Because
`statuses/4` skips the user count when `limits.user == %{}`
(`task_limits.ex:555`), a task without a user scope also costs no per-user
journal query, and `check/3` can neither refuse nor warn on a user limit.

I traced every reader of the user scope (`effective`, `layers`, `statuses`,
`check`, `usage`, the Tasks page's `limits_view`, `users_at_limit`,
`limit_cells`) and every writer; none is left reading the stored or declared
user values of such a task.

## Points checked

- **Normalisation.** `Tasks` stores `user_limits: spec.user_limits != false`,
  so `nil` and any junk read as `true` — only a literal `false` turns the scope
  off, as the `TaskSpec` docs say.
- **Kept, not deleted.** Flipping a declaration to `false` leaves the stored
  `limits["user"]` and the `phoenix_kit_ai_task_user_limits` rows in place
  (`keep_stored_user/3`); flipping back restores them. `update_settings/3`
  with blank user cells is accepted (blank is not an amount) and keeps the
  stored values instead of wiping them through a form that no longer shows
  them.
- **Order of refusals.** `Guard.authorize_manage/1` still runs first, then
  `declared_spec/1`, then `user_scope/1`, so a non-manager still gets
  `:forbidden` and an unknown task still `:unknown_task`.
- **UI.** The user columns, the personal-limits block and the "People at a
  limit" query are all dropped for such a task, with one explanatory line
  (`data-user-limits-off`). A hand-crafted `save_user_limits` /
  `limit_user_pick` event for such a task reaches the context and is refused
  with the new flash.
- **Usage still counts the user** (`usage/3` docs say so): harmless — it limits
  nothing — and keeps the Tasks page's "used" figures unchanged.

## Positive Observations

- Two new test files (`task_user_limits_off_test.exs`,
  `web/tasks_user_limits_off_test.exs`) with a fake task module, covering the
  context refusals, the kept values and the rendered page.
- `AGENTS.md`, the `TaskSpec` moduledoc and the README were updated in the
  same PR.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Fits the existing layers (declared → stored → personal) |
| Security | Nothing new; `ai.manage` checks unchanged |
| Performance | Slightly better for such tasks (no per-user count) |
| Test coverage | Good |
| Migration safety | n/a (no schema change) |
| Consistency | Good |

**Verdict:** APPROVE.
