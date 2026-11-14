# PR #61 follow-up

Claude review with the external panel on 2026-11-13; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** base64 vectors with NaN/infinity or undecodable (now `:invalid_response_format`);
  `normalize: true` overflow; `embed_many` index pairing on a short part; one-pass
  `apply_template/3`; the `translate_query` length guard and matched-quote stripping; the
  live model list's backoff on a raise or exit, and its field types; the order of a
  flaky vision test. Each fix has a test that fails without it.
- **Open, for the maintainer:** the `grpc_core` advisory that stops `mix precommit` at
  `hex.audit` (on upstream too); `dimensions:` missing from a caller cache key
  (pre-existing).
- **Not changed:** a charlist in `provider:`; the task stacktrace on concurrent `embed_many` rows.

## Maintainer review, 2026-11-14

See [the maintainer review](CLAUDE_MAINTAINER_REVIEW.md).

- **Fixed:** `embed_many/3` with a caller cache key answering every part with the first
  part's vectors; a part that raised under `max_concurrency > 1` killing the caller; a
  struct as `provider:` raising; `role: "query"` and `role: :query` cached apart. Each has
  a test in `embedding_options_test.exs`.
- **Documented:** `role:` does not template an image's caption.
- **Closed since the first review:** `dimensions:` in a caller cache key (`02af792`); the
  `grpc_core` advisory (`main` moved to 1.1.0).
- **Not changed:** `translate_query/3` failing silently; no single-flight on the live
  model list; `embed_many`'s cost and usage sums on partly priced or cached parts.
