# Image processing

How consuming modules edit, generate and read images through
`phoenix_kit_ai`, and how the module stays provider-neutral while doing
it.

## The shape

```
caller  ──►  PhoenixKitAI.process_image/4 ─► PhoenixKitAI.Images ─► Provider adapter ─► HTTP
             PhoenixKitAI.edit_image/4            (operations,         (OpenRouter, xAI,
             PhoenixKitAI.generate_image/3         options, fitting)    OpenAI, generic)
             PhoenixKitAI.describe_image/3
             PhoenixKitAI.compare_images/4
```

Every verb takes an endpoint (uuid or struct) and returns bytes. The
module stores nothing: the caller keeps results wherever it keeps files
(core's Storage, usually). The only trace is the request row
(`request_type` `image_edit`, `image`, `vision`).

The endpoint decides the provider; the provider decides the adapter
(`PhoenixKitAI.Provider.for_endpoint/1`). Moving a module from
OpenRouter to xAI, OpenAI, or a provider added later is a change of
endpoint, not of code.

## Operations

`process_image/4` composes named operations into one prompt:

```elixir
PhoenixKitAI.process_image(endpoint_uuid, [photo_jpeg], [
  :remove_reflections,
  {:clean_background, color: "white"},
  {:upscale, resolution: "2K"},
  "Straighten the label so its text is horizontal."
])
```

Built-ins live in `PhoenixKitAI.Images.Operations` (its moduledoc has
the table). Each is a prompt template with parameters, the request
options it implies (`:remove_background` wants `background: "transparent"`
and a PNG), a fallback wording for when those options are unavailable,
and presets (`{:relight, light: :night}`). A bare string is a free-form
instruction. The list becomes a numbered instruction block, then a
preservation clause (`preserve: :subject` by default — shape, text,
logos and colours stay; `:scene` for rooms; `false` for none; or your own
sentence), then a closing line (`finish: false` drops it).

Two ways to change wording without a release:

- a host adds or replaces operations in config:
  `config :phoenix_kit_ai, image_operations: %{product_shot: %{prompt: "…", options: %{aspect_ratio: "1:1"}}}`
- an admin saves a prompt named `Image op <name>` (slug
  `image-op-<name>`); it replaces that operation's template and its
  `{{Variables}}` fill from the operation's parameters.

## Options and fitting

Canonical option names, mapped per provider by the adapter:
`:aspect_ratio`, `:resolution`, `:size`, `:quality`, `:background`,
`:output_format`, `:output_compression`, `:n`, `:seed`,
`:response_format`. Control options: `:model` (override the endpoint's
model — the way to compare two OpenRouter models on one endpoint),
`:transport`, `:provider_options` (passed through untouched),
`:provider_routing` (OpenRouter's `provider` object), `:strict`,
`:preserve`, `:finish`, `:prompt_overrides`, `:verify`.

Endpoint defaults sit underneath: `provider_settings["aspect_ratio"]` /
`["resolution"]` and the `image_size` / `image_quality` columns.

Before sending, `PhoenixKitAI.Images.fit_options/4` keeps the request
inside what the model accepts. OpenRouter publishes a per-model listing
(`GET /images/models`; `PhoenixKitAI.Images.ImageModels` caches it for
30 minutes per base URL); other providers fall back to the adapter's
static option set. An option the model does not list is dropped and
reported as `{:dropped_option, key, value}` in the result's `:warnings`,
or refused up front with `strict: true`. An operation whose implied
option was dropped switches to its fallback wording — a cutout on a
model without transparency becomes a white background, and the caller
sees why in the warnings.

`edit_image/4` and `generate_image/3` send options as given, without
fitting; they are the thin verbs for callers that already know the model.

## Vision

`describe_image/3` runs a chat completion with the images attached.
`schema:` (a JSON Schema map) or `json: true` requests a JSON answer
and returns it parsed under `:json`; anything else comes back as
`:text`. `compare_images/4` is a fixed-schema `describe_image/3` over an
original and its edit: `passed`, `same_subject`,
`text_and_logos_preserved`, `unwanted_changes`, `summary`.
`process_image(…, verify: true)` runs it on the same endpoint and
attaches the verdict as `:verification` without changing the outcome.

## Adapters

| provider key | adapter | transport |
|---|---|---|
| `openrouter` | `PhoenixKitAI.Providers.OpenRouter` | `POST /images` with `input_references`; `transport: :chat` for the chat-completions path |
| `xai` | `PhoenixKitAI.Providers.XAI` | JSON `POST /images/edits` |
| `openai` | `PhoenixKitAI.Providers.OpenAI` | multipart `POST /images/edits`; `aspect_ratio` mapped to `size` |
| other | `PhoenixKitAI.Providers.OpenAICompatible` | `POST /chat/completions` with `image_url` parts |

All adapters go through `PhoenixKitAI.Providers.HTTP`, which honours the
same `:req_options` hook as `Completion`, so one `Req.Test` plug stubs
everything in tests.

Adding a provider: implement `PhoenixKitAI.Provider` (four callbacks:
`image_edit/4`, `image_generate/3`, `image_models/1`, `image_options/1`)
and register it:

```elixir
config :phoenix_kit_ai, provider_adapters: %{"fal" => MyApp.FalAdapter}
```

The key is the Integrations provider key the endpoint carries. Adapters
receive normalised inputs (data URLs or http(s) URLs) and canonical
options, and return the uniform result
`%{images: [%{data, url, content_type}], text, usage, latency_ms, model}`.

## Rules worth keeping

- Never send a provider a permanent Storage URL: inline bytes. The
  normaliser does this for you when you pass bytes or `%{data, content_type}`.
- Caller mistakes (bad input, unknown operation, a refused option under
  `strict`) never reach a provider and are not logged as requests.
- Image bytes are never persisted in the request log; counts and sizes
  are, the prompt and any text under the PII gate.
