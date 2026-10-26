# PR #58 — follow-up

- The endpoint form's integration picker still shows 8+4 of a key; only `ai.manage_endpoints` holders reach it.
- Any page gated on a sub-key inside a base-key LiveView needs `phoenix_kit_scope_changed/1` to hide content at once after a revoke (AGENTS.md).
- `AITranslate.Embed` now takes `authorize:` (a 1-arity function or MFA, checked against the live socket on all six modal events before dispatch). Omitted = unchanged behaviour. Hosts (catalogue, ecommerce, projects, publishing) gate with their own hook before `use` for now, because they compile against the released AI module; switch them to `authorize:` once it ships.
