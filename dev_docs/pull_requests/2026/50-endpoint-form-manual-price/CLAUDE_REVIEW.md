# Claude Review — PR #50

**Reviewer:** Claude Sonnet 5.5
**PR:** Endpoint form, capabilities in plain words, providers without a catalogue, manual price and one cost order (with Anthropic pricing/thinking from #47) (timujinne)
**Reviewed:** 2026-10-23
**Merge commit:** `96ff131`

## Overall Assessment

**APPROVE with two hardening fixes applied.** Risk: **Medium** — it changes how
every chat, embedding and vision row is priced, and money limits and the daily
budget read that number. The design is sound: one module (`CallCost`) owns the
order of sources (provider > catalogue > manual > built-in table), the row says
which one it used (`metadata.cost_source`), the arithmetic is in integers
(`ManualPrice.cost/3` rounds half up with `div`), a call without tokens gets no
cost instead of a priced $0, and setting a price needs `ai.manage` at the
context (`guard_pricing/3`) as well as in the form. No defect was found in the
cost path itself. Two robustness gaps and a few notes below.

## What I checked in the cost path

- **Unit conversions.** Catalogue prices are dollars per token;
  `round(price * 1.0e12)` is micro-dollars per 1M tokens, and the recommendations
  go back with `* 1.0e-12`. Anthropic's table is dollars per 1M, so
  `round(rate * 1_000_000)`. Consistent.
- **Which model is priced.** `for_call/5` tries the answer's model, then the
  endpoint's, through all sources each time. `ManualPrice.get/1` ignores its
  `model` argument by design (it returns the price of the endpoint's own
  model), so an answer naming a variant of the endpoint's model (a dated id)
  is counted at the manual price rather than escaping the limits. For vision
  calls sent with another `model:` the endpoint is rebuilt with that model first
  (`image_op_cost/5`), so the manual price correctly does not apply.
- **`guard_pricing/3`.** A model change drops the stale price in the changeset
  (`validate_pricing/1`) and `dropped_stale?` lets that through without
  `ai.manage`; a new price for the new model, a changed amount and a removal
  all need it. An update that leaves the price alone needs nothing, so a
  non-manager's save of an unrelated field cannot trip it.
- **Form.** Without `ai.manage` the fields are not rendered (the price is
  shown as text), so a save posts no `pricing` key and `submitted_pricing/1`
  returns `:not_submitted`; a half-filled pair and a non-number are refused
  with the typed values kept. `Money.parse_dollars/1` rejects NaN, infinity,
  negatives, over $1e9 and a positive amount that rounds to 0 µ$.
- **Connection auto-pick.** `sole_usable_connection/2` picks only when exactly
  one connection has credentials; on an edited endpoint a stored connection is
  never replaced (`provider_change_connection/2`).

## Findings

### IMPROVEMENT - MEDIUM — a malformed `:anthropic_prices` setting raised inside the usage-logging path (fixed)

`AnthropicPricing.rates/0` ran `Enum.filter/2` over
`Application.get_env(:phoenix_kit_ai, :anthropic_prices, %{})`. A host that
sets it to `nil` or a string (an unset env var interpolated into config, say)
gets `Protocol.UndefinedError` — and `rates/0` is reached from
`CallCost.for_call/5`, i.e. while the row of a call that already succeeded is
being written. The module's other free-form settings (`:embedding_models`) warn
and are ignored. Fixed: anything that is not a map or a list is read as "no
configured rates" (`configured_prices/1`); per-entry validation is unchanged.
Test: `a setting that is neither a map nor a list is ignored, not raised on`.

### IMPROVEMENT - MEDIUM — an Anthropic `-latest` alias lost the caller's sampling parameters (fixed)

`Completion.anthropic_version/1` (from #46/#47) understood `claude-sonnet-4-5`
and `claude-sonnet-4-5-20250929` but not `claude-sonnet-4-5-latest`, while
`AnthropicPricing` already strips `-latest`. An unreadable id is "taken for a
newer model", so the endpoint's `temperature`/`top_p`/`top_k` for such an alias
were silently dropped though the model accepts them. The date group now also
takes `latest`. Test: ids added to `anthropic_rules_test.exs`.

### NITPICK — rates in `AnthropicPricing` are unverified

The table is stamped "as of 2026-10-22" with a link; I could not check it
against the pricing page from here. One row reads oddly and is worth a glance
by whoever owns the page: `claude-opus-5-5` at $4 / $20 is *cheaper* than
`claude-opus-5` at $5 / $25 (and the Haiku 5.5 tier switch above 100 000 input
tokens). A host can override any row with `:anthropic_prices`, and a manual
price outranks the table, so a wrong row is correctable without a release.

### NITPICK — a manual $0 price reads as a "free" model in the recommendations

`Recommendations.extra_price/3` turns a manual `0`/`0` into `0.0` prices, so
`free?/1` tags the row `:free`, `experimental?/1` moves it to the experimental
group and `one_free/1` keeps one such row. `ManualPrice.validate/1` allows 0
(a self-hosted model), but a price the operator entered by hand is not
OpenRouter's rate-limited `:free` variant. Not fixed: needs a product decision
(tag the row `:manual_price` only, or leave it).

### NITPICK — the unit is called two things

`CallCost` and `Money` say "micro-dollars … which the module calls
nanodollars"; `AGENTS.md` still defines nanodollars as "1/1,000,000 of a
dollar". The value is right (µ$); only the name is wrong. Leaving the legacy
column name alone is correct; a one-line AGENTS.md correction would stop the
two spellings from spreading.

## Positive Observations

- Nine new test files, including `image_call_cost_test.exs` (making images
  keeps only the provider's cost), `manual_price_rights_test.exs` (the
  `ai.manage` boundary at the context, not only the form) and
  `plain_catalogue_test.exs`.
- The source is recorded per row and shown as a badge ("entered by hand",
  "list price"), so an estimate is never mistaken for a billed figure.
- The connection picker is accessible (`aria-pressed`, a labelled group,
  status apart from selection) and keeps the "deleted integration" card.
- Guarding the money-limit input at the context means a script cannot do what
  the form refuses.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Good — one owner for the cost order |
| Security | Good — `ai.manage` enforced in the context |
| Performance | `rates/0` rebuilds a small map per priced call; negligible |
| Test coverage | Very good |
| Migration safety | n/a (no schema change) |
| Consistency | Good; gettext extracted for en/et/ru |

**Verdict:** APPROVE; the two hardening fixes are in this review's commit.
