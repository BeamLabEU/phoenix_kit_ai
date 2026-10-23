# Claude Review — PR #51

**Reviewer:** Claude Sonnet 5.5
**PR:** Fix get_endpoint_by_name for endpoints created in the same second: break the tie by uuid (timujinne)
**Reviewed:** 2026-10-23
**Merge commit:** `e280fa1`

## Overall Assessment

**APPROVE.** Risk: **Low**. One `order_by` key (`asc: e.uuid`) after
`inserted_at` (`lib/phoenix_kit_ai.ex:1430`), plus a test that forces two
endpoints into the same second and puts the lower-uuid row physically last,
so only the tiebreaker can make it win. Endpoints are UUIDv7, so "lower uuid"
is also "created first": the tiebreak agrees with the order the query already
meant.

## Findings

### NITPICK — the same second-precision tie sat in two more orderings (fixed)

`inserted_at` is `:utc_datetime` on every table here, so the defect this PR
fixes is not specific to endpoint names. Two list orderings had the same hole:

- `get_prompts_with_variable/1` and the prompt search
  (`order_by: [asc: p.sort_order, desc: p.inserted_at]`): equal `sort_order`
  (the default) and equal second left the order to the planner. Added
  `asc: p.uuid`.
- `list_requests/1` (`apply_request_sorting/3`): the Usage tab pages with
  `limit`/`offset`, and AI calls are written in bursts, so a page boundary
  inside one second could repeat a row on the next page or skip one. Every
  sort field now carries the uuid as a secondary key in the same direction
  (UUIDv7, so `desc` stays "newest first"). New test
  `request_order_test.exs` pages five rows of one second one at a time and
  asserts each comes back once.

`list_endpoints` already had `asc: e.uuid` (`phoenix_kit_ai.ex:1348`).

## Positive Observations

- The test pins the *mechanism*, not the outcome: it rewrites `inserted_at`
  and touches the rows in the order that would hide a missing tiebreaker.
- No schema or index change; `limit: 1` over a unique-by-`lower(name)` index
  keeps the query cheap.

## Summary

| | |
|---|---|
| Code quality | Good |
| Architecture | Unchanged |
| Security | n/a |
| Performance | No change (one more sort key) |
| Test coverage | Good |
| Migration safety | n/a |

**Verdict:** APPROVE.
