# Claude Review — PR #31

- **Reviewer:** Claude Opus 5.5
- **PR:** Refuse a translation response with marker lines nobody asked for (timujinne/fix/translation-markdown-sections)
- **Date:** 2026-09-24
- **Merge commit:** `460bff0`

## Overall Assessment

**Verdict:** APPROVE after a fix. One high-severity bug: legitimate content
could never be translated. Fixed in the follow-up.
**Risk level:** Medium before the fix (a permanent, paid failure on some
content); low after it.

The PR closes two silent-corruption paths in `Translation.parse_response/2`:

- A model that turns `## Heading` into `---HEADING---` used to get the
  field cut at the first such line and returned as `{:ok, _}`. The fixture
  shows 135 of 1325 characters.
- A spaced or non-ASCII marker line (`---SIZE AND USABLE SPACE---`) used to
  stay inside the value.

Both now return `{:parse_error, {:unexpected_markers, names}}`. There is also
a new `{:placeholder_echo, fields}` check for a trailing note that quotes an
unbound `{{slot}}`. Both are retryable, and a retry already refreshes the
request cache (`TranslateWorker.retry_cache_mode/1`, `translate_worker.ex:504`),
so the retry reaches the model again. Verified against the producing code:

- The whole-line/boundary split in `marker_line/1` matches what
  `extract_section/2` actually stops at (`\n---[A-Z0-9_]+---`,
  case-insensitive), so every line that truncates a capture is accounted for.
- Markdown rules (`---`), table separators (`|---|`, `--- | ---`) and
  decorative rules (`--- * ---`) contain no letter or digit, so they are
  content. The test suite covers each of these.
- `\r\n` responses work: `\s*\z` in `@marker_line` absorbs the `\r`.
- The unbound-slot echo carve-out keeps the older "unrequested markers
  don't leak" behaviour.

## High Severity

### BUG - HIGH — marker-shaped lines that belong to the source are rejected on every attempt

`lib/phoenix_kit_ai/translation.ex` (`unexpected_markers/2` as merged)

The guard does not look at the source. Any source value containing a line
such as `----- Original Message -----`, `--- OR ---` or `--- END ---` is
translated faithfully, and the translation is then refused:

```elixir
handle_ai_response("---BODY---\nHallo\n\n----- Ursprüngliche Nachricht -----\nVon: Bob",
                   %{"body" => "Hi\n\n----- Original Message -----\nFrom: Bob"})
#=> {:error, {:parse_error, {:unexpected_markers, ["Ursprüngliche Nachricht"]}}}
```

Before the PR this content passed: `extract_section/2` reads past a spaced
line. Because the error is retryable, every job for such a resource makes
three paid calls and then fails. `TranslationSweep` re-admits the pair after
its 24-hour back-off, so this repeats every day, and the content can never be
translated.

**Fixed.** `parse_response/3` takes `sources:` (a field map or a list of
strings), and `handle_ai_response/2` passes the source fields. The response
may carry as many `:line`-kind marker lines (the kind `extract_section/2`
reads past) as the sources contain. The line text is not compared, because
the model translates it. Boundary-kind lines (`---NOTE---`) are never
covered: they truncate the capture whatever their origin, so rejecting them
is still correct. `marker_line_name/1` became `marker_line/1`, which returns
`{name, :boundary | :line}`. Four tests were added under "marker-shaped lines
the source carries".

## Low

### NITPICK — a boundary-shaped line in the source is still a deterministic retry

A source value with `---NOTE---` on its own line fails all three attempts,
because `unexpected_markers` is retryable. This is better than before (a
silently truncated field was persisted), and the case is rare in catalogue
and publishing content. Telling it apart would need the source in
`retryable?/1`.

**Not changed.** Trigger: a discard log that shows this pattern.

### NITPICK — `unexpected_markers` names are content

The names are translated heading text, and they reach `Logger.warning` and
the Oban `errors` column through `inspect(reason)` in `TranslateWorker.fail/3`.
That is the same exposure the existing `{:unexpected_response, body}` reason
already has. The activity-log classification stays static
(`{"parse_error", "unexpected_markers"}`), which is the path that is
PII-gated.

**Not changed.**

### NITPICK — `placeholder_echo` catches only notes that quote a placeholder

This is acknowledged in the code comment. The real fix is on the prompt side
(never render an unbound slot), and the §9.2 guard in
`Prompt.unbound_placeholders/2` already covers it.

**Not changed.**

## Positive Observations

- Real captured responses are used as fixtures, and there is a positive
  control (`headings_kept.fr-FR.txt`) that proves Markdown headings are not
  rejected.
- The "error, not repair" reasoning is right and is written next to the code:
  the heading's level and translated text are gone from the response.
- Both new reasons are classified for the activity log and marked retryable,
  and both have tests.
- The duplicated requested marker case (`## Description` → a second
  `---DESCRIPTION---`) is caught. Before, it silently took the first half.

## Summary

| Area | Rating |
|---|---|
| Code quality | Good |
| Architecture | Good: the parser stays pure, and the worker only classifies |
| Security | No change |
| Performance | Negligible: one extra line scan of the response and sources |
| Test coverage | Good; extended for the source-carried case |
| Migration safety | N/A |
| Consistency | Matches the existing parse-error and retry conventions |

**Verdict:** APPROVE; the one bug is fixed in the follow-up.
