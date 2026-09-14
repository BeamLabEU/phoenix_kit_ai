# Spend caps, the request cache, structured output and telemetry

How the cross-cutting controls on every verb work, what they promise and
what they deliberately do not. The code is `PhoenixKitAI.Budget`,
`PhoenixKitAI.RequestCache`, `PhoenixKitAI.StructuredOutput` and the
`with_cache/6` + `cached_row/4` pair in `PhoenixKitAI`.

## Units

`cost_cents` on a usage row holds millionths of a dollar — the module
calls them *nanodollars* (a legacy misnomer kept for compatibility);
`1_000_000` = $1. Every budget setting and every number `Budget` returns
is in that unit. `set_limit(:global, 5_000_000)` is a five-dollar cap.

## Spend caps (`PhoenixKitAI.Budget`)

| setting | scope |
|---|---|
| `ai_daily_budget` | every call the module makes |
| `ai_daily_budget_per_endpoint` | one endpoint |
| `ai_daily_budget_per_user` | one `user_uuid:` |
| `ai_budget_warn_percent` | warn once per crossing (default 80) |

`0` means no cap. `Budget.set_limit/2` writes them under the `"ai"`
settings module; there is no admin form yet.

What a check costs: one cached batch read of the four settings (the
settings cache is invalidated on every write, so a new cap applies at
once) and, per scope that has a cap, one aggregate over the last 24 hours
of success rows. With no caps set the requests table is not touched.

Semantics, in order of how often they surprise:

- **Rolling window, not a calendar day.** Spend from 23:00 still counts at
  09:00; a row older than 24 hours drops out mid-morning and frees spend.
- **Reached means stopped.** `remaining <= 0` refuses; a cap of exactly
  the amount spent is not room for one more call.
- **Cached answers are refused too.** A cap is a stop switch: once spent,
  the module answers nothing, so a runaway site goes quiet rather than
  half-quiet. `process_image/4` dry runs (`dry_run: true`) skip the check
  — they spend nothing and never reach a provider. No other verb honours
  `dry_run:`, so on those it lifts nothing.
- **No reservation.** The check reads the table; concurrent callers can
  overshoot by their in-flight calls. Atomic reservation is a TODO.
- **Fails open.** A database error reads as zero spend and no cap, so a
  blip does not refuse every call. The panel split on this; availability
  won, and the module logs the failure.
- **Warnings fire from `check/2` only.** `status/2` is pure so a dashboard
  polling it does not consume the once-per-crossing warning. The flags
  live in a small ETS table (never `persistent_term`, whose writes are a
  global GC); `Budget.reset_warnings/0` clears them.
- **`user_uuid:` must be a PhoenixKit user uuid.** The usage row has a
  foreign key on it. An unknown id means the row is not written — the
  provider was still paid — and `create_request/1` logs a warning. So the
  per-user cap cannot cover anonymous visitors: cap the endpoint or the
  site for them. (A nullable external-id column in core would lift this;
  see TODOs.)
- **The realtime voice session is outside every cap.** It writes no usage
  rows.

`PhoenixKitAI.get_usage_stats/1` is the read side: `user_uuid:`,
`endpoint_uuid:`, `source:`, `status:`, `model:`, `since:`, `until:`.

Core's requests table carries single-column indexes on `inserted_at`,
`endpoint_uuid`, `user_uuid` and `status`. The trailing-24-hour sums use
`inserted_at` and filter the rest; a busy install with per-endpoint caps
will want `(endpoint_uuid, inserted_at) WHERE status = 'success'` in core.

## Request cache (`PhoenixKitAI.RequestCache`)

`cache: true | [ttl: seconds | :infinity, key: term, refresh: boolean] |
:refresh` on every verb (`speak/3` and `compare_images/4` included).
`config :phoenix_kit_ai, request_cache: [ttl:, sweep:, max_entries:,
max_value_bytes:, default:]` is read per call; `default: true` opts every
call in unless it says `cache: false`.

The key is a SHA-256 over `{verb, endpoint uuid, endpoint updated_at,
model, material}`:

- **material** is what shapes the answer — messages or prompt, image
  bytes, request options, the JSON shape asked for (`schema:` / `json:`).
  `source:`, `attribution:`, `idempotency_key:`, `user_uuid:`, `cache:`,
  the prompt identifiers and the prompt snapshot are dropped: they track,
  they do not shape. For `complete/3` the material is the merged options
  (endpoint defaults included); for the image verbs it is the caller's
  options plus the endpoint's `updated_at`, so an admin edit to
  `image_size` or a provider setting starts fresh.
