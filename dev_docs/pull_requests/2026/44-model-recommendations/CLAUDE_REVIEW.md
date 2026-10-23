# Claude Review — PR #44

**Reviewer:** Claude Sonnet 5.5
**PR:** Model recommendations for AI tasks and a shared endpoint picker with fitness and capability badges (timujinne)
**Reviewed:** 2026-10-22
**Merge commit:** `98c0bdd`

## Overall Assessment

**APPROVE.** Risk: **Low**. Read-only on the data side: `Capabilities` gains
`name`, `prompt_price`, `completion_price` and `text_output` (ETS only, not in
the DB snapshot), `PhoenixKitAI.Recommendations` ranks live catalogue data
("cheapest fit" and "already worked in this task, last 30 days"), and
`Web.Components.TaskModelPicker` / `CapabilityBadges` are extracted from the
endpoint form so a consuming module's settings form can reuse them. The
"Create endpoint with this model" link only prefills the new-endpoint form; the
person saves it.

## Findings

### NITPICK — "Already worked" lists a model that only failed

`worked_by_task/2` (`lib/phoenix_kit_ai/recommendations.ex:174`) groups every
non-refused, non-cached row by task, model and operator, `calls` counting all
statuses and `errors` the non-success ones. A model whose ten calls all failed
is listed under "Already worked in this task" with a 100% error share. The
column makes it visible, but the heading promises more than the query checks.
Not changed: filtering to `calls > errors` would hide exactly the models an
operator should be warned off.

### NITPICK — after a restart the first 10 seconds show unpriced rows

The DB snapshot holds only the flags, so until the first refresh
(`@initial_refresh`, 10 s) `Capabilities.catalogue/1` returns the endpoints' own
models with `prompt_price: nil` and `text_output: nil`. `candidates/3` treats
`text_output: nil` as text (`!= false`) and `rank/3` puts them in the unpriced
group, so the panel can list the endpoints' own models as "price not known"
rows, named by their id, before the real ranking replaces them. Narrow window,
no wrong action possible. Not changed.

### NITPICK — the picker queries on every render

`TaskModelPicker.picker/1` runs `Tasks.endpoint_options/1` and, without a
`recommendations` assign, three more queries per render. The moduledoc says so
and tells a `phx-change` form to pass `recommendations`; nothing enforces it.
Not changed.

## Reviewed and sound

- **Batching**: `for_tasks/2` reads the catalogues once and asks the journal
  twice for all tasks (medians, models that worked), and `Web.Tasks` uses it.
- **Fitness is strict**: `candidates/3` keeps only `Tasks.assess/2 == :fit`, so an
  unverified model is never recommended; retired models are dropped,
  deprecated ones marked.
- **Ranking never mixes units**: per call when the size of a call is known,
  by input price alone (marked `:rough`) when it is not; unpriced rows come
  after priced ones with one place kept; at most one free-tier model.
- **Prices**: a negative "varies" price from OpenRouter is `nil`, not a bargain
  (`price/1`); Anthropic rows are unpriced and are never mapped onto an
  OpenRouter model by name.
- **Journal queries** exclude `metadata.refused` and `metadata.cached`, so
  neither inflates calls nor the error share.
- **Prefill** (`EndpointForm.prefill/2`): an `integration_uuid` this install does
  not have is ignored; nothing is saved by the link; HEEx escapes `name` and
  `model` from the query string. The link is rendered only for a scope with the
  `ai` permission, the same that guards the form.
- **`<details>` state** survives re-renders through `JS.ignore_attributes(["open"])`.

## Positive Observations

- The estimate line says which of the three sources (declared, journal,
  rough) priced the list.
- Capability badges moved to one component, so the form, the picker and the
  Tasks page cannot drift apart.
- 602 lines of `Recommendations` tests and 369 for the picker.

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Good: one source of truth for badges and ranking |
| Security | Good: link prefills only, gated by `ai` |
| Performance | Good: two journal queries for all tasks |
| Test coverage | Very good |
| Consistency | Good |
