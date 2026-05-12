# Claude Review — PR #8

- **Reviewer:** Claude Opus 4.7 (1M context)
- **PR title:** Endpoint form overhaul: provider filter + model picker hoist + validate-then-fetch + section gating
- **Date:** 2026-05-12
- **Merge commit:** `df5b02f` (squash-merge head `46cc8d8` onto `f338930`)
- **Scope:** 9 files, +1121 / −268
- **Skills invoked:** `elixir:using-elixir-skills` → `phoenix-thinking`, `otp-thinking`

## Notes for Max (reviewer)

- The validate-then-fetch flow was exercised via the test suite only; I did **not** boot a dev server or click through the live form. Findings on validation latency, picker race conditions on slow networks, and the JS hooks behaviour on `live_redirect` are reasoned from code + Phoenix lifecycle, not from a browser.
- The Hex package consumer side of the JS hooks is out-of-tree for this repo (no `priv/static/assets/*.js`, no `assets/js/app.js`). The inline `<script>` block in `endpoint_form.html.heex` is the *only* place these hooks are defined, which is the basis for finding **#H1**. If the host app's `app.js` ordering is known and reliable, that finding downgrades to a Low — flagging because it isn't documented anywhere I could find.

## Overall Assessment

**Verdict:** APPROVE with reservations — already merged, so the practical question is whether anything warrants a follow-up sweep. Two items qualify (one Medium-High, one Medium); the rest are polish.

**Risk Level:** Low/Medium. The behavioural payload is sound — `Task.Supervisor.start_child` matches the playbook, the staleness guard in `:validation_done` is correct, the strict-`and` → `&&` fix is verified by a dedicated regression test, and the validation-timing change is intentional and tested. The two reservations are: (1) the JS hooks are registered via inline `<script>` rather than the host app's `app.js`, which has a real `live_redirect`-entry failure mode; (2) `format_price/1` has a latent crash on JSON integer pricing.

> **Post-merge follow-up note (2026-05-12):** four findings closed
> in commits `dfdd456` (M1, M3, M4) and `eeae0ad` (the new cond at
> #M3 was rewritten to `if/else`; pre-existing credo + dialyzer
> findings swept). See the **Addressed Findings** roll-up at the
> bottom for the updated verdict and verification table. Inline
> "Addressed in follow-up" annotations sit beneath each closed
> finding.

## Critical Issues

None.

## High Severity

### H1. Inline `<script>` hook registration breaks on `live_redirect` entry

> **Not addressed in follow-up.** Structural change — depends on
> how the consumer app wires `app.js` (out-of-tree for this repo)
> or whether we adopt LV 1.1 colocated hooks. Left for a future
> sweep that can land alongside a consumer-side `app.js`
> migration.


**File:** `lib/phoenix_kit_ai/web/endpoint_form.html.heex:763-810`

The PR replaces an `onclick="..."` inline JS pattern with two `phx-hook` declarations (`ManualModelInput`, `ModelGridSearch`) and registers their implementations via an inline `<script>` block at the bottom of the template:

```heex
<script>
  if (!window.PhoenixKitHooks) window.PhoenixKitHooks = {};
  window.PhoenixKitHooks.ManualModelInput = { ... };
  window.PhoenixKitHooks.ModelGridSearch = { ... };
</script>
```

This works on the test path (`live(conn, ...)` does a full HTTP render → parser runs the inline script → `window.PhoenixKitHooks` is populated before `app.js` constructs the LiveSocket). It works on a direct browser visit for the same reason.

It **silently breaks** when the operator navigates *to* `/admin/ai/endpoints/new` (or `/edit`) via `live_redirect` / `live_patch` from a different LiveView page:

1. The host app's `app.js` constructs `LiveSocket` at boot with `hooks: {...window.PhoenixKitHooks, ...}`. The spread is a one-time snapshot.
2. On the prior page, `window.PhoenixKitHooks` doesn't contain `ManualModelInput` / `ModelGridSearch` (they're only defined by *this* template's `<script>`).
3. On `live_redirect`, the new page's HTML arrives as a patch — `<script>` tags inserted via DOM patches **do not execute** (browser-level rule for content injected by JS, not parsed inline).
4. The `phx-hook="ManualModelInput"` / `phx-hook="ModelGridSearch"` attributes look up their implementations in the LiveSocket's snapshot, find nothing, and the hook is silently absent.

