# Claude Review — PR #41

**Reviewer:** Claude Sonnet 5.5
**PR:** Model capabilities: a cache of what each model can take, from the providers' catalogues, with badges in the endpoint form (timujinne)
**Reviewed:** 2026-10-22
**Merge commit:** `65eb1b8`

## Overall Assessment

**APPROVE.** Risk: **Low**. This is the foundation the next three PRs sit on:
`PhoenixKitAI.Capabilities` (a GenServer owning a protected ETS table with
`read_concurrency`), the module's own migration chain
(`PhoenixKitAI.Migrations`, V1), the `phoenix_kit_ai_model_capabilities`
snapshot, native Anthropic `/v1/models` paging, and capability badges plus a
"declare what the catalogue does not say" panel in the endpoint form. Reads are
ETS-only and never touch the network; every write goes through the one process.
Nothing found that needed a code change.

## Findings

### IMPROVEMENT - MEDIUM — the cache refreshes while the module is switched off

`PhoenixKitAI.children/0` (`lib/phoenix_kit_ai.ex:1172`) starts
`Capabilities` unconditionally, and `do_read_catalogues/1`
(`lib/phoenix_kit_ai/capabilities.ex:764`) never asks `PhoenixKitAI.enabled?/0`.
A host with AI switched off but endpoints still stored makes an authenticated
`GET /models` per base URL every six hours, and again 10 s after every boot.
`GuardEventsPruneWorker` (PR #45) does check `enabled?/0`, so the two are
inconsistent. Not changed: whether a disabled module should keep its catalogue
warm is a call for the maintainer (a re-enable would then start cold for up to
six hours unless `enabled?` is consulted at refresh time, not at start).

### NITPICK — a miss and a refresh decide "has a catalogue" differently

`lookup/2` asks `catalogue_kind(nil, base_url)` (host only,
`capabilities.ex:166`); the refresh asks `catalogue_kind(endpoint.provider,
base_url)` (`:793`). An endpoint with `provider: "anthropic"` behind a proxy
host is read at refresh time, but a model missing from its catalogue never asks
for a refresh. It only waits for the six-hour tick. Not changed: proxies in
front of Anthropic are not a case this module supports yet.

### NITPICK — every miss is a message to the GenServer

A lookup of a model absent from a catalogue that was already read casts
`{:miss, base_url}` on every call (`:166`); the process drops it. Cheap, but the
`settled` set could be checked in ETS before casting. Not changed.

## Reviewed and sound

- **Single flight and retries** (`capabilities.ex:503-710`): a `refresh/1`
  caller joins the running task; a retry for some base URLs is followed by a
  full refresh that answers it; back-off 1 / 5 / 30 min then the next tick; a
  `:no_api_key` base URL is not retried. `Task.Supervisor.async_nolink` with a
  `:DOWN` clause, and `spawn_refresh/2` catches a down supervisor.
- **No key in a crash report**: `read_catalogues/1` rescues and catches inside
  the task, so a stack argument carrying an API key never reaches the log.
- **An empty catalogue is a failure**, not "no models" (`fetch_catalogue/4`),
  so it cannot wipe the cache and the snapshot.
- **Replace without a gap**: `put_catalogue/2` inserts new entries before
  deleting the vanished ones, and reports whether a reader would see a change
  (`fetched_at` aside), so `{:capabilities_refreshed, _}` is not broadcast for a
  no-op refresh.
- **Anthropic paging** (`openrouter_client.ex`): `has_more` without a cursor is
  an error rather than a silently short list; page cap of 20; a 400 on the
  `lifecycle` filter is retried without it.
- **Migration V1** (`migrations.ex`): every statement guards itself, the
  version marker is a table comment read from `pg_class`, a prefix is validated
  before it is interpolated, `down_statements/2` re-stamps the marker.
- **Declarations**: `Endpoint.drop_stale_capabilities/1` drops a declaration
  naming another model whatever built the params; the catalogue's `:no` beats a
  declared `:yes` (`conflicts/2`).
- **Chat model list**: matching on the output side of `modality`
  (`output_modalities`) keeps vision-in/text-out models in the chat picker.

## Positive Observations

- The snapshot makes a restart without network keep its answers, and a failed
  snapshot write is logged without failing the refresh.
- `MessageShape.describe/1` in every log line; no `inspect(msg)`.
- Test coverage is unusually deep for a cache process (709 lines for the
  server alone: concurrent misses making one fetch, the back-off timeline, a
  401 moving to the next key, an empty catalogue wiping nothing). The one path
  without a test is `spawn_refresh/2` finding the task supervisor down.

## Summary

| Area | Verdict |
|---|---|
| Code quality | Good |
| Architecture | Good: ETS reads, one writer |
| Security | Good: no key in crash reports, SSRF guard untouched |
| Performance | Good; one cast per miss is the only waste |
| Test coverage | Very good |
| Migration safety | Good: idempotent, guarded, marker per table |
| Consistency | One gap: refresh ignores `enabled?/0` |
