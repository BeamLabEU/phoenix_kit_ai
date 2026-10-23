# Claude Review — PR #43

**Reviewer:** Claude Sonnet 5.5
**PR:** AI tasks and a model check before each call: a task registry, task on every usage row, refusals before HTTP (timujinne)
**Reviewed:** 2026-10-22
**Merge commit:** `d1a14c3`

## Overall Assessment

**APPROVE.** Risk: **Low to Medium** (it sits on the hot path of every
provider-calling verb). The PR adds `PhoenixKitAI.TaskSpec`, the `Tasks`
registry (`ai_tasks/0`, duck-typed like `handle_ai_usage/1`), `PhoenixKitAI.Guard`
(the call-time fitness check) and one gate, `authorize/5`, that every verb now
passes before its cache lookup and HTTP call. A refusal is a `status: "error"`
usage row marked `metadata.refused`, so sinks and spend never count it. The
design choices hold up against the code: unknown capability lets a call through
unless `ai_guard_verified_models_only` is on, `:json` is soft, and
`provider.require_parameters` is only sent when the model's parameter list is
actually in the cache. No defect found in this PR on its own; the one
cross-PR gap (translation failures reporting `unclassified` for the new
refusals) is recorded in the PR #45 review, where it was fixed.

## Findings

### IMPROVEMENT - MEDIUM — a refused call costs one synchronous insert

`refuse/4` (`lib/phoenix_kit_ai.ex:4378`) writes a usage row for every refused
call, in the caller's process. The guard events are deduplicated per window;
the rows are not. A public caller sitting past a task limit or a budget cap
turns every request into one `INSERT`, which is the traffic a cap exists to
shed. Not changed: the rows are what makes a refusal visible on the Usage tab
and what the "Refused" filter reads. A per-window aggregate (one row with a
counter) or a rate limit on refusal rows would fix it, at the cost of a design
change to the journal. Worth doing the first time a host reports it.

### NITPICK — the 404 → `:no_provider_for_params` rule is shared

`Completion.handle_error_status(404, …)` (`completion.ex:149`) now matches
"requested parameters" for every caller, including embeddings, TTS and the image
adapters (`providers/http.ex:103`), where it yields
`{:no_provider_for_params, []}` with an empty list because only
`chat_completion/3` fills the parameter names in (`with_sent_params/2`). Only
OpenRouter produces that message and only when `require_parameters` was sent,
which only chat does, so it cannot fire elsewhere in practice. Not changed.

## Reviewed and sound

- **Order of the gate** (`authorize/5`): endpoint usable → model fits →
  task limits → spend caps → cache → HTTP. A cache hit is still refused at a
  cap, by design ("a cap is a stop switch").
- **`spends?`**: only a `process_image/4` dry run skips limits and caps, and it
  still has its fitness checked. The comment records why `dry_run:` is not read
  inside `admit/4` for every verb.
- **Registry** (`tasks.ex`): `:persistent_term` keyed by the module set, rebuilt
  only when the set changes or a minute after a build in which an `ai_tasks/0`
  failed; `ModuleRegistry.all_modules/0` is itself a `persistent_term` read
  (checked in core), so the per-call lookup is cheap. A raising callback is
  logged by class and message, never swallowed into a half registry.
- **Unknown task key** is logged once per node through the request cache's flags
  table rather than `persistent_term`, which would GC globally per new key.
- **`require_parameters`** strips only what the model's list lacks, never
  `tools`, `response_format` or `max_tokens`, and records `stripped_params` on
  the row; the warning is once per endpoint and parameter.
- **Anthropic rules**: `thinking` is sent only in a form the catalogue lists;
  `temperature` and `top_p` never together.
- **Cache hit rows** carry the guard's metadata and the task, and a hit names
  its own `request_uuid`, not the first answer's (`{:replace, value}` in
  `RequestCache.fetch/4`).
- **`Guard.admit/4`** tokens are bound to task and user and expire; a token
  for another task or user is ignored and the call is checked normally.

## Positive Observations

- `refuse/4` records caller info, user, attribution and task without the
  message content, so the PII gate is untouched.
- `Request.refused?/1` and the Usage tab's "Refused" filter keep refusals out of
  success/error statistics.
- 595 lines of guard tests plus a 500-line `request_rules_test.exs` for the
  per-provider request rules (Anthropic sampling and thinking,
  `require_parameters`).

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Good: one gate, one wrapper, a new verb has to join both |
| Security | Good: no content in refusal rows, no credential in messages |
| Performance | Good: registry and caps are cheap; refusal rows are the cost |
| Test coverage | Very good |
| Consistency | Good |