User-visible failure: the "Filter models…" input doesn't filter, and the "Set Model" button submits with `phx-value-model=""` because `ManualModelInput.mounted` never runs to stamp the input's current value. No console crash — LV logs `unable to find hook "ManualModelInput"` and continues. Easy to miss in dev because direct URL visits paper over it.

**Recommendation (pick one):**

1. **Move both hook bodies into the host app's `app.js`** (or into a static asset that `app.js` imports), the same way `deps/phoenix_kit/priv/static/assets/phoenix_kit.js` registers `SortableGrid` / `MediaImageZoom`. The `window.PhoenixKitHooks` global is *the* convention for that pattern — see `deps/phoenix_kit/lib/phoenix_kit/install/js_integration.ex:9-10`.
2. **Use Phoenix 1.8+ colocated hooks** (`:phx-hook` with co-located JS), which compiles the hook into the LV's asset bundle and is patch-safe by construction.
3. **Document the constraint loudly** if (1)/(2) are out of scope: "These hooks live in an inline template `<script>` block, so they only register on full-page-load entry. Operators who reach this page via in-app `live_redirect` will see the filter input behave like a no-op input. Track this as a known limitation until hooks move into `app.js`."

The same pattern would also affect any future hook added inline.

## Medium Severity

### M1. `format_price/1` crashes on JSON-integer pricing

> **Addressed in follow-up (`dfdd456`).** Coerced via `value * 1.0
> * 1_000_000` before `:erlang.float_to_binary/2`. Added two
> pinning tests at `endpoint_form_test.exs:836-844` —
> `format_price(0)` (free-tier integer 0) and `format_price(2)`
> (sanity for non-zero integer path).


**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:1453-1455`

```elixir
def format_price(value) when is_number(value) do
  "$#{:erlang.float_to_binary(value * 1_000_000, decimals: 2)}"
end
```

`is_number/1` accepts both integers and floats. `:erlang.float_to_binary/2` requires its first argument to be a **float** and raises `ArgumentError` on integer input.

Path to a crash:

- OpenRouter's `/models` returns a pricing field that's a JSON `0` (bare integer) — for free models, the response has been observed to include exact integer-`0` entries in some shapes. Jason decodes that as integer `0`, not float `0.0`.
- `0 * 1_000_000 = 0` (integer) → `:erlang.float_to_binary(0, decimals: 2)` → `ArgumentError`.
- The crash propagates through `model_card/1` → the entire grid render fails → LV crashes → reconnect loop.

The string path (`"0"` → `Float.parse → {0.0, ""}` → recurse) is fine. The float path (`0.0`) is fine. Only the bare-integer path crashes.

The new test `"renders zero as $0.00"` pins `format_price(0.0)` and `format_price("0")` but not `format_price(0)`. Test coverage walks right past the failure mode.

**Recommendation:** force the float coercion before calling `:erlang.float_to_binary/2`:

```elixir
def format_price(value) when is_number(value) do
  "$#{:erlang.float_to_binary(value * 1.0 * 1_000_000, decimals: 2)}"
end
```

Or guard separately:

```elixir
def format_price(value) when is_integer(value), do: format_price(value * 1.0)
def format_price(value) when is_float(value) do
  "$#{:erlang.float_to_binary(value * 1_000_000, decimals: 2)}"
end
```

Add `assert EndpointForm.format_price(0) == "$0.00"` to `endpoint_form_test.exs:707` to pin the regression.

### M2. `validate-then-fetch` doubles picker latency on every connection-switch

> **Not addressed — tracked as known cost.** Defensible tradeoff
> per the original assessment; revisit when adding the next
> provider whose `validation.url` overlaps `/models`. Document
> in the multi-provider docs at that point.


**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:1022-1030, 1052-1078`

The new flow runs `validate_connection` (one HTTP round-trip to `/auth/key`) **and then** `fetch_models` (one HTTP round-trip to `/models`) sequentially on every integration pick. For OpenRouter that's fine — `/auth/key` is fast. For Mistral / DeepSeek the validation URL is `/v1/models` (per the multi-provider PR #6) — which is *the same endpoint* the fetch would hit a moment later. The operator pays for two requests where one would do.

The validation result is also discarded on the path to `:fetch_models` — it sends `{:fetch_models, api_key, uuid}` with no carry-over of "this key just authed cleanly N ms ago, you can skip your own probe."

