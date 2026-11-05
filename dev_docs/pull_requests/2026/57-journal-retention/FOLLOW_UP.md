# PR #57 follow-up

The confirmed findings in [the GPT review](GPT_REVIEW.md) are fixed with regression coverage in the review commit.

## Claude review — 2026-11-05

See [the review](CLAUDE_REVIEW.md).

- **Fixed:** a queued manual job leaves out a kind whose period changed after it; `prefix:
  false` in `pending_job/0`; the "what clearing leaves" list.
- **Not changed:** a run killed mid-way leaves no audit trail for its committed chunks. Needs a
  design (a started entry or an in-progress stamp).
