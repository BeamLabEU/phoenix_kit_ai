# Tech spec: TTS (text-to-speech) support in `phoenix_kit_ai`

**Date:** 2026-06-10
**Audience:** the agent implementing changes inside the `phoenix_kit_ai` hex package
**Status:** spec for implementation
**Scope:** add a text-to-speech capability to `phoenix_kit_ai` that mirrors the existing
`complete`/`embed` paths. Provider target is Mistral Voxtral TTS (the host app has already
added a Mistral integration + an AI endpoint). **This spec covers the package only** — the
consuming app handles media storage, voice selection, schema, and UI separately.

All paths below are relative to the package root (`deps/phoenix_kit_ai/` in the host repo).

---

## 1. Goal

Add a public function that synthesizes speech from text through a configured AI endpoint and
returns the audio bytes:

```elixir
{:ok, %{audio: <<...mp3 bytes...>>, format: "mp3"}} =
  PhoenixKitAI.speak(endpoint_uuid, "Bonjour, comment ça va ?",
    voice: "casual_male",          # provider-specific voice identifier (see §4)
    response_format: "mp3",        # default "mp3"
    source: "SentenceAudio"        # request-tracking label, optional
  )
```

It must reuse the existing endpoint resolution, credential/header plumbing, error mapping, and
request logging — exactly the shape `embed/3` already follows.

---

## 2. How the existing code is structured (reference points)

- **Public API:** `lib/phoenix_kit_ai.ex`
  - `complete/3` (line ~2278) and `embed/3` (line ~2413) are the templates to copy. Both:
    1. `resolve_endpoint/1` → `validate_endpoint/1`,
    2. `capture_caller_info/0` → `source = opts[:source] || auto_source`,
    3. merge endpoint defaults into opts,
    4. call into `PhoenixKitAI.Completion`,
    5. on success log via a `log_*_request/…`, on error log via `log_failed_*` and return
       `{:error, reason}`.
  - `validate_endpoint/1` (line ~2459) checks model present, `enabled != false`, and
    credential status. Reuse as-is.
  - `resolve_endpoint/1` (line ~1219) accepts a UUID string or an `%Endpoint{}`.
- **HTTP client:** `lib/phoenix_kit_ai/completion.ex`
  - `chat_completion/3` (line 80) and `embeddings/3` (line 151) are the call shapes to copy.
  - `build_url(endpoint, path)` (line 384, private) → `{base_url}{path}`, with base_url falling
    back to `Endpoint.default_base_url(provider)`. **Reuse for `/audio/speech`.**
  - `OpenRouterClient.build_headers_from_endpoint(endpoint)` resolves auth (integration or
    legacy api_key). **Reuse unchanged.**
  - `http_post(url, headers, body)` (line 333, private) posts JSON via `Req`, returns
    `{:ok, %{status_code, body}}` where `body` is a string. **Reuse** (see §5 for the binary
    caveat).
  - `handle_error_status/2` (line 114): 401→`:invalid_api_key`, 402→`:insufficient_credits`,
    429→`:rate_limited`, else `{:error, {:api_error, status}}`. **Reuse.**
  - `maybe_add/3` (line 329, private) — conditional body-field helper.
- **Request log:** `lib/phoenix_kit_ai/request.ex`
  - `@valid_request_types ~w(text_completion chat embedding)` (line 82) gates `request_type`
    via `validate_inclusion` (line 158). **No DB check constraint** — pure changeset
    validation. Must add the new type here (see §6).
  - `create_request/1` writes a `phoenix_kit_ai_requests` row.
- **Endpoint schema:** `lib/phoenix_kit_ai/endpoint.ex`
  - Has `model`, `provider`, `base_url`, `provider_settings :map` (line 141),
    `default_base_url/1` (line 291: `"mistral" → "https://api.mistral.ai/v1"`).
  - **No schema change required** for v1 (voice is a per-call option). See §7.

---

## 3. Public API to add — `PhoenixKitAI.speak/3`

In `lib/phoenix_kit_ai.ex`, add alongside `embed/3`:

```elixir
@spec speak(String.t() | Endpoint.t(), String.t(), keyword()) ::
        {:ok, %{audio: binary(), format: String.t()}} | {:error, term()}
def speak(endpoint_uuid, text, opts \\ []) when is_binary(text) do
  with {:ok, endpoint} <- resolve_endpoint(endpoint_uuid),
       {:ok, _} <- validate_endpoint(endpoint) do
    {auto_source, stacktrace, caller_context} = capture_caller_info()
    source = Keyword.get(opts, :source) || auto_source

    case Completion.text_to_speech(endpoint, text, opts) do
      {:ok, result} ->
        log_tts_request(endpoint, text, result, source, stacktrace, caller_context)
        {:ok, Map.take(result, [:audio, :format])}

      {:error, reason} ->
        log_failed_tts_request(endpoint, text, reason, source, stacktrace, caller_context)
        {:error, reason}
    end
  end
end
```

Notes:
- No endpoint-default merging needed (TTS has no temperature/dimensions analog). Pass `opts`
  straight through. If a default voice is later stored on the endpoint, merge it here.