- **`key:`** replaces the material with the caller's term — a re-rendered
  prompt for the same product still hits — but the verb, endpoint, model
  and JSON shape (`schema:`, `json:`, `extract_text/3`'s `fields:`) stay
  in, so a prose entry is never served to a `json: true` call, nor one
  field set's answer to another, under the same key. Everything else — a
  describe prompt, which image — is the caller's to put in the key.
- An `%{url:}` image input keys on the URL, not the bytes behind it: a
  changed image at the same URL is served the old answer until the TTL.
- **Entries are shared across users.** Two users asking the same thing
  get the same answer, and a caller key is global to the endpoint. Scope
  it yourself (`cache: [key: {user_uuid, "profile"}]`) when the answer is
  personal.
- The key is built only when caching is on: hashing 25 MB of image bytes
  on every uncached call is not free.

A hit returns the stored result, calls no provider, and writes a
**zero-cost usage row** (`cost_cents: 0`, tokens 0, `metadata.cached:
true`) with the hitter's `user_uuid`, `source`, attribution, prompt link
and prompt snapshot — the same shape a fresh row has, minus the cost. It
does not count against a cap because it cost nothing. Only `{:ok, _}`
results are stored, and a JSON request whose answer did not parse is an
error, so it is never stored either. A dry run neither reads nor fills
the cache.

Limits and edges: millisecond deadlines (a `ttl: 1` survives one second);
a `ttl:` that is not a positive integer or `:infinity` falls back to the
default; `max_entries` (10 000) and `max_value_bytes` (8 MB) refuse to
store rather than evict, so an image-edit result over the limit is simply
not cached; `:infinity` entries survive the sweep; concurrent misses on
one key each call the provider (no single-flight); the table dies with
the node, and without the module's supervisor (`PhoenixKitAI.children/0`)
every lookup is a miss with no signal. It is a cost saver, not a store of
record.

## Structured output (`PhoenixKitAI.StructuredOutput`)

`schema:` (a JSON Schema map) sends `response_format: json_schema` with
`strict: true` and repeats the schema in the last user message; `json:
true` sends `json_object`. A 400 or 422 answer is retried once with no
`response_format` — any 400, so an unrelated bad request costs one extra
call. The retry keeps the suffix, so the model still knows the shape, but
the schema is then advisory: nothing validates the parsed object locally,
so check the keys you depend on. Without `schema:` or `json:` the caller's
own `response_format:` passes through untouched.

Parsing takes the whole text, then a fenced block anywhere in it, then the
outermost `{…}` / `[…]`; an object or array parses, anything else is
`{:error, {:no_json_in_response, text}}`. The provider call is logged with
its usage in that case; the error is not logged again and is not cached.
The parsed value sits under `"json"` on a chat response and `:json` on a
vision result.

The same retry serves `describe_image/3` and `extract_text/3` from
`Images.describe/3`, not from the adapter, so a provider with its own
`vision/3` keeps it. A prose answer there is logged the same way as on
chat: `Images.describe/3` hands the unparsed result, usage included, to an
`:on_no_json` callback before returning the error, so the vision verbs
(`compare_images/4` too) write the paid call's success row and no failure
row.

## Telemetry

| event | measurements | metadata |
|---|---|---|
| `[:phoenix_kit_ai, :request]` | `input_tokens`, `output_tokens`, `cost_cents`, `latency_ms` | `request_type`, `status`, `endpoint_uuid`, `model`, `user_uuid`, `source`, `cached` |
| `[:phoenix_kit_ai, :image, :request]` | `latency_ms`, `input_bytes`, `output_bytes`, `input_images`, `output_images` | `type`, `outcome`, `provider`, `model`, `endpoint_uuid`, `operations`, `warnings`, `error`, `source` |
| `[:phoenix_kit_ai, :budget, :warning]` | `spent`, `limit` | `scope`, `endpoint_uuid`, `user_uuid` |
| `[:phoenix_kit_ai, :cache, :hit \| :miss \| :refresh]` | `count` | `verb`, `endpoint_uuid` |

`[:phoenix_kit_ai, :request]` fires from `create_request/1`, so it covers
every usage row of every verb, cached rows included — split dashboards on
the `cached` tag. No event carries prompt text, response text or image
bytes; the cache callback that writes the hit row is stripped from the
cache events' metadata, so a handler that serialises metadata cannot
raise (and be detached by `:telemetry`) on a function.

Saved-prompt rows (`ask_with_prompt/4`, `complete_with_system_prompt/5`)
carry `metadata.prompt_snapshot.hash`, a 16-hex prefix of the SHA-256 over
system prompt + content, so an answer still says which version of an
edited prompt produced it. There is no timestamp in it: usage increments
touch `updated_at` on every call.
