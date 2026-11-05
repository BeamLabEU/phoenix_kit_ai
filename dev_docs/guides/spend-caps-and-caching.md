# Spend caps, the request cache, structured output and telemetry

How the cross-cutting controls on every verb work, what they promise and
what they deliberately do not. The code is `PhoenixKitAI.Budget`,
`PhoenixKitAI.RequestCache`, `PhoenixKitAI.StructuredOutput` and the
`with_cache/6` + `cached_row/5` pair in `PhoenixKitAI`.

## Units

Everything is **US dollars**, as a `Decimal` (`PhoenixKitAI.Money`): a usage
row's `cost` (`numeric(28,18)`), every cap, every number `Budget` returns,
task limits and prices per 1M tokens. `set_limit(:global, "5")` is a
five-dollar cap; the sum of `cost` is compared with it as it is, so a
thousand calls of $0.0000006 count as $0.0006. No amount is ever scaled
into an integer, and an integer given as an amount is refused
(`{:error, :ambiguous_amount}`): releases before this one stored millionths
of a dollar (`cost_cents`, `ai_daily_budget = "5000000"` for $5). Core's V223
converts the column, this module's V4 the settings (into new keys), the task
limits and the prices; until both have run, calls are refused rather than
counted in the wrong unit.

## Spend caps (`PhoenixKitAI.Budget`)

| setting | scope |
|---|---|
| `ai_daily_cap` | every call the module makes |
| `ai_monthly_cap` | every call the module makes, in the current calendar month of the site time zone (`:global_month`) |
| `ai_daily_cap_per_endpoint` | one endpoint |
| `ai_daily_cap_per_user` | one `user_uuid:` |
| `ai_budget_warn_percent` | warn once per crossing (default 80) |

Dollar strings; `0` or blank means no cap. A scope whose new key is missing
while its released `ai_daily_budget*` key still holds a cap refuses every
call with `{:error, {:budget_unmigrated, scope}}` until V4 has copied it.
`Budget.set_limit/2` writes them under the `"ai"`
settings module; there is no admin form yet.

What a check costs: one cached batch read of the cap settings (the
settings cache is invalidated on every write, so a new cap applies at
once) and, per scope that has a cap, one aggregate over the last 24 hours
of success rows (since the start of the month for the monthly cap, whose sum
is reused for 30 seconds, 2 near the cap, see below). With no caps set the
requests table is not touched.

Semantics, in order of how often they surprise:

- **Rolling window, not a calendar day.** Spend from 23:00 still counts at
  09:00; a row older than 24 hours drops out mid-morning and frees spend.
- **The monthly cap is a calendar month.** `ai_monthly_cap` sums the same
  success rows as the global daily cap from the local midnight that starts the
  month (Settings → `time_zone`, the month window of
  `PhoenixKitAI.TaskLimits.windows/2`) and starts again at zero on the first.
  It refuses with `{:error, {:budget_exceeded, :global_month}}`; the daily and
  monthly site caps can both be set and either refuses when reached. A
  setting only: no migration. A value that is set but not a number (`"$100"`,
  `"1,000"`) reads as no cap, as a blank does, but a warning says so (once per
  node and per distinct value, never quoting it): a cap that switched itself
  off should not do it silently.
- **The monthly sum is cached for 30 seconds, and for 2 near the cap.**
  Unlike the daily windows the month's sum scans every success row since the
  month began, which on a busy site is too much to run before every provider
  call. The sum is kept in the module's ETS flags table, keyed by the month's
  start (a new month, or another `time_zone`, never reuses it), for `config
  :phoenix_kit_ai, budget_month_cache_ttl: 30_000` milliseconds (`0` = off; the
  test config sets it to `0`). A TTL that is not a positive integer means no
  cache. The cache is for the stretch where the cap is far away. From 90% of
  the cap up to it a sum is reused for 2 seconds at most (a fixed line, not
  `ai_budget_warn_percent`: a notification setting, even `100`, does not
  decide how exactly money is counted). The bound on the overshoot: below 90%
  it is the spend of one TTL (30 s) minus the headroom to the cap, which is a
  tenth of the cap or more (so on a $100 cap a site would have to spend $10 in
  30 seconds); from 90% up it is the spend of 2 seconds plus the in-flight
  calls. At the cap nothing more is spent, so the cached sum stays. The cache
  is per node: with N nodes every figure above is up to N times larger. This
  is the simpler of two options (the other being to add each logged call's
  cost to the cached sum); the cost is at most one month scan per 2 seconds per
  node in the last tenth of the budget. `status/2` reads through (and fills)
  the same cache, so its monthly spend can be 30 seconds old.
