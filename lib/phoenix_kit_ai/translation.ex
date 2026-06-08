defmodule PhoenixKitAI.Translation do
  @moduledoc """
  Generic AI translation helper. Translates a `%{field_name => text}`
  map from `source_lang` to `target_lang` using the optional
  `PhoenixKitAI` plugin, and parses the structured response back into
  the same shape.

  Designed to be the single orchestration layer shared by every
  feature module that wants AI translation — `phoenix_kit_publishing`,
  `phoenix_kit_projects`, future consumers. Each module wraps this
  helper in its own Oban worker (or controller action) and owns the
  per-module storage write, broadcasts, caching, and per-resource
  activity log entry.

  ## What lives here

  - Prompt rendering with `{{SourceLanguage}}` / `{{TargetLanguage}}`
    / arbitrary field-name variables.
  - The `PhoenixKitAI.ask_with_prompt/4` call, guarded so absence of
    the plugin returns `{:error, :ai_not_installed}` instead of
    raising.
  - A structured-response parser for the `---FIELD_NAME---` shape
    that publishing's prompt template ships with. Generalised — any
    list of field names is accepted, ordering follows the input.
  - Error normalisation: every failure path returns
    `{:error, atom_or_tuple}` so callers can pattern-match without
    knowing whether the failure came from the plugin, the parser, or
    a network blip.
  - A single core activity-log entry (`core.ai_translation.requested`)
    on every dispatched request — gives Max a unified audit trail of
    AI token spend regardless of which feature module triggered it.
    Modules still log their own per-resource action (e.g.
    `publishing.translation.added`, `projects.translation.added`).

  ## What does NOT live here

  - Storage of the translation result — each consumer owns its own
    write path (publishing's `publishing_content` rows, projects'
    `Project.translations` JSONB, etc.).
  - Broadcasts — each consumer has its own PubSub topic shape.
  - Per-language status (in-flight, completed, errored) — that's the
    consumer's worker and the host UI.
  - Retry policy / queue choice — each consumer's Oban worker picks
    its own queue, max-attempts, and uniqueness constraints. This
    module is a synchronous function-call shape; consumers wrap it.

  ## Usage

      Translation.translate_fields(
        endpoint_uuid,
        prompt_uuid,
        "en",
        "es",
        %{"title" => "Hello", "body" => "World"}
      )
      # => {:ok, %{"title" => "Hola", "body" => "Mundo"}}
      # |  {:error, :ai_not_installed}
      # |  {:error, :no_endpoint}
      # |  {:error, :missing_prompt}
      # |  {:error, {:ai_error, reason}}
      # |  {:error, {:parse_error, reason}}
  """

  # `PhoenixKitAI` is an optional plugin — present at compile time only
  # when the host depends on `:phoenix_kit_ai`. Silence the unknown-MFA
  # warning for the specific call below so core compiles cleanly on hosts
  # that don't have it. Targeting the 3-tuple (instead of the whole
  # module) keeps real typos visible — a misspelled `PhoenixKitAI.asx_with_prompt`
  # still warns.
  @compile {:no_warn_undefined, [{PhoenixKitAI, :ask_with_prompt, 4}]}

  @core_activity_action "core.ai_translation.requested"

  @type field_map :: %{required(String.t()) => String.t()}
  @type translation_result ::
          {:ok, field_map()}
          | {:error,
             :ai_not_installed
             | :no_endpoint
             | :missing_prompt
             | {:ai_error, term()}
             | {:parse_error, term()}}

  @doc """
  Translate `fields` from `source_lang` to `target_lang`.

  - `endpoint_uuid` — UUID of a configured `PhoenixKitAI` endpoint.
    Required even when the plugin is installed; the plugin's prompt
    machinery binds to a specific endpoint at call time.
  - `prompt_uuid` — UUID of a `PhoenixKitAI.Prompt` whose template
    references `{{SourceLanguage}}`, `{{TargetLanguage}}`, and one
    `{{<FieldName>}}` placeholder per key in `fields`.
  - `source_lang` / `target_lang` — language codes (base or dialect;
    the helper passes them through unchanged).
  - `fields` — `%{field_name => text}` map. Field names become the
    structured-response markers (`---<FIELD_NAME>---`, uppercased).

  ## Options

  - `:actor_uuid` — included in the `core.ai_translation.requested`
    activity log entry. When omitted the log is still written with
    `actor_uuid: nil`.
  - `:resource_type` / `:resource_uuid` — let the audit log point at
    the row being translated.
  - `:source` — string identifier for the calling module (e.g.
    `"Publishing.TranslatePostWorker"`); included in the
    `PhoenixKitAI` request log so usage reports break down by caller.
  """
  @spec translate_fields(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          field_map(),
          keyword()
        ) :: translation_result()
  def translate_fields(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts \\ [])
      when is_map(fields) and is_binary(source_lang) and is_binary(target_lang) do
    # Order matters: validate inputs first so callers can unit-test the
    # argument-validation contract without needing the optional plugin
    # loaded. The plugin-availability check is a system-state question,
    # not an input-shape question — fail fast on bad args either way.
    with :ok <- validate_uuid(endpoint_uuid, :no_endpoint),
         :ok <- validate_uuid(prompt_uuid, :missing_prompt),
         :ok <- validate_non_empty(fields),
         :ok <- validate_unique_markers(Map.keys(fields)),
         :ok <- ensure_available() do
      do_translate(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts)
    end
  end

  # Short-circuit before dispatching to the AI plugin — an empty
  # `fields` map would render a prompt with no field variables, spend
  # real tokens on a `PhoenixKitAI.ask_with_prompt/4` call, and then
  # fail downstream in `parse_response/2` with `:no_markers`. Cheap to
  # reject up front. The error sentinel mirrors `parse_response/2`'s
  # shape so callers don't have to branch on a new error class.
  defp validate_non_empty(fields) when map_size(fields) == 0,
    do: {:error, {:parse_error, :no_markers}}

  defp validate_non_empty(_fields), do: :ok

  defp validate_uuid(value, error) when is_binary(value) do
    if String.trim(value) == "", do: {:error, error}, else: :ok
  end

  defp validate_uuid(_value, error), do: {:error, error}

  # Two field names like `"foo-bar"` and `"foo_bar"` both normalise to
  # the marker `FOO_BAR`. Reject duplicates at entry — silently
  # overwriting one field with another's translation is worse than
  # crashing with a clear error.
  defp validate_unique_markers(field_names) do
    normalised = Enum.map(field_names, &marker/1)

    if length(Enum.uniq(normalised)) == length(normalised) do
      :ok
    else
      duplicates =
        normalised
        |> Enum.frequencies()
        |> Enum.filter(fn {_, n} -> n > 1 end)
        |> Enum.map(fn {marker, _} -> marker end)

      {:error, {:parse_error, {:duplicate_markers, duplicates}}}
    end
  end

  defp ensure_available do
    if function_exported?(PhoenixKitAI, :ask_with_prompt, 4),
      do: :ok,
      else: {:error, :ai_not_installed}
  end

  defp do_translate(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts) do
    # Field names are used verbatim as prompt-variable keys (unlike markers,
    # which are upcased) so existing TitleCase/original-casing prompts keep
    # working. `fields` keys are strings per the contract, so they merge in
    # directly alongside the language slots.
    variables =
      Map.merge(fields, %{
        "SourceLanguage" => source_lang,
        "TargetLanguage" => target_lang
      })

    ai_opts =
      opts
      |> Keyword.take([:source])
      |> Keyword.put_new(:source, "PhoenixKitAI.Translation")

    log_request(source_lang, target_lang, Map.keys(fields), opts)

    # Wrap the plugin call so unexpected return shapes, raised
    # exceptions, GenServer.call exits, and throws all come out as
    # `{:error, {:ai_error, _}}` — matching the documented contract.
    # The plugin uses `GenServer.call/3` internally for streaming
    # endpoints; that exits the caller process by default on timeout,
    # which `rescue` alone wouldn't catch.
    try do
      case PhoenixKitAI.ask_with_prompt(endpoint_uuid, prompt_uuid, variables, ai_opts) do
        {:ok, response} ->
          handle_ai_response(response, fields)

        {:error, reason} ->
          {:error, {:ai_error, reason}}

        other ->
          {:error, {:ai_error, {:unexpected_return, other}}}
      end
    rescue
      e -> {:error, {:ai_error, {:exception, Exception.message(e)}}}
    catch
      :exit, reason -> {:error, {:ai_error, {:exit, reason}}}
      :throw, value -> {:error, {:ai_error, {:throw, value}}}
    end
  end

  # `PhoenixKitAI.ask_with_prompt/4` returns the full OpenAI-shaped
  # response map (`%{"choices" => [%{"message" => %{"content" => "..."}}]}`),
  # not a raw string. We extract the assistant's content inline rather
  # than via `PhoenixKitAI.Completion.extract_content/1` so the helper
  # has no cross-module dep on the optional plugin — works in core's
  # test env (plugin absent) and any host (plugin present, any
  # version). The shape is OpenAI-standard so the inline match is
  # stable.
  #
  # KEEP IN SYNC with `PhoenixKitAI.Completion.extract_content/1`: this
  # is a deliberate second source of truth for "pull the assistant text
  # out of a completion." If that helper grows to normalise additional
  # provider/response shapes, mirror the relevant ones here or this
  # clause will reject them as `:unexpected_response`.
  #
  # Older plugin versions (or test stubs) may still return a plain
  # binary; the second clause keeps that path working.

  @doc false
  # Public-for-testing entry point so the OpenAI-shape extraction can
  # be unit-tested without spinning up the live `PhoenixKitAI`
  # plugin. Production callers go through `do_translate/6`.
  def handle_ai_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}, fields)
      when is_binary(content) do
    parse_response(content, Map.keys(fields))
  end

  def handle_ai_response(response, fields) when is_binary(response) do
    parse_response(response, Map.keys(fields))
  end

  def handle_ai_response(other, _fields) do
    {:error, {:ai_error, {:unexpected_response, other}}}
  end

  @doc """
  Parses a structured `---FIELD_NAME---` response into a field map.

  Public for testing — consumers normally hit `translate_fields/6`,
  which calls this internally. Useful when a caller already has the
  raw AI response (e.g. a previously cached completion) and just
  needs to extract field values.

  Field names are matched case-insensitively against the markers but
  the returned map preserves the input casing of `fields` so callers
  can round-trip with their original field-name strings.

  **All requested fields must be present** in the response. When the
  model returns a partial response (e.g. it forgot the `---SLUG---`
  marker), this function returns
  `{:error, {:parse_error, {:missing_fields, [...]}}}` so the caller
  can decide whether to retry, fall back to the source value, or
  surface an error to the user — rather than silently persisting a
  half-translated row.

      iex> Translation.parse_response(
      ...>   "---TITLE---\\nHola\\n---BODY---\\nMundo",
      ...>   ["title", "body"]
      ...> )
      {:ok, %{"title" => "Hola", "body" => "Mundo"}}

      iex> Translation.parse_response("---TITLE---\\nonly", ["title", "body"])
      {:error, {:parse_error, {:missing_fields, ["body"]}}}

      iex> Translation.parse_response(":shrug:", ["title"])
      {:error, {:parse_error, :no_markers}}
  """
  @spec parse_response(String.t(), [String.t()]) ::
          {:ok, field_map()} | {:error, {:parse_error, term()}}
  def parse_response(response, field_names) when is_binary(response) and is_list(field_names) do
    upcased = Enum.map(field_names, &{&1, marker(&1)})
    body = response |> strip_reasoning() |> String.trim()

    parsed =
      Enum.reduce(upcased, %{}, fn {name, marker}, acc ->
        case extract_section(body, marker, upcased) do
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      end)

    missing = for name <- field_names, not Map.has_key?(parsed, name), do: name

    cond do
      map_size(parsed) == 0 -> {:error, {:parse_error, :no_markers}}
      missing != [] -> {:error, {:parse_error, {:missing_fields, missing}}}
      true -> {:ok, parsed}
    end
  end

  defp marker(field) when is_binary(field) do
    field |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")
  end

  # Reasoning / "thinking" models (DeepSeek-R1, QwQ, etc.) wrap their
  # chain-of-thought in `<think>…</think>` (also `<thinking>`/`<reasoning>`/
  # `<thought>`) before the real answer. That prose routinely *mentions* the
  # field markers inline ("…so skip ---TITLE---…"), which the extractor would
  # otherwise capture as a field value — overflowing the consumer's column on
  # persist. Strip balanced reasoning blocks before parsing.
  #
  # Only *balanced* blocks are removed: a truncated/unclosed `<think>` is left
  # alone (deleting to end-of-string could discard the real answer), and the
  # start-of-line marker anchor in `extract_section/3` + the `:no_markers`
  # guard handle whatever survives. Pairing the strip with the line anchor is
  # what turns a silent persist failure into a clean `:no_markers` parse error.
  @reasoning_block ~r{<\s*(think|thinking|reasoning|thought)\s*>.*?<\s*/\s*\1\s*>}is

  defp strip_reasoning(text), do: Regex.replace(@reasoning_block, text, "")

  # Pulls the text between `---MARKER---` and the next `---OTHER---`
  # marker (or end-of-string). Returns nil when the marker isn't
  # present.
  defp extract_section(body, marker, _all_markers) do
    # Boundary matches ANY `---<NAME>---` marker, not just the
    # requested-field markers. Without that, an AI that emits a
    # marker the caller didn't ask for (e.g. an extra `---TITLE---`
    # because the prompt template referenced `{{title}}` with no
    # variable bound, leaving the literal text in the rendered
    # prompt) gets that block's content rolled into the previous
    # requested field. The marker name pattern intentionally accepts
    # the same character class `marker/1` normalises field names
    # into: uppercase letters, digits, underscores.
    #
    # The `\n` before `---` is load-bearing: real AI-emitted markers
    # always start on their own line, so requiring a newline before
    # the boundary avoids prematurely terminating a capture when the
    # translated content happens to contain a literal `---WORD---`
    # token mid-paragraph (technical docs, API examples).
    #
    # `i` flag: markers are normalised to uppercase by `marker/1`,
    # but a model may emit them lowercased (`---title---`). Case-
    # insensitive matching keeps the documented "case-insensitive
    # marker matching" contract honest.
    #
    # `(.*?)` (not `.+?`) so a present-but-empty *trailing* marker
    # (`...\n---BODY---` at end-of-string) captures `""` and is
    # recorded as an empty field, matching how an empty *middle*
    # section resolves via the guard below. An entirely absent marker
    # still fails the `---MARKER---` literal and returns `nil` →
    # `missing_fields`, so the "model forgot a marker" signal is
    # preserved. The empty match only succeeds at `\z` (greedy `\s*`
    # always eats the newline before an inter-marker boundary), so a
    # mid-document field with real content is never falsely emptied.
    # The opening marker must START A LINE (`\A` or right after a `\n`), not
    # appear mid-sentence. Reasoning models narrate the markers inline
    # ("…so skip ---TITLE---…"); without this anchor that mention matches as a
    # section opener and swallows the surrounding prose into the field. Real
    # prompt-emitted markers always sit on their own line, so anchoring is safe
    # and mirrors the boundary lookahead, which already requires a leading `\n`.
    pattern = ~r/(?:\A|\n)---#{Regex.escape(marker)}---\s*\n?(.*?)(?=\n---[A-Z0-9_]+---|\z)/si

    case Regex.run(pattern, body) do
      [_, value] ->
        # Empty-section guard: when a section is truly empty (e.g.
        # `---TITLE---\n---BODY---\n...`), `\s*\n?` will consume the
        # `\n` between the markers and `(.+?)` starts capturing
        # `---BODY---\n...` as TITLE's content. The lookahead can't
        # rescue it because it requires a leading `\n` (which the
        # previous `\s*` already ate). Detect after the fact: if the
        # captured value starts with what LOOKS like another marker,
        # the original section had no content — return `""` so the
        # parser records it as empty rather than misattributing the
        # next field's content. The boundary regex up above ensures
        # only "real" marker shapes trigger this; legitimately
        # translated content that begins with `---WORD---` would be
        # an unlikely UI translation, and the cost of misclassifying
        # that as empty is lower than misattributing a whole field.
        trimmed = String.trim(value)

        if Regex.match?(~r/\A---[A-Z0-9_]+---/i, trimmed) do
          ""
        else
          trimmed
        end

      _ ->
        nil
    end
  end

  # Writes one `core.ai_translation.requested` audit entry per dispatched
  # request. The host's worker also logs its own per-resource action
  # (e.g. `publishing.translation.added`); this entry is the unified
  # token-spend audit trail.
  #
  # If `PhoenixKit.Activity` isn't loaded (host has the module disabled)
  # the log is skipped silently. Beyond that we let `Activity.log/1`
  # failures propagate — a DB-level problem here is the same bug we'd
  # want to see in any other log site, and the caller (an Oban worker
  # in every documented consumer) owns retry policy.
  defp log_request(source_lang, target_lang, field_names, opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) and
         function_exported?(PhoenixKit.Activity, :log, 1) do
      PhoenixKit.Activity.log(%{
        action: @core_activity_action,
        module: "ai",
        mode: "auto",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type, "ai_translation"),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        metadata: %{
          "source_lang" => source_lang,
          "target_lang" => target_lang,
          "field_count" => length(field_names),
          "fields" => field_names
        }
      })
    end
  end
end