- Return value is a small map (`:audio` binary + `:format`) so the caller knows the file
  extension/MIME without re-deriving it. Keep `latency_ms` etc. internal to logging.

---

## 4. Wire format — **confirm against the live API before finalizing**

Two Voxtral TTS surfaces exist and they differ. The host app uses the **Mistral hosted API**
(`provider: "mistral"`, base_url `https://api.mistral.ai/v1`), so target that first:

| | Mistral hosted (`api.mistral.ai/v1`) | OpenRouter / OSS vLLM |
|---|---|---|
| Path | `POST /audio/speech` | `POST /audio/speech` |
| `model` | `voxtral-mini-tts-2603` | `mistralai/Voxtral-4B-TTS-2603` |
| Voice field | `voice_id` (saved/cloned voice) — also accepts preset voices | `voice` (e.g. `"casual_male"`) |
| Response | JSON `{ "audio_data": "<base64>" }` | raw binary audio body |
| Limits | ≤ 300 words/request; 403 on content moderation | — |

**Action for implementer:** do a one-off smoke call against the host's configured Mistral
endpoint and confirm (a) the exact voice field name the hosted API expects, and (b) whether the
response is base64-JSON or raw binary. Build the request to match; build the response handler to
tolerate **both** shapes (§5) so the same code works for hosted Mistral and an OpenRouter
fallback.

Keep `phoenix_kit_ai` provider-neutral: do **not** hardcode a voice field name. Pass through
whatever the caller supplies:

```elixir
# lib/phoenix_kit_ai/completion.ex
@tts_timeout 120_000

def text_to_speech(endpoint, text, opts \\ []) do
  url = build_url(endpoint, "/audio/speech")
  headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
  format = Keyword.get(opts, :response_format, "mp3")

  body =
    %{"model" => endpoint.model, "input" => text, "response_format" => format}
    |> maybe_add("voice", Keyword.get(opts, :voice))
    |> maybe_add("voice_id", Keyword.get(opts, :voice_id))

  start_time = System.monotonic_time(:millisecond)

  case http_post(url, headers, body) do
    {:ok, %{status_code: 200, body: response_body}} ->
      decode_audio(response_body, format, start_time)

    {:ok, %{status_code: status, body: response_body}} ->
      handle_error_status(status, response_body)

    {:error, :timeout} -> {:error, :request_timeout}
    {:error, reason} ->
      Logger.warning("TTS transport error: #{inspect(reason)}")
      {:error, {:connection_error, reason}}
  end
end
```

The caller passes either `:voice` or `:voice_id`; only the present one is sent.

---

## 5. Response decoding — handle base64-JSON **and** raw binary

`http_post/3` stringifies the response body (JSON maps are re-encoded to a JSON string;
non-JSON bodies pass through `to_string/1`, which is a no-op for a binary). So `decode_audio/3`
must try JSON-with-base64 first, then fall back to treating the body as raw audio bytes:

```elixir
defp decode_audio(response_body, format, start_time) do
  latency_ms = System.monotonic_time(:millisecond) - start_time

  audio =
    case Jason.decode(response_body) do
      {:ok, %{"audio_data" => b64}} when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, bytes} -> bytes
          :error -> nil
        end

      _ ->
        # Not JSON (or no audio_data) → assume raw binary audio body.
        response_body
    end

  case audio do
    bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
      {:ok, %{audio: bytes, format: format, latency_ms: latency_ms}}

    _ ->
      {:error, :invalid_audio_response}
  end
end
```

> ⚠️ **Req binary caveat to verify:** `http_post/3` currently does
> `if is_map(body) or is_list(body), do: Jason.encode!(body), else: to_string(body)`. For a raw
> binary audio response Req may need `decode_body: false` to avoid mangling, and `to_string/1`
> on an already-binary body is fine. If the smoke test shows the hosted API returns base64-JSON
> (most likely), this caveat is moot. If you add a raw-binary provider, prefer adding a small
> `http_post_binary/3` (or a `decode_body: false` option) rather than changing the shared
> `http_post/3` used by chat/embeddings. Keep the change surgical.

`:invalid_audio_response` is a new error reason — add it to `PhoenixKitAI.Errors` with a
user-facing message (see §8).

---

## 6. Request logging

Add a `request_type` value and two private loggers in `lib/phoenix_kit_ai.ex` modeled on
`log_embedding_request/6` / `log_failed_embedding_request/…`.

1. **`lib/phoenix_kit_ai/request.ex`** — extend the allowlist:
   ```elixir
   @valid_request_types ~w(text_completion chat embedding tts)
   ```
   (Pure changeset `validate_inclusion`; no migration — confirmed no DB check constraint.)

