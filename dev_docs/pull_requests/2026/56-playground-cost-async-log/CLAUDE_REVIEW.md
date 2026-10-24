# PR #56 — Show the Playground's logged cost under an asynchronous usage log

**Author:** timujinne · **Merged:** 2026-10-24 (cf25404) · **Reviewer:** Claude

## Summary

With `request_log_mode: :async`, `log_usage/1` only queues the usage row, and
`Playground.response_usage/2` read it before the writer stored it, so a call
priced only in its row (Anthropic's rates, a catalogue or manual price) showed no
cost chip — the gap the GPT review of #55 named. `logged_cost/2` now reads through
`logged_row/1`: a missing row under `RequestLog.async?/0` triggers one
`RequestLog.flush(2_000)` and a second read; an exit from the flush (timeout, dead
writer) still gets that second read.

Verdict: correct. No defects found.

Checked:

- **Ordering is real, not hoped for.** `execute_request/1` runs inside the
  LiveView's own `handle_info(:do_send)` (not a `start_async` task), so the row's
  `GenServer.cast` and the flush's `GenServer.call` come from one pid to one pid,
  which Erlang delivers in order. `handle_call(:flush, …)` replies at once, so its
  reply proves every earlier cast from this process was handled.
- **Paths that must not wait don't.** Sync mode, no writer, and a full queue all
  make `async?/0` false — and a full queue means the caller wrote synchronously, so
  the row is already there. A row found on the first read costs no extra query.
- **Bounded cost.** The LiveView is already blocked on the provider call; the wait
  is one queue drain, 2 s at most. `catch :exit` covers the timeout; the late reply
  is dropped by call aliases (OTP 24+).
- **Endpoint check kept.** The re-read row still has to match `endpoint_uuid`, so
  a uuid naming another endpoint's row still shows no cost.
- **Test.** The module runs `async: false` (LiveCase default), so its
  `Application.put_env(:request_log_mode, :async)` cannot leak into concurrent
  files, and `on_exit` removes it. Suspending the writer and resuming it once two
  messages (the row's cast and the flush call) are queued exercises exactly the
  race; it fails on main before the PR.

## Not changed

- **NITPICK:** `flush/1` waits for the whole queue, not this one row, so under a
  large backlog the Playground can wait the full 2 s and then show no cost. That is
  the documented trade-off of `:async` (spend caps have the same lag) and the
  Playground is an admin tool; a per-row wait would need a reply registry in the
  writer, which is not worth it here.