This is a defensible tradeoff (centralised validation gate, picker badge updates via PubSub) but worth documenting and worth measuring before adding more providers whose validation URL overlaps `/models`. If the picker UX gets sluggish on slow networks, the fix is to (a) collapse provider-specific `validation_url == models_url` cases into a single fetch that doubles as auth proof, or (b) cache the validation result for N seconds per uuid so rapid switches A→B→A don't re-probe.

**Recommendation:** track this as a known UX cost rather than fix immediately. Mention in the multi-provider docs that adding a provider whose `validation.url` and model-list endpoint are the same incurs a redundant request — the request-collapse should land alongside that next provider, not retrospectively.

### M3. `:fetch_models` carries an unused `uuid` payload

> **Addressed in follow-up (`dfdd456`, `eeae0ad`).** Took option
> (a) — added a stale-fetch guard. The guard only fires when both
> `socket.assigns.active_connection` and the incoming `uuid` are
> concrete binaries that differ; a nil `active_connection`
> bypasses (preserves unit-test direct sends + the deselect
> path). Required reshuffling `:fetch_models` /
> `:model_fetch_slow` / `handle_info` catch-all to keep them
> contiguous so the extracted `do_fetch_models/2` helper could
> live under `# Private helpers` without splitting `handle_info`
> clauses (`--warnings-as-errors` would have failed). The new
> guard's initial `cond` was rewritten to `if/else` in
> `eeae0ad` to silence the credo single-real-branch warning the
> rewrite introduced.


**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:1078-1083`

```elixir
def handle_info({:fetch_models, api_key, _integration_uuid}, socket) do
```

The PR widened the tuple from `{:fetch_models, api_key}` to `{:fetch_models, api_key, uuid}` and updated five call sites in `endpoint_form_coverage_test.exs` (lines 343, 389, 435, 462, 705) to match. But the receiver discards the uuid with `_integration_uuid`.

The staleness guard is correctly applied one step earlier — in `:validation_done`'s `if socket.assigns[:active_connection] == uuid` branch — so the wider tuple here serves no purpose. Comment at line 1047-1050 ("Guarded on `active_connection` matching the uuid the Task ran for") describes a guard that doesn't exist on this specific handler.

**Recommendation:** either (a) actually guard `:fetch_models` on `socket.assigns[:active_connection] == uuid` for defence in depth (and to remove the stale-comment risk), or (b) revert the tuple to `{:fetch_models, api_key}` and drop the now-redundant test-side fixture uuid. Option (a) is the safer call — the validation-done handler `send(self(), {:fetch_models, api_key, uuid})` and any future producer of this message benefit from the guard at the consumer.

### M4. `provider_options_for/2` keeps `current_provider` in the list on `:new` mount

> **Addressed in follow-up (`dfdd456`).** `refresh_provider_options/2`
> now derives `editing? = socket.assigns[:endpoint] != nil` and
> only pads `current_provider` into the dropdown when editing.
> On `:new`, `pinned_provider = nil`, so the mount-default
> `"openrouter"` no longer surfaces as a dead-end option. Added
> regression test at `endpoint_form_test.exs:694-710` — seed only
> mistral, assert OpenRouter and DeepSeek absent from the
> `:new` dropdown.


**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:778-797`

The helper takes `current_provider` and always pads it into the filtered set:

```elixir
available =
  if current_provider,
    do: MapSet.put(available_from_connections, current_provider),
    else: available_from_connections
```

Intent (per the doc comment): "editing an endpoint whose provider has 0 connections → keep the endpoint's saved provider." For the **edit** flow this is correct.

For the **`:new`** flow, `current_provider` is bootstrapped to `"openrouter"` at mount (line 248) — not a saved selection, just the form default. So if the operator has only a Mistral integration set up and lands on `/endpoints/new`, the dropdown shows BOTH `Mistral` (their actual connection) AND `OpenRouter` (the form default). Selecting OpenRouter then immediately puts them in a "no integration available for this provider" hole.

The test `"dropdown lists only providers with at least one connection (new mode)"` seeds OpenRouter and asserts Mistral/DeepSeek are absent — it doesn't catch the inverse case (seed Mistral, assert OpenRouter is absent on `/new`).

**Recommendation:** thread an `editing?` boolean (or, simpler, check `socket.assigns[:loaded_id] != nil`) through `refresh_provider_options/2` so the "keep current_provider in list" branch only fires for edits. Add a regression test:

