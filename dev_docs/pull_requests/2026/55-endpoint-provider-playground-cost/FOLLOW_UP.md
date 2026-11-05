# PR #55 — follow-up

## No findings

The GPT / Codex review rechecked `follow_offered_provider/2` and `response_usage/2` and found no defect: a new endpoint follows the offered provider while keeping typed params, an existing endpoint keeps its saved provider, and a provider-free cost is read only from a usage row of the expected endpoint (none is shown when async logging has not written it yet, as documented). Re-verified on 2026-10-28: `follow_offered_provider/2` is unchanged since the review; `response_usage/2` was changed afterwards by PR #56 and its follow-up (how it waits for an asynchronously written row, reviewed in `56-playground-cost-async-log/`), and still reads a cost only from a row whose `endpoint_uuid` is the expected one.

## Open

None.

## Claude review — 2026-11-05

See [the review](CLAUDE_REVIEW.md).

- **Fixed:** Playground results are tied to the endpoint they were started for.
- **Not changed:** a connection that becomes usable starts no model fetch; the chip on an
  OpenRouter cache hit.
- **Corrected 2026-11-05:** that fix went further than the bug, and threw away a paid edit
  or description that finished after a switch, with no message. Only the model list is tied
  to its endpoint now; an edit or a description is shown under the model that gave it.
