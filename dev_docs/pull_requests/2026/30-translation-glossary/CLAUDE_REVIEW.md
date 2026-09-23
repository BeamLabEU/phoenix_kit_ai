# Claude Review — PR #30

- **Reviewer:** Claude Opus 5.5
- **PR:** Add a terminology glossary to AI translation prompts (timujinne/feature/translation-glossary)
- **Date:** 2026-09-23
- **Merge commit:** `a8b65ff`

## Overall Assessment

**Verdict:** APPROVE. No bugs found; the findings are about discoverability
and documentation.
**Risk level:** Low.

The PR adds a `{{Glossary}}` prompt variable, backed by a per-language
setting (`ai_translation_glossary_<lang>`) that overrides a shared one
(`ai_translation_glossary`), plus a three-valued `glossary:` option on
`Translation.translate_fields/6`. Things verified against the producing code:

- **Rendering is single-pass.** `Prompt.render_content/2`
  (`lib/phoenix_kit_ai/prompt.ex:258`) is one `Regex.replace`, so a glossary
  that contains `{{...}}` is never re-substituted.
- **The §9.2 unbound-placeholder guard is not tripped.**
  `Prompt.unbound_placeholders/2` blanks bound values before it scans, and
  `Glossary` is bound on every call, `""` included.
- **The cache stays correct.** `RequestCache.key/4` hashes the rendered
  messages (`lib/phoenix_kit_ai.ex:2599`), so a glossary edit is a new key
  and never replays an answer made under the old terms.
- **The option does not leak.** `do_translate/6` passes only
  `[:source, :attribution, :cache]` on to `ask_with_prompt/4`, and the
  activity entry (`log_request/4`) records no glossary text.
- **Every caller gets the feature.** `TranslateWorker` and `FormGlue` both
  go through `translate_fields/6`, so both pick up the settings path
  without changes.

## Medium

### IMPROVEMENT - MEDIUM — the glossary does nothing on existing installs, silently

`lib/phoenix_kit_ai/translations.ex:293`. `do_ensure_prompt/0` never rewrites
an existing shared prompt, which is the right call because operators can edit
it. The side effect is that on every install provisioned before this release,
setting `ai_translation_glossary` does nothing: no slot in the prompt, no
warning, and no request-metadata flag. The code comment records this, but
nothing an operator or host developer would read does.

**Resolution:** documented in `AGENTS.md` (Feature notes) and in the 0.23.2
CHANGELOG as an upgrade step. Detecting it at runtime ("a glossary is bound
but the template has no slot") would take a second prompt fetch or a new
"unused variable" signal in `ask_with_prompt/4`. That is more than the gap is
worth for now. The trigger to build it is the first operator report of a
glossary that "doesn't work".

### IMPROVEMENT - MEDIUM — new settings keys and a reserved variable name were undocumented

`AGENTS.md` listed neither the glossary settings nor the prompt variables that
are now reserved (`SourceFields`, `Glossary`). **Fixed:** the Settings section
and the `translation.ex` architecture note now cover both, including that a
blank value cannot be stored and `delete_setting/1` is how a language falls
back to the shared key.

## Low

### NITPICK — no base-language fallback

`Translations.glossary/1` matches `target_lang` exactly, so a glossary stored
under `_de` never applies to a `de-DE` target. This is documented in AGENTS.md
and not changed. Adding `de-DE → de → shared` is a contract change, and it
should wait until a host actually mixes the two forms.

### NITPICK — two uncached settings reads per translation

`glossary/1` calls `Settings.get_setting/1` (an uncached DB query) up to twice
per call. This is not changed: the endpoint and prompt keys next to it read the
same way, and the LLM call costs far more than two indexed point queries.
`get_settings_cached/2` is the switch if this ever shows up in a profile.

### NITPICK — an empty glossary leaves an extra blank paragraph

With no glossary configured, the `{{Glossary}}` line in
`default_prompt_content/0` renders as a blank line between two blank lines.
The model does not care. Keeping the slot on its own line is easier for an
operator editing the prompt to read. Not changed.

## Positive Observations

- The three-valued `:glossary` contract (absent / `nil` / binary) is
  documented and tested at the seam. The injected resolver and the
  message-based `never_called/0` probe prove that the settings are *not*
  consulted, and this cannot be faked by a rescued raise.
- The heading is bound together with the body, so "no glossary" renders as
  nothing instead of a dangling "TERMINOLOGY:" header.
- A settings failure falls back to "no glossary" and logs a warning instead
  of failing the translation.
- The integration tests hit a real database and record a real finding: the
  Setting changeset rejects blank values.

## Follow-up applied

- `test/phoenix_kit_ai/translation_glossary_prompt_test.exs`: a new test
  renders the shipped template through `Prompt.render_content/2` with no
  glossary, a blank one and a real one. It pins that the slot disappears
  completely and that the terms arrive with their heading. Before this, each
  half of that seam had its own tests but they were never run together.
- `AGENTS.md`: glossary settings, reserved variables, and the note that
  existing installs must add the slot to their prompt.

## Summary

| Area | Rating |
|---|---|
| Code quality | Good |
| Architecture | Good: one variable, no new process, no new table |
| Security | No concerns: operator-authored config, never user input |
| Performance | Negligible (two point queries per translation) |
| Test coverage | Strong |
| Migration safety | Safe: existing prompts untouched |
| Consistency | Matches the existing Translations settings pattern |

**Verdict:** APPROVE. Ships in 0.23.2.