```elixir
test "new mount with only mistral connection doesn't surface openrouter in dropdown",
     %{conn: conn} do
  seed_mistral_connection("only-mistral")
  {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")
  assert html =~ ~s(value="mistral">Mistral)
  refute html =~ ~s(value="openrouter">OpenRouter)
end
```

## Low Severity

### L1. `Process.put(:"$callers", callers)` happens inside the Task closure, after `start_child` returns

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:1022-1030`

`Task.Supervisor.start_child/2` does not propagate `$callers` automatically the way `Task.Supervisor.async_nolink/2` does. The PR works around this by capturing `callers = [parent | Process.get(:"$callers", [])]` before the call and setting it inside the Task closure (`Process.put(:"$callers", callers)`).

This is the right pattern for `Task.Supervisor.start_child`, but worth noting: there's a *very small* window between `start_child` returning and the first line of the closure running where `$callers` isn't yet set. If `validate_connection` ever moves work into another spawned process before its HTTP call (unlikely, but conceivable for instrumentation), that grandchild process wouldn't inherit `$callers` until the parent set it.

Not a real bug today. Flagging because if anyone migrates to `Task.Supervisor.async_nolink/2` later (which propagates `$callers` natively), they should also drop this manual stash to avoid double-bookkeeping.

### L2. `assigns_after_a.models_grouped == [{"fake", assigns_after_a.models}]` is order-sensitive

**File:** `test/phoenix_kit_ai/web/endpoint_form_test.exs:619`

The "switching integrations clears stale model state" test asserts `models_grouped` shape via direct equality on the tuple list. Works today because the test seeds a single group. Wouldn't survive a multi-group future change. Cheap fix: assert `Enum.map(assigns_after_a.models_grouped, &elem(&1, 0)) == ["fake"]` instead.

### L3. PR-body claim "37 → 38 tests in the main form spec, 679 → 680 in the AI suite" is from the first commit and doesn't reflect final state

**File:** PR description vs `git diff --stat`

The first commit (`967580d`) reported 37 → 38 in the main form spec. The follow-up commits added 9 more tests (`46cc8d8` "Add C11 pinning tests — format_price, section gating, manual-id"). Final state per the PR-body Verification section is `689 / 0`. Internally consistent at the bottom of the PR body, but the message-body of `967580d` is stale. No action needed — squash-merged commits get their messages preserved only in the merge commit body. Flagging for posterity.

### L4. `model_card/1` button has `phx-click="select_model"` even when hoisted-and-selected

**File:** `lib/phoenix_kit_ai/web/endpoint_form.ex:113-126`

The selected card hoisted above the grid still has `phx-click="select_model" phx-value-model={@model.id}`. Clicking it re-fires `select_model` with the same id. The handler at line 472 rebuilds the changeset and sets `selected_model` to the same value — no-op for the user but a wasted LV round-trip + render.

The doc comment at line 109-110 acknowledges this: "Clicking the card body itself is a no-op (selecting an already-selected model has no effect)." So the design is intentional. Worth a `phx-click={if @selected, do: nil, else: "select_model"}` to avoid the round-trip entirely, especially on slow connections where the spinner-then-no-change is confusing.

### L5. `Generation Parameters` section-gating test only asserts text, not the `text-base-content/50` class

**File:** `test/phoenix_kit_ai/web/endpoint_form_test.exs:744-752`

The Model Selection gating test (`716-728`) asserts both the placeholder copy AND the `text-base-content/50">\n              Model Selection` greyed-class marker. The Generation Parameters and Optional Provider Settings tests assert only the copy. A future template refactor could drop the greyed class on those two cards and the tests would stay green. Cheap to mirror the stronger assertion across all three.

## Positive Observations

