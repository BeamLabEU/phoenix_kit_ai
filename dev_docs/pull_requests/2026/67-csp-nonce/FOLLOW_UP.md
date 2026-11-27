# Resolution of PR #67 findings

- Restricted template exemptions to external or colocated scripts and inline styles with a CSP nonce attribute. Added positive and negative cases and case-insensitive HTML matching.
- Aligned the guide with the existing hook rule and added a regression check for a script created near a style adoption call.
- Scoped the sliding lookahead to each declared bundle.
- The full suite exposed a pre-existing guard test that assumed UUID order follows insertion order within a millisecond. The chat and vision assertions now identify rows by the returned UUIDs or recorded status.
