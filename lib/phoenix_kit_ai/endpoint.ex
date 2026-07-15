defmodule PhoenixKitAI.Endpoint do
  @moduledoc """
  AI endpoint schema for PhoenixKit AI system.

  An endpoint is a unified configuration that combines provider credentials,
  model selection, and generation parameters into a single entity. Each endpoint
  represents one complete AI configuration ready for making API requests.

  ## Schema Fields

  ### Identity
  - `name`: Display name for the endpoint (e.g., "Claude Fast", "GPT-4 Creative")
  - `description`: Optional description of the endpoint's purpose

  ### Provider Configuration
  - `provider`: Integration connection key (e.g. `"openrouter"` or
    `"openrouter:my-key"`). Resolved via `PhoenixKit.Integrations`.
  - `api_key`: **Deprecated.** Legacy field retained for pre-Integrations
    endpoints — `OpenRouterClient.resolve_api_key/2` reads it as a fallback
    when no `PhoenixKit.Integrations` connection is configured for the
    endpoint's `provider`. The column is `NOT NULL` in core's V34
    migration, so for now you must provide a value (an empty string is
    accepted by the DB but will trigger a per-call `Logger.warning`
    if no Integrations connection is set up either). The recommended
    migration path is documented in `AGENTS.md` "Migrating from legacy
    `endpoint.api_key`" — set up an OpenRouter connection under Settings
    → Integrations and point `provider` at it; the legacy column then
    becomes unused. Planned for removal in a future major version once
    operators have had time to migrate.
  - `base_url`: Optional custom base URL for the provider
  - `provider_settings`: Provider-specific settings (JSON)
    - For OpenRouter: `http_referer`, `x_title` headers
    - For TTS: `voice` — default voice / voice id used by `PhoenixKitAI.speak/3`
      when the caller passes no explicit voice

  ### Model Configuration
  - `model`: AI model identifier (e.g., "anthropic/claude-3-haiku")

  ### Generation Parameters
  - `temperature`: Sampling temperature (0-2, default: 0.7)
  - `max_tokens`: Maximum tokens to generate (nil = model default)
  - `top_p`: Nucleus sampling threshold (0-1)
  - `top_k`: Top-k sampling parameter
  - `frequency_penalty`: Frequency penalty (-2 to 2)
  - `presence_penalty`: Presence penalty (-2 to 2)
  - `repetition_penalty`: Repetition penalty (0-2)
  - `stop`: Stop sequences (array of strings)
  - `seed`: Random seed for reproducibility

  ### Image Generation Parameters
  - `image_size`: Image size (e.g., "1024x1024", "1792x1024")
  - `image_quality`: Image quality ("standard", "hd")

  ### Embeddings Parameters
  - `dimensions`: Embedding dimensions (model-specific)

  ### Status
  - `enabled`: Whether the endpoint is active
  - `sort_order`: Display order for listing
  - `last_validated_at`: Last successful API key validation

  ## Usage Examples

      # Create an endpoint
      {:ok, endpoint} = PhoenixKitAI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })

      # Use the endpoint
      {:ok, response} = PhoenixKitAI.ask(endpoint.uuid, "Hello!")
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # Providers are discovered from the Integrations registry by capability,
  # not hardcoded: any provider declaring this capability (built-in or
  # contributed by an external module) is a valid AI endpoint provider.
  @ai_capability :ai_completions

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :name,
             :description,
             :integration_uuid,
             :provider,
             :base_url,
             :provider_settings,
             :model,
             :temperature,
             :max_tokens,
             :top_p,
             :top_k,
             :frequency_penalty,
             :presence_penalty,
             :repetition_penalty,
             :stop,
             :seed,
             :image_size,
             :image_quality,
             :dimensions,
             :reasoning_enabled,
             :reasoning_effort,
             :reasoning_max_tokens,
             :reasoning_exclude,
             :enabled,
             :sort_order,
             :last_validated_at,
             :inserted_at,
             :updated_at
           ]}

  schema "phoenix_kit_ai_endpoints" do
    # Identity
    field(:name, :string)
    field(:description, :string)

    # Provider configuration
    #
    # `integration_uuid` references a `phoenix_kit_settings` row (the
    # actual integration connection the user picked). `OpenRouterClient`
    # resolves credentials by uuid, so renaming the integration on the
    # admin side doesn't break this endpoint.
    #
    # `provider` and `api_key` are legacy. `provider` carried either a
    # provider-type tag (`"openrouter"`) or, more recently, an integration
    # uuid stuffed into a string column. Both are now subsumed by
    # `integration_uuid`. They remain on the schema for the transition
    # window — the V107 migration backfilled `integration_uuid` from
    # `provider`, and the legacy api_key column has its own warning path
    # — but new code paths should ignore them.
    field(:integration_uuid, :binary_id)
    field(:provider, :string, default: "openrouter")
    field(:api_key, :string)
    field(:base_url, :string)
    field(:provider_settings, :map, default: %{})

    # Model configuration
    field(:model, :string)

    # Generation parameters
    field(:temperature, :float, default: 0.7)
    field(:max_tokens, :integer)
    field(:top_p, :float)
    field(:top_k, :integer)
    field(:frequency_penalty, :float)
    field(:presence_penalty, :float)
    field(:repetition_penalty, :float)
    field(:stop, {:array, :string})
    field(:seed, :integer)

    # Image generation parameters
    field(:image_size, :string)
    field(:image_quality, :string)

    # Embeddings parameters
    field(:dimensions, :integer)

    # Reasoning/thinking parameters (for models like DeepSeek R1, Qwen QwQ, etc.)
    field(:reasoning_enabled, :boolean)
    field(:reasoning_effort, :string)
    field(:reasoning_max_tokens, :integer)
    field(:reasoning_exclude, :boolean)

    # Status
    field(:enabled, :boolean, default: true)
    field(:sort_order, :integer, default: 0)
    field(:last_validated_at, :utc_datetime)

    has_many(:requests, PhoenixKitAI.Request,
      foreign_key: :endpoint_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for endpoint creation and updates.
  """
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :name,
      :description,
      :integration_uuid,
      :provider,
      :api_key,
      :base_url,
      :provider_settings,
      :model,
      :temperature,
      :max_tokens,
      :top_p,
      :top_k,
      :frequency_penalty,
      :presence_penalty,
      :repetition_penalty,
      :stop,
      :seed,
      :image_size,
      :image_quality,
      :dimensions,
      :reasoning_enabled,
      :reasoning_effort,
      :reasoning_max_tokens,
      :reasoning_exclude,
      :enabled,
      :sort_order,
      :last_validated_at
    ])
    |> validate_required([:name, :provider, :model])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_temperature()
    |> validate_penalties()
    |> validate_reasoning()
    |> maybe_set_default_base_url()
    |> validate_base_url()
    |> maybe_clear_legacy_api_key()
    |> unique_constraint(:name)
  end

  # When an endpoint is being linked to an Integrations row (via
  # `integration_uuid`), clear the legacy `api_key` column in the same
  # changeset so the write is atomic. Once a user explicitly chooses the
  # integration as the source of truth, the legacy column should not
  # silently survive as a stale fallback — it would mask config drift
  # and rot quietly. The column itself stays in the schema; only the
  # value is wiped so a manual recovery via direct DB edit is still
  # possible if something goes catastrophically wrong.
  #
  # Cleared to `""` rather than `nil` because the column is `NOT NULL`
  # (V34 schema). Both the recovery-card render condition
  # (`api_key && api_key != ""`) and the OpenRouterClient fallback chain
  # (`maybe_get_credentials("") => {:error, :not_configured}`) treat the
  # empty string as "no fallback configured" — same semantics as NULL,
  # without needing a schema relaxation.
  #
  # Only fires when the changeset is actually CHANGING `integration_uuid`
  # to a non-empty value. A no-op edit (saving the form without touching
  # the integration field) leaves `api_key` alone.
  defp maybe_clear_legacy_api_key(changeset) do
    case fetch_change(changeset, :integration_uuid) do
      {:ok, uuid} when is_binary(uuid) and uuid != "" ->
        put_change(changeset, :api_key, "")

      _ ->
        changeset
    end
  end

  @doc """
  Creates a changeset for updating the last_validated_at timestamp.
  """
  def validation_changeset(endpoint) do
    change(endpoint, last_validated_at: UtilsDate.utc_now())
  end

  @doc """
  Returns the list of valid provider keys.

  Discovered from the Integrations registry — every provider declaring the
  `:ai_completions` capability (built-in, or contributed by an external
  module via `integration_providers/0`). Adding a chat provider to the
  registry makes it valid here automatically; nothing is hardcoded.
  """
  @spec valid_providers() :: [String.t()]
  def valid_providers do
    Enum.map(Providers.with_capability(@ai_capability), & &1.key)
  end

  @doc """
  Returns provider options (`{label, key}`) for form selects.

  Built from the same capability-discovered list as `valid_providers/0`;
  labels come from each provider's registry name.
  """
  @spec provider_options() :: [{String.t(), String.t()}]
  def provider_options do
    Enum.map(Providers.with_capability(@ai_capability), fn provider ->
      {provider.name, provider.key}
    end)
  end

  @doc """
  Returns the default base URL for a provider, read from the Integrations
  registry (`PhoenixKit.Integrations.Providers.base_url/1`).

  All `:ai_completions` providers expose an OpenAI-compatible chat
  completions endpoint at `<base>/chat/completions`, so the same Completion
  HTTP layer works for them. Returns `nil` when the registry has no base URL
  for the key (e.g. a legacy integration-uuid provider value) — the operator
  can still set `base_url` manually on the endpoint.
  """
  @spec default_base_url(String.t()) :: String.t() | nil
  def default_base_url(provider) when is_binary(provider), do: Providers.base_url(provider)
  def default_base_url(_), do: nil

  @doc """
  Masks the API key for display.

  - `nil` or `""` → `"Not set"`.
  - Keys shorter than 14 chars → `"•••"` (a 13-char key would otherwise
    leak most of itself with the head+tail shape).
  - Longer keys → first 8 + `…` + last 4 (e.g. `"sk-or-v1…mnop"`).
    Recognisable provider prefix retained, identifying suffix retained,
    middle elided. Useful for human-recognition in admin cards while
    still hiding the bulk of the secret.
  """
  @spec masked_api_key(String.t() | nil) :: String.t()
  def masked_api_key(nil), do: "Not set"
  def masked_api_key(""), do: "Not set"

  def masked_api_key(api_key) when is_binary(api_key) do
    if String.length(api_key) < 14 do
      "•••"
    else
      head = String.slice(api_key, 0, 8)
      tail = String.slice(api_key, -4..-1)
      head <> "…" <> tail
    end
  end

  def masked_api_key(_), do: "Not set"

  @doc """
  Returns a display label for the provider, read from the Integrations
  registry (the provider's `name`).

  Unknown providers — e.g. a legacy integration uuid stored in the column —
  fall back to the raw string. Brand names stay effectively un-translated:
  registry names are gettext strings, but product trademarks like
  `"OpenRouter"` / `"Mistral"` have no translations, so gettext returns them
  verbatim rather than producing mixed `"OpenRouter Соединение"` strings.
  """
  @spec provider_label(String.t()) :: String.t()
  def provider_label(provider) when is_binary(provider) do
    case Providers.get(provider) do
      %{name: name} -> name
      _ -> provider
    end
  end

  def provider_label(provider), do: provider

  @doc """
  Whether `provider` supports xAI's realtime streaming voice API
  (`PhoenixKitAI.Realtime.Session`, WebSocket-based) — gates the
  Playground's streaming voice panel to capable endpoints.
  """
  @spec realtime_voice_capable?(String.t() | nil) :: boolean()
  def realtime_voice_capable?(provider) when is_binary(provider) do
    case Providers.get(provider) do
      %{capabilities: capabilities} -> :realtime_voice in capabilities
      _ -> false
    end
  end

  def realtime_voice_capable?(_provider), do: false

  @doc """
  Whether picking "Text-to-Speech" in the Endpoint form's model-type
  filter could plausibly return models to choose from for `provider`.

  False only for xAI: it has real TTS (`PhoenixKitAI.speak/3` works via
  `POST /v1/tts` regardless of what model type the endpoint stores —
  see `Completion.text_to_speech/3`) but it isn't model-based at all —
  no model id, nothing in `GET /models` — so the picker would always
  come back empty. True for every other provider, including ones with
  no TTS at all (an empty list there is accurate, not a dead end to
  hide).
  """
  @spec tts_model_picker?(String.t() | nil) :: boolean()
  def tts_model_picker?(provider) when is_binary(provider) do
    base_provider(provider) != "xai"
  end

  def tts_model_picker?(_provider), do: true

  @doc """
  Whether picking "Image generation" in the Endpoint form's model-type
  filter could plausibly return models to choose from for `provider`.

  Unlike `tts_model_picker?/1`, this reuses the Integrations registry's
  `:image_generation` capability directly rather than a hardcoded
  provider check — OpenAI, OpenRouter, and xAI all genuinely support
  image generation at the same `/images/generations` path
  (`PhoenixKitAI.Completion.generate_image/3`), so there's no single
  provider to special-case; Mistral/DeepSeek correctly show an empty
  list here since they have no image-gen models at all.
  """
  @spec image_gen_model_picker?(String.t() | nil) :: boolean()
  def image_gen_model_picker?(provider) when is_binary(provider) do
    case Providers.get(provider) do
      %{capabilities: capabilities} -> :image_generation in capabilities
      _ -> false
    end
  end

  def image_gen_model_picker?(_provider), do: false

  @doc """
  Strips a named connection suffix from a provider string.

  The `provider` column may hold the bare key (`"xai"`) or a named
  connection string (`"xai:my-key"`, legacy / pre-V107 rows) — this
  extracts the base key so callers can compare against it directly
  instead of using `String.starts_with?/2`, which would also match
  unrelated providers sharing the same prefix.
  """
  @spec base_provider(String.t()) :: String.t()
  def base_provider(provider) do
    provider |> String.split(":", parts: 2) |> List.first()
  end

  @doc """
  Checks if the endpoint has been validated recently (within the last 24 hours).
  """
  def recently_validated?(%__MODULE__{last_validated_at: nil}), do: false

  def recently_validated?(%__MODULE__{last_validated_at: validated_at}) do
    case DateTime.diff(UtilsDate.utc_now(), validated_at, :hour) do
      hours when hours < 24 -> true
      _ -> false
    end
  end

  @doc """
  Extracts the model name without the provider prefix.
  """
  def short_model_name(nil), do: nil
  def short_model_name(""), do: nil

  def short_model_name(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end

  @doc """
  Classifies an endpoint by the kind of model it points at.

  Endpoints don't store a model type, so this infers it from the model
  id using the same heuristic the model picker uses (see
  `PhoenixKitAI.OpenRouterClient` `:tts`/`:image_gen` filters): a `tts`
  substring marks text-to-speech, `embed` marks an embedding model,
  `dall-e`/`image` marks image generation (`gpt-image-1`,
  `grok-imagine-image[-quality]`, `google/gemini-2.5-flash-image`, ...),
  and everything else is treated as chat/completion. Used to badge rows
  in the admin UI.
  """
  @spec kind(t() | String.t() | nil) :: :chat | :tts | :embedding | :image_gen
  def kind(%__MODULE__{model: model}), do: kind(model)

  def kind(model) when is_binary(model) do
    downcased = String.downcase(model)

    cond do
      String.contains?(downcased, "tts") -> :tts
      String.contains?(downcased, "embed") -> :embedding
      String.contains?(downcased, "dall-e") or String.contains?(downcased, "image") -> :image_gen
      true -> :chat
    end
  end

  def kind(_), do: :chat

  @doc """
  Heroicon name representing an endpoint `kind/1`.
  """
  @spec kind_icon(:chat | :tts | :embedding | :image_gen) :: String.t()
  def kind_icon(:tts), do: "hero-speaker-wave"
  def kind_icon(:embedding), do: "hero-rectangle-stack"
  def kind_icon(:image_gen), do: "hero-photo"
  def kind_icon(:chat), do: "hero-chat-bubble-left-right"

  @doc """
  Returns image size options for form selects.
  """
  def image_size_options do
    [
      {"1024x1024 (Square)", "1024x1024"},
      {"1792x1024 (Landscape)", "1792x1024"},
      {"1024x1792 (Portrait)", "1024x1792"}
    ]
  end

  @doc """
  Returns image quality options for form selects.
  """
  def image_quality_options do
    [
      {"Standard", "standard"},
      {"HD", "hd"}
    ]
  end

  @doc """
  Returns xAI image aspect-ratio options for form selects.

  Stored in `provider_settings["aspect_ratio"]` and applied by
  `PhoenixKitAI.generate_image/3` when the endpoint's provider is xAI.
  """
  def image_aspect_ratio_options do
    [
      {"1:1 (Square)", "1:1"},
      {"16:9 (Landscape)", "16:9"},
      {"9:16 (Portrait)", "9:16"},
      {"4:3", "4:3"},
      {"3:4", "3:4"},
      {"3:2", "3:2"},
      {"2:3", "2:3"}
    ]
  end

  @doc """
  Returns xAI image resolution options for form selects.

  Stored in `provider_settings["resolution"]` and applied by
  `PhoenixKitAI.generate_image/3` when the endpoint's provider is xAI.
  """
  def image_resolution_options do
    [
      {"1k", "1k"},
      {"2k", "2k"}
    ]
  end

  @doc """
  Returns reasoning effort options for form selects.
  """
  def reasoning_effort_options do
    [
      {"None (disabled)", "none"},
      {"Minimal (~10%)", "minimal"},
      {"Low (~20%)", "low"},
      {"Medium (~50%)", "medium"},
      {"High (~80%)", "high"},
      {"Extra High (~95%)", "xhigh"}
    ]
  end

  # Private functions

  defp validate_temperature(changeset) do
    case get_field(changeset, :temperature) do
      nil -> changeset
      temp when temp >= 0 and temp <= 2 -> changeset
      _ -> add_error(changeset, :temperature, "must be between 0 and 2")
    end
  end

  defp validate_penalties(changeset) do
    changeset
    |> validate_penalty(:frequency_penalty, -2, 2)
    |> validate_penalty(:presence_penalty, -2, 2)
    |> validate_penalty(:repetition_penalty, 0, 2)
    |> validate_penalty(:top_p, 0, 1)
  end

  defp validate_penalty(changeset, field, min, max) do
    case get_field(changeset, field) do
      nil -> changeset
      val when val >= min and val <= max -> changeset
      _ -> add_error(changeset, field, "must be between #{min} and #{max}")
    end
  end

  @valid_reasoning_efforts ~w(none minimal low medium high xhigh)

  defp validate_reasoning(changeset) do
    changeset
    |> validate_reasoning_effort()
    |> validate_reasoning_max_tokens()
  end

  defp validate_reasoning_effort(changeset) do
    case get_field(changeset, :reasoning_effort) do
      nil ->
        changeset

      "" ->
        changeset

      effort when effort in @valid_reasoning_efforts ->
        changeset

      _ ->
        add_error(
          changeset,
          :reasoning_effort,
          "must be one of: #{Enum.join(@valid_reasoning_efforts, ", ")}"
        )
    end
  end

  defp validate_reasoning_max_tokens(changeset) do
    case get_field(changeset, :reasoning_max_tokens) do
      nil ->
        changeset

      tokens when is_integer(tokens) and tokens >= 1024 and tokens <= 32_000 ->
        changeset

      tokens when is_integer(tokens) ->
        add_error(changeset, :reasoning_max_tokens, "must be between 1024 and 32,000")

      _ ->
        changeset
    end
  end

  defp maybe_set_default_base_url(changeset) do
    provider = get_field(changeset, :provider)
    base_url = get_field(changeset, :base_url)

    if is_nil(base_url) or base_url == "" do
      put_change(changeset, :base_url, default_base_url(provider))
    else
      changeset
    end
  end

  # SSRF guard. `base_url` is user-supplied via the form, so without
  # validation an admin could create an endpoint pointing at AWS
  # cloud-metadata (`169.254.169.254`), corporate intranet ranges, or
  # the local loopback and have the server fetch on their behalf via
  # `Completion.build_url/2` → `Req.post/2`. We default to a strict
  # public-only allowlist; deployments that need self-hosted /
  # localhost endpoints (Ollama, intranet inference servers) opt in
  # explicitly via `config :phoenix_kit_ai, allow_internal_endpoint_urls: true`.
  defp validate_base_url(changeset) do
    case get_field(changeset, :base_url) do
      nil -> changeset
      "" -> changeset
      url when is_binary(url) -> validate_base_url_string(changeset, url)
      _ -> add_error(changeset, :base_url, "must be a string")
    end
  end

  defp validate_base_url_string(changeset, url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        add_error(changeset, :base_url, "must use http or https scheme")

      is_nil(uri.host) or uri.host == "" ->
        add_error(changeset, :base_url, "must include a hostname")

      Application.get_env(:phoenix_kit_ai, :allow_internal_endpoint_urls, false) ->
        changeset

      String.ends_with?(uri.host, ".local") ->
        add_error(
          changeset,
          :base_url,
          "cannot point at .local mDNS hostnames (set allow_internal_endpoint_urls if you need this)"
        )

      uri.host == "localhost" ->
        add_error(
          changeset,
          :base_url,
          "cannot point at localhost (set allow_internal_endpoint_urls if you need this)"
        )

      internal_host?(uri.host) ->
        add_error(
          changeset,
          :base_url,
          "cannot point at private/loopback/link-local addresses (set allow_internal_endpoint_urls if you need this)"
        )

      true ->
        changeset
    end
  end

  # Returns true for any hostname that resolves to an RFC1918, loopback,
  # link-local, or unspecified IP literal. Hostnames that aren't IP
  # literals fall through to `false` — DNS-rebinding attacks aren't
  # mitigated here (would require resolution at request time, which is
  # racy). The acute threat we're guarding is the literal IP shape
  # (cloud-metadata is always `169.254.169.254` literal).
  #
  # Strips a single trailing dot (FQDN form): `127.0.0.1.` is the same
  # loopback host to the OS resolver, so it must not bypass the guard.
  defp internal_host?(host) when is_binary(host) do
    normalized = String.trim_trailing(host, ".")

    case :inet.parse_address(to_charlist(normalized)) do
      {:ok, ip} -> internal_ip?(ip)
      _ -> false
    end
  end

  # IPv4 ranges
  defp internal_ip?({0, _, _, _}), do: true
  defp internal_ip?({10, _, _, _}), do: true
  defp internal_ip?({127, _, _, _}), do: true
  defp internal_ip?({169, 254, _, _}), do: true
  defp internal_ip?({172, b, _, _}) when b in 16..31, do: true
  defp internal_ip?({192, 168, _, _}), do: true
  # CGNAT / shared address space (RFC 6598). Used by ISPs and on-prem
  # Kubernetes pod networks; not internet-routable.
  defp internal_ip?({100, b, _, _}) when b in 64..127, do: true
  # IPv6 — loopback `::1`, unspecified `::`, link-local `fe80::/10`,
  # unique-local `fc00::/7`.
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  # IPv4-mapped IPv6 (`::ffff:a.b.c.d`). Without this clause an attacker
  # could wrap any IPv4 restriction — `::ffff:127.0.0.1` and
  # `::ffff:169.254.169.254` were both bypasses before. Recurse against
  # the embedded IPv4 to keep the guard list authoritative.
  defp internal_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    a = div(hi, 256)
    b = rem(hi, 256)
    c = div(lo, 256)
    d = rem(lo, 256)
    internal_ip?({a, b, c, d})
  end

  defp internal_ip?(_), do: false
end
