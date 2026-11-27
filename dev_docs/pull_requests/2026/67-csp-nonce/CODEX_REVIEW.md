# Review of PR #67

PR #67 adds a source lint for the templates and JavaScript bundle the module ships. The Playground uses a LiveView image preview for uploads and builds data URLs for generated images and audio playback.

- **BUG - MEDIUM** The tag check accepted any occurrence of `src=`, `ColocatedHook` or `CSP.nonce(` in an opening tag. Even a style with a source attribute passed. Check the element and its actual attribute, and exercise the exemptions independently.
- **BUG - MEDIUM** The proposed guidance and lint allowed nonce-bearing inline scripts in templates. LiveView navigation requires hooks to ship in the module bundle. The JavaScript check also accepted script creation when a nearby line mentioned style adoption.
- **IMPROVEMENT - MEDIUM** The bundle check repeatedly sliced from the start of the list and could inspect a different bundle's lines if another bundle were added. Scan a bounded window within each file.

The lint checks source conventions. Browser behavior under a host's complete CSP requires a host integration test.