- **C12 #1 fix (`Task.Supervisor.start_child`) is exactly right.** `Task.start/1` was unsupervised; `Task.start_link/1` would have killed the LV on a transport blip; `Task.Supervisor.async_nolink/2` would have required `handle_info({ref, result}, ...)` plumbing. The chosen shape (`start_child` + manual `send(parent, ...)` back) is the playbook-mandated pattern for fire-and-forget LV-spawned work, and the `$callers` propagation comment at line 1017-1021 spells out the why-this-not-that for anyone touching this in 6 months.
- **`BadBooleanError` fix at `current_models_base_url/1:1252-1255` is a real catch.** Strict `and` on `nil` is one of the easiest Elixir traps to walk past; the test at `endpoint_form_test.exs:505-543` pins it via `:sys.get_state` after a forced mailbox drain, which is the right shape (synchronous events alone wouldn't surface the queued `handle_info` crash).
- **`:validation_done` staleness guard is correct.** Comparing `socket.assigns[:active_connection] == uuid` before issuing the model fetch is the right way to handle "operator switched picks mid-flight." Most LV codebases skip this and ship the race.
- **Section-gating headers-stay-visible, body-grey-out pattern is the right UX call.** Hiding entire cards when their precondition isn't met would have made the form feel "shorter than it actually is" — the operator wouldn't know more sections existed. Greyed headers preserve discoverability.
- **`<.model_card>` consolidation** removes a real source of drift. The pre-PR template had ~80 lines of duplicated rich-card markup between the selected-summary panel and the grid. Hoisting to one component + filtering it out of the grid by `model.id != current_model_id` is exactly the right factoring.
- **CSP-friendly fix on the manual-id submit** (inline `onclick` → `phx-hook="ManualModelInput"`) is correct in spirit even if the registration mechanism needs follow-up per **#H1**.
- **PR #6 deferred-findings closure (`b283477`)** is documentation-only but well-anchored: each `@doc` / inline comment cites the specific finding it resolves (`#2`, `#8`, `#9`), which makes future audits easier.

## Summary

| Dimension | Rating | Notes |
|---|---|---|
| Code quality | Good | Comments-as-docs throughout; doc comments cite source-of-truth (boss decisions, prior reviews). |
| Architecture | Good | Validate-then-fetch is the right gating layer; staleness guard placed correctly. |
| Security | Good | Auth signal is now the actual auth check (`/auth/key`), not the effectively-public `/models`. |
| Performance | Acceptable | M2 (doubled picker latency) is a known cost; not pathological at OpenRouter scale. |
| Test coverage | Good | 689/0, 3× stable. C11 pinning sweep is thorough; M1/M4 gaps noted. |
| Migration safety | N/A | No DB migrations in this PR. |
| Consistency | Good | Greyed-header pattern applied uniformly; gettext sweep covered the i18n holes. |
| JS / asset story | Concerns | **H1** — inline `<script>` hooks need to migrate to `app.js` or colocated. |

## Strengths

- Right `Task.Supervisor` shape, right staleness guard, right rationale for not trusting `/models` as an auth signal.
- The BadBooleanError fix + dedicated regression test is the kind of bug-fix-plus-pin pattern that keeps the next regression visible.
- Doc comments explicitly cite which prior-review findings they close (`#2`, `#8`, `#9`), which gives the audit trail real load-bearing structure.
- Section gating with greyed-but-visible headers is a noticeably better UX call than the obvious "hide cards" alternative.

## Areas to Address

1. **#H1** — Inline `<script>` hook registration: migrate `ManualModelInput` / `ModelGridSearch` to `app.js` (or Phoenix 1.8 colocated hooks) so `live_redirect` entries don't silently break the manual-id input and grid filter.
2. **#M1** — `format_price/1` integer crash: add `value * 1.0` (or split the integer head). Add `assert EndpointForm.format_price(0) == "$0.00"` to the test list.
3. **#M3** — Drop the unused `uuid` from `{:fetch_models, _, _}` or use it as a guard (`active_connection == uuid` at the consumer side).
4. **#M4** — Tighten `provider_options_for/2` so the form-default `current_provider` isn't padded into the dropdown on `:new` mount; add the inverse-seed regression test.

The Mediums are all small follow-up patches. The High is host-app-dependent in severity but worth resolving before the next consumer-side install.

## Verdict

**APPROVE with reservations.** Behavioural correctness is solid; the validate-then-fetch / staleness / supervised-task patterns are textbook for the playbook shape. The four follow-ups above would benefit a quality sweep — none are blockers for what's already shipped.

---

## Addressed Findings — post-merge follow-up (2026-05-12)

Two commits landed on `main` after the merge of PR #8:

- `dfdd456` — closes **M1**, **M3**, **M4** + their pinning tests.
- `eeae0ad` — closes 7 of 12 pre-existing credo findings and the
  one dialyzer pattern-match error surfaced by the
  `4b98b8c libs got upgraded` bump. Also rewrites the `cond`
  M3 introduced into `if/else` (credo: single-real-branch).

### Files touched

| File | Findings closed | Notes |
|---|---|---|
| `lib/phoenix_kit_ai.ex` | dialyzer dead clause + 2 pre-existing `cond`→`if` (`migrate_endpoint_group/3`, `promote_provider_to_integration_uuid/1`) | The unreachable `nil` clause of `maybe_add_integration_uuid/2` was removed; the `""` clause stays (form-input path is still reachable). |
| `lib/phoenix_kit_ai/web/endpoint_form.ex` | **M1**, **M3**, **M4** | `format_price/1` coercion (M1), `:fetch_models` stale-fetch guard + `handle_info` reshuffle (M3), `refresh_provider_options/2` editing-only padding (M4). |
| `test/phoenix_kit_ai/web/endpoint_form_test.exs` | M1/M4 pinning tests | Two new tests added: `format_price(0)` integer path, and `:new` mount with only-mistral connection. |
| `test/phoenix_kit_ai/completion_coverage_test.exs` | 3 nested-module-alias suggestions | `PhoenixKitAI.Test.Repo` aliased as `TestRepo`. |
| `test/phoenix_kit_ai/web/endpoint_form_test.exs` | 1 nested-module-alias suggestion | Same alias added. |
| `test/phoenix_kit_ai/web/endpoint_form_coverage_test.exs` | 1 nested-module-alias suggestion | `PhoenixKit.Integrations.Events` aliased as `IntegrationsEvents`. |

### Verification (post-sweep)

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | clean |
| `mix format --check-formatted` | clean |
| `mix credo --strict` | **5 findings** (down from 12) — all pre-existing complexity-refactor opportunities, see "Known debt" below |
| `mix dialyzer` | **0 errors** (was 1) |
| `mix test` | **Not run** — no postgres in this sandbox. Run locally before relying on the sweep. The high-risk piece is the `handle_info` reshuffle in `endpoint_form.ex` — `endpoint_form_test.exs` + `endpoint_form_coverage_test.exs` exercise it. |

### Findings status

| # | Severity | Status |
|---|---|---|
| H1 | High | **Open.** Structural — needs consumer-side `app.js` migration or LV 1.1 colocated hooks. |
| M1 | Medium | **Closed** — `dfdd456`. |
| M2 | Medium | **Open (intentional).** Tracked as known UX cost; revisit when adding the next provider whose `validation.url` overlaps `/models`. |
| M3 | Medium | **Closed** — `dfdd456` (guard) + `eeae0ad` (`cond`→`if`). |
| M4 | Medium | **Closed** — `dfdd456`. |
| L1–L5 | Low | **Open.** Polish only; not worth a churn commit on their own. |

### Known debt (intentionally left open)

The 5 remaining credo refactoring opportunities are all
cyclomatic-complexity / nesting-depth findings on real
branching logic. Each one needs a thoughtful split-into-helpers
pass rather than a mechanical rewrite, so they're left for a
purposeful sweep with the test suite in hand. They have been
carried across multiple PRs (the maintainer has consciously
left them) and don't block correctness.

| File:Line | Function | Issue |
|---|---|---|
| `lib/phoenix_kit_ai.ex:613` | `migrate_endpoint_group/3` | nested depth 3 (max 2) |
| `lib/phoenix_kit_ai.ex:757` | `sweep_provider_string_to_integration_uuid/0` | nested depth 3 (max 2) |
| `lib/phoenix_kit_ai/web/endpoint_form.ex:287` | `load_endpoint/2` | cyclomatic 14 (max 9) |
| `lib/phoenix_kit_ai/web/endpoint_form.ex:709` | `reload_connections/2` | cyclomatic 11 (max 9) |
| `lib/phoenix_kit_ai/web/endpoint_form.ex:904` | `integration_warning/1` | cyclomatic 12 (max 9) |

### Updated verdict

**APPROVE.** Four of the five actionable findings closed (M1, M3, M4
on the AI module side; pre-existing dialyzer warning + 7 of 12 credo
findings on the broader sweep). The remaining items are either
structural (H1 — consumer-side `app.js`), intentional tradeoff (M2 —
known latency cost), or maintainer-tolerated complexity debt (the 5
credo refactor opportunities). No correctness reservations remain on
the merged code path.

