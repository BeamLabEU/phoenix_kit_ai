# PR #63 — Percent-encode a non-ASCII X-Title / HTTP-Referer; send Anthropic's lifecycle[] filter

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; tests added

Merged into `main` as e90867b (fixes #62). It merged cleanly.

`OpenRouterClient.build_headers/2` now percent-encodes (UTF-8) an `X-Title` or `HTTP-Referer` value that is not
visible ASCII and spaces. Visible ASCII goes unchanged. Before, Req refused such a value and the whole call failed
with `invalid_header_value`. That happened whenever `project_title` fell back from `PhoenixKit.Settings` in
Cyrillic or with accents. The Anthropic `/v1/models` listing now sends one `lifecycle[]` per stage instead of the
joined `lifecycle=active,deprecated,retired`.

Checked and fine:
- **Every header path.** All REST calls build headers through `build_headers/2`: directly, through
  `build_headers_from_endpoint/1` (`Completion`, `Providers.OpenAICompatible`) or through
  `build_headers_from_account/1`, and the Anthropic listing too. `Realtime.Session` sends neither header. One fix
  covers every provider.
- **Round trip.** `%` is encoded as `%25` in the encoded branch, so `URI.decode/1` gives back the original. A
  value that is ASCII apart from `%` (for example "50% off") stays as it is, since it was always a valid header
  value.
- **Anthropic's filter.** The Models API reference documents `lifecycle` as an array of up to three of `active` /
  `deprecated` / `retired`, and leaves `retired` out unless it is asked for. The author checked the `lifecycle[]`
  form against the live API. The unfiltered retry on a 400 is still there as the fallback.
- **Header injection.** The ASCII test is `\A[\x20-\x7E]*\z`, so CR, LF and tab fall into the encoded branch and
  can never reach the wire raw.

## Findings

### IMPROVEMENT - MEDIUM — No test locked in the CR/LF and whitespace-only cases (fixed)

The comment on `header_value/1` promises two things no test checked. A value with a line break goes as one inert
encoded value, and a value of only whitespace sends no header. The first is what keeps a site-admin-set title from
becoming a second header line, and widening the ASCII class to `\x00-\x7F` would silently undo it. Added:
- "a title with a line break inside goes as one encoded value" (`"Atlas\r\nX-Injected: yes\tok"`)
- "a title or referer of only whitespace sends no header"

### NITPICK — OpenRouter shows the percent-encoded title as it is (not changed)

OpenRouter's app attribution will list a Cyrillic site as `%D0%90%D1%82…` unless it decodes the header. The choice
was between that, dropping the header, and failing the call. The PR picks the one that keeps both the call and the
information. An endpoint can set an ASCII `x_title` override in its own settings.

### NITPICK — The site title and URL go to every provider, not only OpenRouter (not changed, pre-existing)

`build_headers_from_endpoint/1` falls back to `site_url` / `project_title` for every endpoint, so Anthropic,
OpenAI, Mistral and the rest receive `HTTP-Referer` / `X-Title` too, although only OpenRouter uses them. That
predates this PR and is outside its scope. It is recorded here in case limiting the fallback to OpenRouter
endpoints is wanted.
