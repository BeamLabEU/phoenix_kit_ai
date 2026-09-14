# Claude Review — PR #25

**Reviewer:** Claude Opus 5
**PR:** Provider-neutral image processing: adapters, named operations, vision, capability fitting
**Author:** Max Don (`mdon/main`)
**Merge commit:** `a32f8c2`
**Reviewed:** 2026-09-14
**Verdict:** APPROVE with reservations. One Medium bug fixed on main with regression tests, nitpicks on record.

---

## Notes for the reviewer

- The diff is large: about 3,900 lines of `lib`, 1,500 of tests and 1,700 of
  catalogues. It had already been through three rounds plus a quality sweep
  before merge (`80ffff6` … `70e2231`). This review read every new module in
  full (`images.ex`, `images/*`, `provider.ex`, `providers/*`) and the
  modified ones with their surrounding context.
- No live provider was called. The HTTP shapes, most notably OpenRouter's
  unified `POST /images` and `GET /images/models`, are taken on the PR's
  word and on its `Req.Test` bodies.
- **Behaviour change for existing consumers:** `generate_image/3` on an
  OpenRouter endpoint now posts to `/images` instead of
  `/images/generations`. It is additive in the return value (`:model`,
  `:warnings`), but a consumer pinned to the old route should know.
  Recorded under *Changed* in the CHANGELOG.

## Overall assessment

The design is sound. Callers name an endpoint and operations, adapters own
the HTTP shape, and a behaviour plus `:provider_adapters` keeps new providers
out of `Completion`/`Images`. The security posture around image URLs is
careful. Logging respects the PII gate, including error payloads.

The one real defect is in the part that makes the design honest: capability
fitting trusted an option set that one transport never sends.

**Risk level:** Medium before the fix (silent wrong output on the default
adapter); Low after.

---

## Critical issues

None.

## High severity

None.

## Medium

### BUG - MEDIUM — Chat-completions edits fitted options they never send *(fixed on main)*

`Images.process/4` fitted the request against `adapter.image_options(endpoint)`
whenever there was no model listing, and against the listing alone when
there was one.

Two edit paths send far less than that:

- **The default adapter** (`PhoenixKitAI.Providers.OpenAICompatible`).
  `image_options/1` returns `@generation_options` (`n response_format size
  quality style background output_format aspect_ratio resolution seed`).
  That set is right for `image_generate/3`. But `image_edit/4` →
  `chat_edit/5` (`providers/openai_compatible.ex:82-104`) builds a body of
  `model`, `messages`, `image_config` (aspect ratio only) and
  `provider_options`, and nothing else.
- **OpenRouter with `transport: :chat`.** The adapter delegates to the same
  `chat_edit/5`, but fitting used the `/images/models` listing. That listing
  describes the unified Images API, not the chat path, so a listed
  `background` passed fitting and went nowhere.

**Consequence.** `process_image(ep, [photo], [:remove_background])` on either
path:

- fitted `background: "transparent"` and `output_format: "png"` with no
  warning;
- never sent them;
- and, because nothing was dropped, kept the operation's primary wording:
  "make the background fully transparent".

A Gemini-class image model cannot produce alpha. The usual result is a
painted checkerboard, a JPEG-ish PNG without transparency, and an empty
`:warnings` list telling the caller everything was honoured. The
documented contract says the opposite: "an option the model does not list is
dropped with a warning, and the operation falls back to its plain-prompt
wording". A stored `image_size` default was carried along the same way.

**Confirmed before fixing.** With the `lib/` changes stashed, the new tests
fail: 3 failures in `images_test.exs`, including
`{:ok, %{aspect_ratio: "1:1", background: "transparent"}, []}` for a listed
key the adapter cannot send.

**Fix applied:**

- `PhoenixKitAI.Provider` gains an optional callback,
  `image_edit_options(endpoint, options) :: [atom()]`: the request options
  `image_edit/4` actually sends for these options. `Provider.edit_options/3`
  resolves it and falls back to `image_options/1`, so third-party adapters
  are unaffected.
- `OpenAICompatible.image_edit_options/2` returns `[:aspect_ratio]`.
  `OpenRouter.image_edit_options/2` returns the same under `transport: :chat`
  and its typed set otherwise. xAI and OpenAI send what `image_options/1`
  already says and need no change.
- `Images.fit_options/4` now requires a key to be in the adapter's set **and**,
  when a listing exists, allowed by it. The listing narrows; it never widens
  past what the transport carries. Every existing assertion still held. On
  the `/images` path OpenRouter's typed set is a superset of every option a
  listing can name.
