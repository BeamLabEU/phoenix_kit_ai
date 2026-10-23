# Claude Review — PR #46

**Reviewer:** Claude Sonnet 5.5
**PR:** Model capabilities: documents in and image generation, DeepSeek and Mistral catalogues, Anthropic rules from #42, recommendations by capability (timujinne)
**Reviewed:** 2026-10-23
**Merged:** 2026-10-22, final PR commit `2b99b6f`; reached `main` inside the merge of #48 (`0f3f879`). The branch was stacked on #41, #43–#45, so its 52 commits are mostly those reviews' subjects; this review covers the last nine (capabilities, catalogues, Anthropic rules, recommendation groups).
**Other reviews:** `GPT_REVIEW.md` (Codex, 2026-10-22) — native model filters ignored the parsed capabilities (fixed in `f71dc6b`).

## Overall Assessment

**APPROVE, no new defects.** Risk: **Low–Medium**. The additions are
catalogue parsers (DeepSeek, Mistral, Anthropic `/models`), two more capability
flags (`file_input`, `image_output`) that the guard can require, Anthropic's
sampling and thinking rules, and the recommendations regrouped as
`verified` / `possible` / `experimental`. Everything stays advisory or
fail-soft: an unknown capability is `:unknown` (and only refused when the admin
turned on "only verified models"), a failed catalogue keeps the previous
snapshot and retries on a 1/5/30-minute schedule, and a model the catalogue
lacks is never invented.

## What I checked

- **Anthropic sampling.** `anthropic_sampling?/1` decides from the model id:
  `claude-opus-4-7` and later (and every Claude 5 id) take no
  `temperature`/`top_p`/`top_k`; older ones take one of the first two, never
  both. Walked the two regexes over `claude-opus-4-5-20251101`,
  `claude-sonnet-4-20250514` (the date must not be read as a minor version —
  backtracking handles it), `claude-opus-4-1-20250805`, `claude-3-opus-20240229`,
  `claude-3-5-sonnet-20241022`, `claude-fable-5-1`; all land on the right side.
  One gap (a `-latest` alias read as "newer") is fixed in the #50 review, since
  that PR is where the same function was reworked.
- **Thinking forms** are sent only in a form the catalogue lists
  (`capabilities.thinking.types.<type>.supported`), the budget form only when
  it stays below `max_tokens`, `adaptive` never — consistent with the AGENTS.md
  text and with what the compatibility layer answers.
- **Guard needs.** `:file_input` / `:image_output` are task needs, implied by
  the verbs (`generate_image` / `edit_image` / `process_image` need
  `:image_output`), and an `:unknown` is refused only under verified-only —
  matching the documented consequence for OpenAI/xAI/Z.ai endpoints.
- **Recommendations grouping** (`groups/5`): `:unfit` is dropped, a plain
  list's model is never `verified`, `unverified` lists exactly the unclear
  needs, retired models never appear, a model that does not answer in text is
  listed only when images out are needed. `rank/3` sorts priced rows by price
  then id, caps free rows at one, and keeps one place for the unpriced.
- **Snapshot schema** (V2) adds the two flag columns with a guarded `ALTER`;
  a node on V2 code with a V1 database falls back to an empty cache and logs
  (documented, and the order "migrate first" is in the upgrade notes).

## Findings

### NITPICK — `rank/3` with `limit: 1` shows only an unpriced row

`take_priced = min(length(priced), limit - min(length(unpriced), 1))` reserves a
place for the unpriced rows; at `limit: 1` that leaves zero places for priced
ones even when many exist. The default limit is larger and no caller passes 1,
so nothing breaks; a `max(…, 0)` guard or a comment would pin the intent.

### NITPICK — plain-list name heuristics are deliberately narrow

`@not_chat` / `@image_model` filter OpenAI/xAI/Z.ai ids by name. A model such as
`grok-imagine` or a future audio id without those words would be listed as
`possible` for chat. The comment owns this ("a heuristic by name, deliberately
narrow") and the row is labelled "capabilities not reported", so the operator is
told. No change.

## Positive Observations

- Pure parsers with fixtures: the catalogue tests run on `Req.Test`, no provider
  calls.
- Each recommendation row carries *why* it is not verified (`unverified`) and
  *where* its price came from, rather than a bare score.
- The recommendation panel is a LiveComponent that keeps its filters as its own
  state across parent re-renders, and the create link only prefills the form —
  nothing is saved by a link.
- `source_endpoint_uuid` is resolved server side; the new-endpoint form
  resolves a recommendation's URL from a stored endpoint, never from a
  query-string URL, so a crafted link cannot start a credentialed fetch.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Good — parsers, cache, grouping and UI separated |
| Security | Good |
| Performance | One catalogue read per base URL; panel regroups without the journal |
| Test coverage | Very good |
| Migration safety | Good — additive, guarded |
| Consistency | Good |

**Verdict:** APPROVE.
