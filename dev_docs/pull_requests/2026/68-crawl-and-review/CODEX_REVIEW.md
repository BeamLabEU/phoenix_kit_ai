# Review of PR #68

- **BUG - HIGH** Fetch reused caller headers after a change of origin. A redirect could disclose credentials on the next page request or during the destination's robots check.
- **BUG - MEDIUM** A fetch that could never reach its reserved slot before its deadline still moved the host's next slot forward. Repeated refusals delayed other callers. The initial DNS check also had a fixed five-second timeout even when less time remained.
- **BUG - MEDIUM** An explicit malformed reviewer UUID became an anonymous decision and appeared as automatic activity. This made a bad actor ID indistinguishable from an intentional system decision.
- **BUG - MEDIUM** Content comparison used inspected output for list fields, so edits after the inspection limit could leave the hash unchanged. It also conflated numbers with their string representation.
- **BUG - MEDIUM** Content-hash keys and caller-supplied hashes could pass validation with bytes PostgreSQL cannot store. Translation enqueue silently shortened long source pins by grapheme count, which could both change their identity and exceed the storage API's byte limit.