- `process/4` layers endpoint defaults from the edit set, so a stored
  `image_size` on a chat edit is left out quietly rather than dropped with a
  warning on every call. The layering also stops computing the endpoint
  defaults twice (`Map.drop(options, @request_options -- [:mask])` replaces
  the second `endpoint_defaults/1` call).
- Tests (`test/phoenix_kit_ai/images_test.exs`):
  - default adapter: `mistral` endpoint with a stored `image_size`, and
    `:remove_background` → both implied options dropped with warnings,
    white-background wording, `image_config` carries the aspect ratio, no
    listing GET;
  - OpenRouter `transport: :chat` with a `gpt-image-1` override whose listing
    has `background` → dropped with warnings, fallback wording, chat body;
  - `fit_options/4` unit: a listed key outside the adapter's set is dropped.
- `dev_docs/guides/image-processing.md` describes the adapter-set rule and
  the new optional callback.

---

## Low / nitpicks *(all four fixed in a follow-up on main)*

### NITPICK — One `handle_async` exit clause resets all three busy flags

`web/playground.ex`, `handle_async(task, {:exit, reason}, socket) when task in
[:image_models, :edit, :describe]` sets `editing`, `describing` and
`image_models_loading` to `false` together. If a model-listing task crashes
while an edit is in flight, the Edit/Describe buttons re-enable early. The
edit's own result still lands when it arrives. Cosmetic, so left as-is.
Per-task clauses would fix it if it ever matters.

**Addressed in follow-up.** There is now one `{:exit, _}` clause per task, and
each resets only its own flag. A listing crash reports under the Load button
(`image_models_error`) instead of the edit's error line. New
`playground_test.exs` test: an edit is held open in its stub while a listing
task crashes, and the "Usually 10–40 seconds" indicator must survive until the
edit is released.

### NITPICK — The `verify:` row loses the parent call's `user_uuid`

`PhoenixKitAI.maybe_verify/5` calls `compare_images/4` with only `intent:` and
`source:`. The edit's usage row carries `user_uuid` (and `idempotency_key`),
but the verification's `vision` row does not. A per-user cost report
therefore undercounts verified edits by one vision call each. The one-line
fix is to forward `user_uuid: opts[:user_uuid]`. It was not applied because
no consumer reports per user yet.

**Addressed in follow-up.** `maybe_verify/5` forwards `user_uuid`. The
`idempotency_key` deliberately stays on the edit's own row, because it names
that call and not the check. The `verify: true` test in `images_test.exs` now
asserts both the `image_edit` and the `vision` row carry the user.

### NITPICK — `edit_capabilities(assigns)` in the template

`playground.html.heex` computes
`capabilities = PhoenixKitAI.Web.Playground.edit_capabilities(assigns)`
inside `<% %>`. Passing the whole `assigns` map disables change tracking
for that block, so the image-edit section re-renders on every assign change
anywhere on the page. It is harmless at Playground scale. Computing
`capabilities` as an assign in `apply_edit_params/2` / `handle_async(:image_models)`
would restore tracking.

**Addressed in follow-up.** `@edit_capabilities` is an assign. It is set to
`nil` in mount and on endpoint switch, and recomputed by
`assign_edit_capabilities/1` when the listing arrives and on every
`edit_change`. `edit_capabilities/1` is private now. The listing test asserts
that the option selects follow a model override and disappear on an endpoint
switch.

### NITPICK — The address policy misses a few reserved ranges

`Providers.HTTP.private_address?/1` covers loopback, RFC 1918, link-local,
CGNAT, ULA and IPv4-mapped IPv6. It does not cover NAT64 `64:ff9b::/96`,
which reaches internal IPv4 on a NAT64 network, nor 198.18.0.0/15 or
224.0.0.0/4 and above. The policy is documented as best-effort with egress
firewalling recommended, and DNS rebinding is already a tracked TODO. Worth
adding alongside that TODO rather than now.

**Addressed in follow-up.** Changes to `private_address?/1`:
- IPv4 now also refuses 192.0.0.0/24, 198.18.0.0/15 and everything from
  224.0.0.0 up (multicast, reserved, broadcast).
- IPv6 forms that embed an IPv4 address are judged by that address: mapped,
  translated (`::ffff:0:a.b.c.d`), compatible (`::a.b.c.d`), NAT64
  `64:ff9b::/96` and 6to4 `2002::/16`.
- Local-use NAT64 `64:ff9b:1::/48` and multicast `ff00::/8` are refused
  outright.

A NAT64 address embedding a *public* IPv4 is still allowed. New
`test/phoenix_kit_ai/providers/http_test.exs` covers literal addresses, so no
DNS is involved. DNS rebinding remains the tracked TODO.