- **A failed month scan serves the last good sum.** A failed read is never
  stored as a sum. The month's last good sum (even an expired one) is used
  instead, or zero if the node has none, and for 5 seconds calls do not scan
  again, so a month scan that times out is not retried by every call on a
  database that is already struggling. The cap is still not enforced on a
  fresh sum while reads fail; it is fail-open, as below, and spend after the
  last good scan is not counted, for as long as scans fail (the cap trips late,
  never early). The first failure is logged once per outage; once the sum in
  use is 10 minutes old the module logs a second warning, naming its age, and
  repeats it every 10 minutes, so an operator can tell that the cap has been
  running on old data. With the cache off (`0`) a failed read is zero spend,
  like the other scopes.
- **One scan at a time per node, where there is a sum to serve.** A scan that
  has an earlier sum of the month to fall back on leaves a 5 second lease
  behind (`month_scanning`); callers arriving meanwhile serve that sum instead
  of running the same scan, and a good scan removes the lease. A scanner that
  crashes leaves nothing behind: the lease lapses by itself. With no earlier
  sum (a fresh node, or a new month) every caller scans, since there is
  nothing else to answer with; that is a single burst, not a standing load.
- **Reached means stopped.** `remaining <= 0` refuses; a cap of exactly
  the amount spent is not room for one more call.
- **Cached answers are refused too.** A cap is a stop switch: once spent,
  the module answers nothing, so a runaway site goes quiet rather than
  half-quiet. `process_image/4` dry runs (`dry_run: true`) skip the check
  — they spend nothing and never reach a provider. No other verb honours
  `dry_run:`, so on those it lifts nothing.
- **A refusal is a row.** The refused call is written as a zero-token
  `status: "error"` row with `metadata.refused: true` (and the call's
  `task`), so the journal shows who was turned away; it counts toward no
  cap and no usage sink (`handle_ai_usage/1`) receives it. It is also a
  `limit_reached` guard event (scope `budget:<scope>`), and the guard's
  watchers are told once per local day (`PhoenixKitAI.GuardEvents`); for the
  monthly cap once per local month, since it only lifts when the month turns
  (or the cap is raised). That holds even when the cap is raised and reached
  again in the same month: the later refusals are refusals as ever, but not a
  new event or notice.
- **Task limits come first.** A call that names a declared task is checked
  against the task's calendar-day and month limits (`PhoenixKitAI.TaskLimits`)
  before the caps; the caps stay the site-wide safety net (the rolling 24
  hours, and the calendar month for `ai_monthly_cap`).
- **No reservation.** The check reads the table; concurrent callers can
  overshoot by their in-flight calls. Atomic reservation is a TODO.
- **Fails open.** A database error reads as zero spend and no cap, so a
  blip does not refuse every call. The panel split on this; availability
  won, and the module logs a warning naming the exception class, once per
  outage per scope per node (each scope's flag is cleared by that scope's next
  successful database read, not by another scope's read and not by a sum served
  from the month cache), so the first failure is visible without a flood while
  the database is down. For the monthly cap the value used meanwhile is the
  last good sum, not zero.
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
The monthly sum is the same `inserted_at` range over a longer window, so no
index makes it cheap (it is an aggregate over the month's rows): that is why
it is cached (30 seconds, 2 near the cap).

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
**zero-cost usage row** (`cost: 0`, tokens 0, `metadata.cached:
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
| `[:phoenix_kit_ai, :request]` | `input_tokens`, `output_tokens`, `cost` (dollars, a float), `latency_ms` | `request_type`, `status`, `endpoint_uuid`, `model`, `user_uuid`, `source`, `cached` |
| `[:phoenix_kit_ai, :image, :request]` | `latency_ms`, `input_bytes`, `output_bytes`, `input_images`, `output_images` | `type`, `outcome`, `provider`, `model`, `endpoint_uuid`, `operations`, `warnings`, `error`, `source` |
| `[:phoenix_kit_ai, :budget, :warning]` | `spent`, `limit` (dollars as floats; a count for `:user_calls`) | `scope`, `endpoint_uuid`, `user_uuid` |
| `[:phoenix_kit_ai, :request, :retry]` | `attempt`, `delay_ms` | `status` ("HTTP 429", "a timeout", "a connection error") |
| `[:phoenix_kit_ai, :limiter, :rejected]` | `count` | `key`, `reason` (`:full` or `:timeout`) |
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
