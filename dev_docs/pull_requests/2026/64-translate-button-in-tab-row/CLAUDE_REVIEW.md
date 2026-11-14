# PR #64 — Put the AI translate button at the end of the language tab row

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one small fix, one sibling follow-up open

Merged into `main` as b5f9403. It merged cleanly.

`<.ai_multilang_tabs>` now puts the AI Translate button at the end of core's language tab row, instead of in a row
of its own under the tabs. Two things changed with it:

- **Progress row.** The progress bar and the slow-run hint get a row under the tabs only while there is something
  to show: a run in flight, a finished bar, or the hint.
- **`class` and `ai_row_class`.** `class` now pads the whole block. `ai_row_class` styles only that progress/hint
  row, and its default lost the `-mt-3 px-6` pair it needed when it sat beside core's padded div.

With AI off or a single language, the component renders exactly core's tabs, as before.

Checked and fine:
- **Tailwind sees the new classes.** The arbitrary class `[&>div:last-child]:mb-0`, which takes off core's `mb-4`
  on the switcher, is scanned by the host: the module declares `css_sources/0` → `[:phoenix_kit_ai]`.
- **Narrow widths.** Core's `:tabs` switcher is `flex-wrap`, and the tab column is `flex-1 min-w-0`, so on a phone
  the tabs wrap under each other and the `shrink-0` button keeps its place at the end. It never overflows.
- **Ids and hooks.** The PR adds no form, id or hook. The button keeps `aria-haspopup="dialog"` and
  `aria-expanded`, and it stays after the tabs in DOM order, so the tab order is tabs first, then the button.
- **Strings.** The PR adds no new gettext strings.
- **Call sites.** Every consumer uses the bundled component, never the old row by hand: catalogue's four forms,
  projects' `form_parts.ex` and publishing's `edit.ex`. The button component itself (`<.ai_translate_button>`)
  is unchanged.

## Findings

### IMPROVEMENT - MEDIUM — Projects and publishing still pass the old `ai_row_class` with `-mt-3` (open; sibling repos)

`phoenix_kit_projects` (`web/components/form_parts.ex:260`) and `phoenix_kit_publishing` (`web/edit.ex:371`) both
pass `ai_row_class="flex items-center gap-3 -mt-3"`. That value was tuned for the old layout, where the row had to
climb back over core's `mb-4`. Now the row sits under a tab row with `mb-2`, inside a plain block (`class=""` in
publishing; projects' class carries no flex). So `-mt-3` pulls the progress row 4 px up into the language tabs.
This happens only while a translation runs, the only time the row is drawn. The PR's claim that the row "cannot
overlap the tabs whatever `class` the host passes" holds for the default, not for these two values.

Not fixed here. The component cannot reliably undo a caller's negative margin: class precedence follows stylesheet
order, and stripping tokens from a host's string would be guesswork. The fix belongs to the two sibling repos: drop
their `ai_row_class` and let the default apply. Projects' `class="[&>div:last-child]:mb-0"` still does what it
meant, because it now lands on this wrapper and takes the tab row's `mb-2` off when no progress row follows.

### NITPICK — With `show_header`, the button floated between the header and the tabs (fixed)

The tab row is `items-center`. With core's header on (`show_header={true}`), the left column is header plus tabs,
so the button was centred on both and sat beside neither. No consumer passes `show_header` to this wrapper today,
but the attr is documented. The button's cell is now `self-end` when the header is on, so it drops to the tabs'
line. Two tests pin it: one for the header on and one for the default without it. The first fails with the PR's
code.

### Gate: a new HIGH `hex.audit` advisory on `grpc_core` 1.0.5 (fixed; not the PR's)

`mix precommit` failed at `hex.audit` on EEF-CVE-2026-121808: memory exhaustion via compressed Erlang terms in the
Erlpack codec of `grpc_core`. The advisory was published after #63's gate passed. `grpc` comes in only through
`xai` (`~> 1.0`). `grpc_core` 1.0.6, which `grpc` 1.0.5 allows, is still flagged, so both move to 1.1.0, the first
clean release (`mix deps.update grpc grpc_core`, lock only). `hex.audit` is clean after the change, and the full
suite passes on it.

## Validation

- `mix precommit`: exit 0.
- `mix test` on a scratch database: 7 doctests and 2631 tests, all passing, nothing excluded, exit 0 with seed
  945840. One earlier full run had a single failure: `EndpointBaseUrlGuardTest`, where an "internal name is refused
  by `create_endpoint/2`" check got `{:ok, _}`. It passed in three runs of that file on its own and in a full rerun
  with the same seed. The guard deliberately accepts a name that does not resolve within its 2 s budget
  (`Endpoint.@base_url_resolve_timeout`), so the `:inet_db` hosts-table lookup must have overrun under full-suite
  load. That flake predates this PR and is unrelated to it.
