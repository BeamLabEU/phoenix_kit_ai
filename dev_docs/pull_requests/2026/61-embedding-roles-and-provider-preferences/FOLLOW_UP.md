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