---

## Checked and cleared

- **Consuming uploads while an entry is still uploading.**
  `consume_uploaded_entries/3` raises if any entry is in progress, and
  `images_ready?/1` only checks that *some* entry is done. It is not
  reachable from the browser: LiveView's client defers `phx-submit` while
  `hasUploadsInProgress(formEl)`.
- **Vision's retry without `response_format`** matches
  `{:api_error, status}`. That is exactly what
  `Completion.handle_error_status/2` returns for 400/422.
- **`latency_ms`** in `describe/3` is present: `parse_success_response/2`
  puts it on every chat response.
- **Cost** flows through `Completion.extract_usage/1`'s `cost_cents`, in
  nanodollars, same as chat.
- **Atoms from caller input:** `Operations.normalize_one/1` uses
  `String.to_existing_atom` with a string fallback. `ImageModel.option_key/1`
  converts only a fixed allowlist. The Playground resolves operation names
  against `Operations.all/0` keys.
- **`Completion.decode_image_url/1`** on a malformed percent-encoded payload
  does not raise, because `URI.decode/1` is lenient.
- **Catalogues:** no `#, fuzzy` and no empty `msgstr` in `et` / `ru`.

---

## Positive observations

- **The URL fetch policy is done properly.** Hostnames are resolved and every
  address checked, redirects are followed by hand with a re-check per hop (two
  at most), the body is streamed and abandoned past the cap, and the switch
  is deliberately separate from the endpoint base-URL one.
- **The PII gate reaches error payloads.** `log_failed_image_op_request/6`
  stores only `error_tag(reason)` unless content capture is on, so a
  provider's refusal prose about the user's photo stays out of the table by
  default.
- **Caller mistakes are not usage rows.** `input_error?/1` keeps validation
  failures that never reached a provider out of `phoenix_kit_ai_requests`.
- **The capability cache is keyed per account** (`integration_uuid`, or a hash
  of the legacy key), with a short negative TTL so an outage doesn't cost
  every request a 15 s round trip.
- **Operations degrade honestly.** Fallback wording, exclusive groups
  (`{:conflicting_operations, …}`), and a transparent-vs-JPEG conflict
  corrected with an `{:adjusted_option, …}` warning. The fix above makes that
  mechanism true on every transport.
- **The tests assert request bodies,** not just return values, for every
  adapter. That is the right level for a transport layer, and it made the
  regression tests easy to write.
- **The Playground does its provider calls through `start_async`,** so the
  page stays responsive during a 10–40 s edit.

---

## Summary

| Area | Assessment |
|---|---|
| Code quality | Good. Dense but consistent, pattern-matched, well commented |
| Architecture | Good. Behaviour + adapters + a generic layer; one seam (edit vs generation option sets) was missing, now added |
| Security | Good. Host policy per hop, bounded bodies, PII-gated error payloads; reserved and embedded-IPv4 ranges added in follow-up |
| Performance | Acceptable. `persistent_term` cache (ETS TODO already tracked); one prompt-override DB lookup per operation |
| Test coverage | Good. Bodies asserted per adapter; the chat-path fitting gap is now covered |
| Migration safety | N/A. No schema change; `request_type` gains two values in the changeset allowlist |
| Consistency | Good. Error vocabulary via `Errors.message/1`, gettext in the module backend, activity/usage conventions kept |

**Strengths**

- Provider switch is an endpoint change, not a code change.
- Careful SSRF and PII handling.
- Warnings explain every deviation from what the caller asked.

**Areas to address**

- ~~Chat-completions edits fitted options they never send.~~ Fixed.
- ~~Per-task `handle_async` exit clauses; forward `user_uuid` to the
  verification row; `@edit_capabilities` as an assign; NAT64/reserved ranges
  in the address policy.~~ Fixed in follow-up.

**Verdict:** APPROVE. The Medium bug is fixed on main with regression tests.

---

## Verification

| Check | Result |
|---|---|
| `mix test` before the fix (baseline) | 982 tests, 0 failures |
| `mix test test/phoenix_kit_ai/images_test.exs` with `lib/` fix stashed | 33 tests, 3 failures (the new assertions) |
| `mix test` after the fix | 984 tests, 0 failures |
| `mix precommit` | clean (compile --warnings-as-errors, format, credo --strict, dialyzer) |
| `mix hex.audit` | no retired or advisory packages |
| Nitpick follow-up: touched test files with its `lib/` changes stashed | 47 tests, 5 failures (the new assertions) |
| Nitpick follow-up: `mix test` | 989 tests, 0 failures |
| Nitpick follow-up: `mix precommit` | clean |