2. **Success logger** — TTS responses carry **no token usage**; bill is per-character. Record
   what's meaningful:
   ```elixir
   defp log_tts_request(endpoint, text, result, source, stacktrace, caller_context) do
     capture = capture_request_content?()
     create_request(%{
       endpoint_uuid: endpoint.uuid,
       endpoint_name: endpoint.name,
       model: endpoint.model,
       request_type: "tts",
       latency_ms: result[:latency_ms],
       status: "success",
       metadata:
         %{source: source, stacktrace: stacktrace, caller_context: caller_context,
           input_chars: String.length(text), audio_format: result[:format],
           audio_bytes: byte_size(result[:audio])}
         |> then(&if capture, do: Map.put(&1, :input, text), else: Map.put(&1, :content_redacted, true))
     })
   end
   ```
   - Leave `input_tokens`/`output_tokens`/`total_tokens`/`cost_cents` unset (TTS has no token
     counts). If the host later wants cost, derive from `input_chars` app-side.
   - Honor the existing `capture_request_content?/0` gate (`config :phoenix_kit_ai,
     capture_request_content`) for the `:input` text, same as chat/embedding.

3. **Failure logger** — mirror `log_failed_embedding_request`: `request_type: "tts"`,
   `status: "error"`, `error_message: PhoenixKitAI.Errors.message(reason)`, metadata with
   `error_reason`, source, stacktrace, caller_context (text only if capture enabled).

---

## 7. Endpoint schema / config — no migration in v1

- Voice is a **per-call option** (the host app holds a per-language `{lang => voice}` map). The
  endpoint already has everything else (`model`, `provider`, `base_url`, credentials).
- If a per-endpoint **default voice** is desired later, store it in the existing
  `provider_settings` map (no migration; it's `:map`) and merge it into opts inside `speak/3`.
  Do **not** add dedicated columns for v1.

---

## 8. Errors

- Reuse `Completion.handle_error_status/2` (401/402/429/`{:api_error, status}`).
- Add `:invalid_audio_response` to `lib/phoenix_kit_ai/errors.ex` with a translated message
  (e.g. "The TTS provider returned an unreadable audio response.").
- Note Mistral returns **403** for content-moderation violations — it falls through to
  `{:api_error, 403}`. Optionally add a dedicated `:content_moderated` reason for 403 on the TTS
  path, but only if you can scope it to TTS without affecting chat/embeddings error mapping.
  Otherwise leave as `{:api_error, 403}`.

---

## 9. Optional: provider capability flag

`deps/phoenix_kit` `providers.ex` lists Mistral `capabilities: [:ai_completions,
:ai_embeddings]`. Adding `:ai_tts` would let the integration/endpoint admin UI advertise TTS,
but it is **not required** for `speak/3` to function (the endpoint already works for completions
with the same credentials). Treat as a separate, optional follow-up — coordinate with the
`phoenix_kit` package if pursued. Out of scope for the core change.

---

## 10. Tests

Follow the existing `Req.Test` stub pattern (`http_post/3` honors
`Application.get_env(:phoenix_kit_ai, :req_options, [])`, set in tests via
`Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, Stub})`):

- `speak/3` success with a base64-`audio_data` JSON stub → returns `{:ok, %{audio: bytes,
  format: "mp3"}}`, decoded bytes match.
- `speak/3` success with a raw-binary stub → same result (covers both response shapes).
- 401 / 402 / 429 / 500 stubs → mapped error reasons via `handle_error_status/2`.
- Garbage / empty body → `{:error, :invalid_audio_response}`.
- A `phoenix_kit_ai_requests` row is written with `request_type: "tts"` on both success and
  failure; `capture_request_content: false` redacts the input text.
- Disabled endpoint / missing model / missing credentials → existing `validate_endpoint/1`
  errors, no HTTP call made.

---

## 11. File-by-file change list

| File | Change |
|---|---|
| `lib/phoenix_kit_ai/completion.ex` | add `text_to_speech/3` + private `decode_audio/3`; (only if a raw-binary provider is added) a `decode_body: false` post path |
| `lib/phoenix_kit_ai.ex` | add public `speak/3`; add private `log_tts_request/6` + `log_failed_tts_request/…` |
| `lib/phoenix_kit_ai/request.ex` | add `"tts"` to `@valid_request_types` |
| `lib/phoenix_kit_ai/errors.ex` | add `:invalid_audio_response` (and optionally TTS `:content_moderated` for 403) |
| `test/...` | tests per §10 |
| `CHANGELOG.md` / version bump | per package convention |

---

## 12. Explicitly out of scope (host app, not this package)

- Storing the returned MP3 in PhoenixKit media / `priv/media`.
- Per-language voice selection, the `tts_voices` / `tts_ai_endpoint` settings, and the
  Practice-Sentences admin UI.
- Sentence schema columns linking audio to a sentence.
- Registering Voxtral voices and obtaining `voice_id`s.

These are tracked in `dev_docs/2026-06-10-sentence-voice-generation.md`.

---

## 13. Open items for the implementer to confirm

1. Exact voice field name the **hosted** Mistral API expects (`voice` vs `voice_id`) and whether
   it accepts preset voice names or only saved/cloned voice ids.
2. Whether the hosted response is base64-JSON (`audio_data`) or raw binary — the decoder handles
   both, but confirm so the happy path is the common one.
3. Whether `Req` needs `decode_body: false` for any raw-binary response (verify no mangling).
4. Package version/changelog conventions for the release.
