# Resolution of PR #68 findings

- Fetch drops custom headers when the redirect changes origin, before fetching the destination's robots policy. The regression test checks both origins' robots and page requests, including a same-origin redirect.
- HostState checks the absolute deadline before advancing its queue. Fetch also limits its initial DNS lookup to the remaining time. Tests cover a rejected reservation and a deadline that expires before lookup.
- Reviews verifies the actor inside the decision transaction and holds a key-share lock so a concurrent deletion cannot invalidate the foreign key. The regression test checks that an invalid ID leaves the review pending.
- ContentHashes uses deterministic term encoding for complete field values and distinguishes nested maps from text. Tests cover lists with a common prefix and fields that differ in type.
- ContentHashes checks UTF-8, NUL and byte limits for keys and hashes during comparison and recording. Translation enqueue validates the exact pin before creating a job. Tests cover invalid database text and multibyte pins.
