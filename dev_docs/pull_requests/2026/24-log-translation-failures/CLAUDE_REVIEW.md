# PR #24 Review — Log `ai.translation_failed` activity entries for TranslateWorker discards

**Author:** timujinne
**Reviewed:** 2026-09-10
**Verdict:** APPROVED — merged, with one bug fixed and a regression test added

---

## The change

Before this PR, `PhoenixKitAI.TranslateWorker` only wrote an activity entry
(`ai.translation_added`) on a successful translation. A terminal failure —
either `perform/1`'s setup-failure branch (bad args, unknown adapter, missing
resource) or `fail/3`'s two terminal `cond` clauses (deterministic discard, or
a retryable reason with attempts exhausted) — broadcast on PubSub but left no
audit trail, so an operator had no way to see a discarded translation short of
querying `oban_jobs` directly.

The PR adds `log_failed/2`, mirroring the existing `log_added/2` (same
best-effort `Code.ensure_loaded?`/`function_exported?` guard, same rescue), and
a `classify_reason/1` function that reduces the raw failure `reason` term to a
short, static `{category, detail}` pair before it reaches activity metadata —
deliberately never serializing the raw term, since some failure shapes (a
changeset, an adapter's arbitrary return value, an exception message) can embed
resource content.

Coverage is thorough: a new unit-test file drives `classify_reason/1` directly
(including a dedicated "no sensitive payload ever survives" test), and a new
DB-backed integration-test file proves the entry actually lands for both
terminal sites, including the "still retrying — stays silent" case that must
**not** log (matching the existing broadcast's own silence during a pending
retry). `translate_worker_test.exs` was correctly switched from
`ExUnit.Case` to `PhoenixKitAI.DataCase`, with a good explanation for why: the
new best-effort Ecto call in the setup-failure branch can otherwise race a
concurrently-shutting-down async test's sandbox owner and take the test process
down with an unrescuable `:exit`.

---

## Findings

### BUG - MEDIUM — `classify_reason/1`'s persist-error detail was unreachable dead code *(fixed on main)*

`persist/2` always wraps `safe_put_translation/2`'s error as `{:persist_error,
reason}` before calling `fail/3` (`translate_worker.ex:176`). When the
adapter's `put_translation/4` returns a shape `safe_put_translation/2` doesn't
recognize, that inner `reason` is itself `{:bad_put_translation, other}` — so
the value that actually reaches `classify_reason/1` in production is the
**nested** `{:persist_error, {:bad_put_translation, other}}`.

The PR's clause order was:

```elixir
def classify_reason({:persist_error, _reason}), do: {"persist_error", nil}

def classify_reason({:bad_put_translation, _other}),
  do: {"persist_error", "bad_put_translation"}
```

Elixir matches clauses top-to-bottom, and `{:persist_error, _reason}` matches
*any* 2-tuple tagged `:persist_error` regardless of what's nested inside —
including `{:persist_error, {:bad_put_translation, other}}`. So the specific
clause below it never fires from any real call site; it only matched a bare
`{:bad_put_translation, _}` tuple, which nothing in the module ever produces
at the top level. Every persist failure — including the "adapter returned a
malformed shape" case the specific clause was clearly written to distinguish —
collapsed to `{"persist_error", nil}`, losing the one piece of diagnostic
detail the feature exists to capture. The `{:persist_error, {:exception,
_message}}` case (the adapter's `put_translation/4` crashing) had the same gap,
with no dedicated clause at all despite `{:adapter_error, {:exception, _}}`
getting one.

Confirmed empirically before fixing:

```elixir
iex> PhoenixKitAI.TranslateWorker.classify_reason({:persist_error, {:bad_put_translation, %{foo: 1}}})
{"persist_error", nil}   # expected {"persist_error", "bad_put_translation"}
```

The PR's own test suite didn't catch this because the unit test called
`classify_reason/1` with the *bare*, never-actually-produced shape
(`{:bad_put_translation, :whatever}`), and the integration-test file had no
coverage of the persist-failure path at all.

**Fix applied:**
- Reordered `classify_reason/1` so `{:persist_error, {:bad_put_translation,
  _other}}` and a new `{:persist_error, {:exception, _message}}` clause sit
  above the generic `{:persist_error, _reason}` catch-all, and removed the
  now-genuinely-unreachable bare `{:bad_put_translation, _other}` clause.
- Fixed the unit test to exercise the real, wrapped shape (and added the
  `{:persist_error, {:exception, _}}` case), including in the no-leakage test.
- Added `test/support/fake_translatable_persist_failure.ex` (a `put_translation/4`
  that returns a non-tuple) and a new integration-test `describe` block in
  `translate_worker_failure_logging_test.exs` that drives a full
  `perform/1` → `do_translate/1` → `persist/2` → `fail/3` round trip
  (stubbed AI response, no live network) and asserts the activity row carries
  `"reason" => "persist_error", "reason_detail" => "bad_put_translation"` —
  locking in the fix at the same layer the PR's own tests operate at.

---

## Verification

| Check | Result |
|---|---|
| `mix test test/phoenix_kit_ai/translate_worker*.exs` | 26 tests, 0 failures |
| `mix precommit` | clean (format, compile --warnings-as-errors, credo --strict, dialyzer) |
