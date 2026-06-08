defmodule PhoenixKitAI.TranslateWorker do
  @moduledoc """
  Generic Oban worker that translates one resource's fields into a single
  target language, shared by every consumer module.

  Resolves a `PhoenixKitAI.Translatable` adapter from the
  job's `resource_type` (registered via `ai_translatables/0` and
  discovered through `PhoenixKitAI.Translatables`), then runs:

      adapter.fetch/3-or-2 → adapter.source_fields/2 →
      Translation.translate_fields/6 → adapter.put_translation/4

  broadcasting `{:ai_translation, event, payload}` at each lifecycle step
  (see `PhoenixKitAI.Translations`) and writing one
  `ai.translation_added` activity entry on success.

  ## Job args

      %{
        "resource_type" => "catalogue_item",
        "resource_uuid" => uuid,
        "endpoint_uuid" => uuid,
        "prompt_uuid"   => uuid,
        "source_lang"   => "en",
        "target_lang"   => "es",
        "actor_uuid"    => uuid_or_nil,
        "resource_scope" => scope_or_nil
      }

  `resource_scope` is an optional, opaque, JSON-safe string partitioning a
  resource's jobs (e.g. a version number). When present and the adapter exports
  `fetch/3`, it's passed through so the adapter loads that exact slice; `nil`
  (or absent) means the default slice via `fetch/2`.

  ## De-duplication

  De-dup is **app-level** in `PhoenixKitAI.Translations.enqueue/1`
  (one in-flight job per `(resource_type, resource_uuid, resource_scope,
  target_lang)`), NOT
  Oban's built-in `unique:`. Oban's uniqueness query references the
  `:suspended` job state, which is absent from the `oban_job_state` enum on
  hosts that upgraded the Oban *lib* ahead of its *migration* — there the
  query raises `22P02` and kills every enqueue. The app guard queries only
  the four always-present states (`available`/`scheduled`/`executing`/
  `retryable`) and fails open. Same trade-off as the catalogue PDF worker.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias PhoenixKitAI.{Translation, Translations}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, type} <- fetch_arg(args, "resource_type"),
         {:ok, uuid} <- fetch_arg(args, "resource_uuid"),
         {:ok, endpoint} <- fetch_arg(args, "endpoint_uuid"),
         {:ok, prompt} <- fetch_arg(args, "prompt_uuid"),
         {:ok, source} <- fetch_arg(args, "source_lang"),
         {:ok, target} <- fetch_arg(args, "target_lang"),
         {:ok, adapter} <- resolve_adapter(type),
         scope = Map.get(args, "resource_scope"),
         {:ok, resource} <- load_resource(adapter, type, uuid, scope) do
      do_translate(%{
        type: type,
        uuid: uuid,
        endpoint: endpoint,
        prompt: prompt,
        source: source,
        target: target,
        scope: scope,
        actor: Map.get(args, "actor_uuid"),
        adapter: adapter,
        resource: resource,
        attempt: job.attempt,
        max_attempts: job.max_attempts
      })
    else
      {:error, reason} ->
        # Deterministic setup failure (bad args, unknown adapter, missing
        # row) — not worth retrying. Surface a normalised failure on the
        # global topic (we may lack a per-resource topic), then discard.
        Translations.broadcast(:translation_failed, %{
          resource_type: Map.get(args, "resource_type"),
          resource_uuid: Map.get(args, "resource_uuid"),
          resource_scope: Map.get(args, "resource_scope"),
          source_lang: Map.get(args, "source_lang"),
          target_lang: Map.get(args, "target_lang"),
          reason: reason
        })

        {:discard, reason}
    end
  end

  defp do_translate(ctx) do
    broadcast(ctx, :translation_started, %{})

    case safe_source_fields(ctx) do
      {:error, reason} ->
        # Adapter misbehaved (crashed or returned a non-`%{String=>String}`
        # map). Deterministic — discard with a clean failure broadcast.
        fail(ctx, {:adapter_error, reason}, retry?: false)

      fields when map_size(fields) == 0 ->
        # Nothing to translate — treat as success so the host clears its
        # spinner; the resource just has no source content for these fields.
        broadcast(ctx, :translation_completed, %{fields: %{}, empty: true})
        :ok

      fields ->
        case Translation.translate_fields(
               ctx.endpoint,
               ctx.prompt,
               ctx.source,
               ctx.target,
               fields,
               actor_uuid: ctx.actor,
               resource_type: ctx.type,
               resource_uuid: ctx.uuid,
               source: "PhoenixKitAI.TranslateWorker"
             ) do
          {:ok, translated} ->
            persist(ctx, translated)

          # Rate-limited: snooze instead of consuming a retry attempt, so a
          # burst of concurrent jobs (enqueue_all_missing) backs off and
          # drains rather than exhausting max_attempts. The language stays
          # in-flight on the UI (no terminal broadcast) until it lands.
          {:error, {:ai_error, :rate_limited}} ->
            {:snooze, 30}

          {:error, reason} ->
            fail(ctx, reason, retry?: retryable?(reason))
        end
    end
  end

  defp persist(ctx, translated) do
    case safe_put_translation(ctx, translated) do
      {:ok, _updated} ->
        log_added(ctx, translated)
        broadcast(ctx, :translation_completed, %{fields: translated})
        :ok

      {:error, reason} ->
        Logger.warning(
          "[AI.TranslateWorker] persist failed for #{ctx.type} #{ctx.uuid}: #{inspect(reason)}"
        )

        # Persist failures are deterministic (changeset/constraint) — discard.
        fail(ctx, {:persist_error, reason}, retry?: false)
    end
  end

  # Broadcast a terminal failure only when the job won't be retried (either
  # deterministic, or the final attempt). During a pending retry we stay
  # silent so a host UI keeps its spinner rather than flashing a failure the
  # next attempt may clear.
  defp fail(ctx, reason, retry?: retry?) do
    Logger.warning(
      "[AI.TranslateWorker] translation failed for #{ctx.type} #{ctx.uuid} → #{ctx.target} " <>
        "(attempt #{ctx.attempt}/#{ctx.max_attempts}): #{inspect(reason)}"
    )

    final? = ctx.attempt >= ctx.max_attempts

    cond do
      retry? and not final? ->
        {:error, reason}

      retry? ->
        # Out of attempts — now it's terminal, so surface it.
        broadcast(ctx, :translation_failed, %{reason: reason})
        {:error, reason}

      true ->
        broadcast(ctx, :translation_failed, %{reason: reason})
        {:discard, reason}
    end
  end

  # Adapter callbacks are external module code — normalize crashes and bad
  # return shapes into `{:error, _}` instead of letting them blow up the
  # worker after `:translation_started` (which would retry with no clean
  # failure signal).
  defp safe_source_fields(ctx) do
    case ctx.adapter.source_fields(ctx.resource, ctx.source) do
      map when is_map(map) -> validate_source_map(map)
      other -> {:error, {:bad_source_fields, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp validate_source_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      map
    else
      {:error, :non_string_fields}
    end
  end

  defp safe_put_translation(ctx, translated) do
    case ctx.adapter.put_translation(ctx.resource, ctx.target, translated, actor_uuid: ctx.actor) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_put_translation, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # ── Adapter resolution + loading ─────────────────────────────────

  defp resolve_adapter(type) do
    case PhoenixKitAI.Translatables.find(type) do
      nil -> {:error, {:no_adapter, type}}
      adapter -> {:ok, adapter}
    end
  end

  # Prefer the scoped `fetch/3` when the adapter exports it (load the exact
  # slice the `resource_scope` names); otherwise fall back to `fetch/2`. Guard
  # `function_exported?/3` with `ensure_loaded?/1` — it returns false for a
  # not-yet-loaded module, which would silently drop the scope.
  defp load_resource(adapter, type, uuid, scope) do
    result =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :fetch, 3) do
        adapter.fetch(type, uuid, scope)
      else
        adapter.fetch(type, uuid)
      end

    case result do
      {:ok, resource} -> {:ok, resource}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_adapter_fetch, other}}
    end
  end

  # ── Broadcast + activity ─────────────────────────────────────────

  defp broadcast(ctx, event, extra) do
    payload =
      Map.merge(
        %{
          resource_type: ctx.type,
          resource_uuid: ctx.uuid,
          resource_scope: ctx.scope,
          source_lang: ctx.source,
          target_lang: ctx.target
        },
        extra
      )

    Translations.broadcast(event, payload, adapter_topics(ctx))
  end

  defp adapter_topics(%{adapter: adapter, resource: resource}) do
    if function_exported?(adapter, :pubsub_topics, 1) do
      case adapter.pubsub_topics(resource) do
        topics when is_list(topics) -> topics
        _ -> []
      end
    else
      []
    end
  rescue
    # A broadcast helper must never crash the worker — drop extra topics.
    _ -> []
  end

  # Only record resource_scope when present, so unversioned resources' audit
  # entries stay unchanged.
  defp maybe_put_scope(metadata, nil), do: metadata
  defp maybe_put_scope(metadata, scope), do: Map.put(metadata, "resource_scope", scope)

  defp log_added(ctx, translated) do
    if Code.ensure_loaded?(PhoenixKit.Activity) and
         function_exported?(PhoenixKit.Activity, :log, 1) do
      PhoenixKit.Activity.log(%{
        action: "ai.translation_added",
        module: "ai",
        mode: "auto",
        actor_uuid: ctx.actor,
        resource_type: ctx.type,
        resource_uuid: ctx.uuid,
        metadata:
          %{
            "source_lang" => ctx.source,
            "target_lang" => ctx.target,
            "fields" => Map.keys(translated)
          }
          |> maybe_put_scope(ctx.scope)
      })
    end
  rescue
    # The audit entry is best-effort — a logging failure must not fail an
    # otherwise-successful translation (the row is already persisted).
    error ->
      Logger.warning("[AI.TranslateWorker] activity log failed: #{Exception.message(error)}")
      :ok
  end

  # ── Retry classification ─────────────────────────────────────────

  @doc false
  @spec retryable?(term()) :: boolean()
  def retryable?({:ai_error, :request_timeout}), do: true
  # `PhoenixKitAI.Completion` normalizes a transport timeout to `:request_timeout`
  # (above) before it reaches this worker. The bare `:timeout` below is a
  # defensive fallback for any provider/path that surfaces the raw atom instead —
  # a timeout is transient, so retry rather than discard.
  def retryable?({:ai_error, :timeout}), do: true
  def retryable?({:ai_error, :rate_limited}), do: true
  def retryable?({:ai_error, {:connection_error, _}}), do: true
  def retryable?({:ai_error, {:exit, _}}), do: true

  # Defense-in-depth: the built-in OpenRouter client maps HTTP 429 to the
  # `:rate_limited` atom (handled as `{:snooze, 30}` in `do_translate/1`, before
  # this is consulted). A custom/future provider that instead surfaces a bare
  # `{:api_error, 429}` should still retry — 429 is the canonical retry-after.
  def retryable?({:ai_error, {:api_error, 429}}), do: true

  def retryable?({:ai_error, {:api_error, status}})
      when status in [500, 502, 503, 504, 522, 524, 529],
      do: true

  def retryable?(_), do: false

  # ── Args ─────────────────────────────────────────────────────────

  defp fetch_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_arg, key}}
    end
  end
end
