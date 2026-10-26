# PR #58 — follow-up

- The endpoint form's integration picker still shows 8+4 of a key; only `ai.manage_endpoints` holders reach it.
- Any page gated on a sub-key inside a base-key LiveView needs `phoenix_kit_scope_changed/1` to hide content at once after a revoke (AGENTS.md).
