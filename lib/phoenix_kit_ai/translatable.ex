defmodule PhoenixKitAI.Translatable do
  @moduledoc """
  Behaviour a feature module implements to make a resource AI-translatable
  through core's generic translation pipeline
  (`PhoenixKitAI.TranslateWorker` +
  `PhoenixKitAI.Translations`).

  An adapter is the *only* per-module code needed — the load, the field
  extraction, and the persist. Everything else (enqueue, the Oban worker,
  the AI call, parsing, broadcasts, the audit log, retry policy) lives in
  core and is shared across every consumer.

  ## Registration

  The feature module exposes its adapters via the optional
  `ai_translatables/0` callback on `PhoenixKit.Module`, returning
  `[{resource_type, adapter_module}]`:

      @impl PhoenixKit.Module
      def ai_translatables do
        [
          {"catalogue", PhoenixKitCatalogue.AITranslatable},
          {"catalogue_category", PhoenixKitCatalogue.AITranslatable},
          {"catalogue_item", PhoenixKitCatalogue.AITranslatable}
        ]
      end

  `resource_type` strings MUST be globally unique across all modules —
  namespace them (`"catalogue_item"`, not `"item"`). The same adapter
  module may serve several resource types; it dispatches on the
  `resource_type` argument passed to each callback.

  ## Storage contract

  `put_translation/4` owns the write and MUST be **atomic + merge-safe**.
  `enqueue_all_missing/2` dispatches one concurrent job per target language,
  so several jobs write the *same row's* translation store at once. The
  `resource` struct handed in was loaded BEFORE the (multi-second) AI call,
  so it is stale by persist time — merging the new language into that
  in-memory struct and doing a plain update will silently drop sibling
  languages other jobs committed in the meantime.

  Persist against the **current** row, one of:

  - a single atomic SQL write to the per-language path, e.g.
    `jsonb_set(coalesce(data, '{}'), {translations, <lang>}, <fields>, true)`
    via `update_all` (different languages touch different paths → no
    conflict); or
  - a `Repo.transaction` that re-reads the row `lock: "FOR UPDATE"`, merges,
    and writes.

  Either keeps the multilang form's edit round-trip working unchanged.
  """

  @type resource_type :: String.t()
  @type lang :: String.t()
  @type fields :: %{optional(String.t()) => String.t()}

  @doc "Load a resource by its (type, uuid). `{:error, :resource_not_found}` when absent."
  @callback fetch(resource_type(), uuid :: String.t()) :: {:ok, struct()} | {:error, term()}

  @doc """
  Optional scoped load — `fetch/2` plus an opaque `scope` (the `resource_scope`
  enqueue param, threaded verbatim through the Oban job). Lets a versioned or
  partitioned resource load the exact slice being translated instead of a
  default.

  `scope` is a JSON-safe value (it round-trips through Oban args) — typically a
  string the adapter interprets (e.g. a version number), or `nil`. **A `nil`
  scope MUST behave identically to `fetch/2`** (the default slice), so jobs
  enqueued before scoping existed keep working unchanged.

  Optional: when an adapter does not export `fetch/3`, the worker falls back to
  `fetch/2`. Adapters that implement `fetch/3` should still implement `fetch/2`
  (delegating with a `nil` scope) to satisfy the required arity.
  """
  @callback fetch(resource_type(), uuid :: String.t(), scope :: term() | nil) ::
              {:ok, struct()} | {:error, term()}

  @doc """
  The `%{field_name => text}` to translate, read in `source_lang`.

  Return only non-empty fields — empty ones waste tokens and confuse the
  model. Field names become the prompt variables + `---FIELD---` markers.
  """
  @callback source_fields(resource :: struct(), source_lang :: lang()) :: fields()

  @doc """
  Persist `fields` into `resource` for `target_lang`. Must merge (not
  clobber other languages). `opts` carries `:actor_uuid`.
  """
  @callback put_translation(
              resource :: struct(),
              target_lang :: lang(),
              fields :: fields(),
              opts :: keyword()
            ) :: {:ok, struct()} | {:error, term()}

  @doc """
  Optional extra PubSub topics (besides the core translation topic) to
  fan status events out on — e.g. the module's own resource topic so an
  already-subscribed LV gets translation lifecycle events too.
  """
  @callback pubsub_topics(resource :: struct()) :: [binary()]

  @optional_callbacks pubsub_topics: 1, fetch: 3
end
