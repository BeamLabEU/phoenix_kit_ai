## 0.1.1 - 2026-03-25

### Fixed
- Fix wrong GitHub org in README git dependency (mdon → BeamLabEU)
- Remove unused test.setup/test.reset mix aliases (no local migrations)
- Clarify migration module is called by parent app, not run directly

### Added
- Add versioning & releases section to AGENTS.md

## 0.1.0 - 2026-03-24

### Added
- Extract AI module from PhoenixKit into standalone `phoenix_kit_ai` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `PhoenixKitAI.Endpoint` schema for AI endpoint configurations (provider credentials, model, generation parameters)
- Add `PhoenixKitAI.Prompt` schema for reusable prompt templates with `{{Variable}}` substitution
- Add `PhoenixKitAI.Request` schema for request logging (tokens, cost, latency, status)
- Add `PhoenixKitAI.Completion` HTTP client for OpenRouter chat completions and embeddings
- Add `PhoenixKitAI.OpenRouterClient` for API key validation and model discovery
- Add admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground
- Add route module with `admin_routes/0` and `admin_locale_routes/0`
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (v1) with `IF NOT EXISTS` for all 3 tables (run by parent app)
- Add behaviour compliance test suite
- Add prompt unit tests (variable extraction, substitution, validation)
