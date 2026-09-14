defmodule PhoenixKitAI.Provider do
  @moduledoc """
  The seam between the public image API and one provider's HTTP shape.

  Consumers never see a provider: they call `PhoenixKitAI.process_image/4`,
  `PhoenixKitAI.edit_image/4` or `PhoenixKitAI.generate_image/3` with an
  endpoint, and the endpoint's provider picks the adapter. Switching a
  module from OpenRouter to xAI, OpenAI or a provider added later is a
  change of endpoint, not of code.

  An adapter implements this behaviour and is selected by the endpoint's
  base provider key (`PhoenixKitAI.Endpoint.base_provider/1`):

  | provider key | adapter |
  |---|---|
  | `"openrouter"` | `PhoenixKitAI.Providers.OpenRouter` — the unified Images API |
  | `"xai"` | `PhoenixKitAI.Providers.XAI` — JSON `/images/edits` |
  | `"openai"` | `PhoenixKitAI.Providers.OpenAI` — multipart `/images/edits` |
  | anything else | `PhoenixKitAI.Providers.OpenAICompatible` — chat completions with image parts |

  A host adds or replaces adapters without touching this module:

      config :phoenix_kit_ai, provider_adapters: %{"fal" => MyApp.FalAdapter}

  The key is the Integrations provider key the endpoint carries; the
  value is a module implementing this behaviour.

  ## Contract

  Every adapter receives already-normalised inputs: reference images as
  data URLs (bytes inlined) or http(s) URLs, and options as a map with
  the canonical keys from `PhoenixKitAI.Images` (`:aspect_ratio`,
  `:resolution`, `:size`, `:quality`, `:background`, `:output_format`,
  `:output_compression`, `:n`, `:seed`, `:response_format`), plus
  `:model` (an override of the endpoint's model), `:transport` (an
  adapter-specific hint) and `:provider_options` (a map passed through
  to the provider untouched). It returns the uniform image result or one
  of the module's error atoms/tuples.
  """

  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Images.ImageModel

  @type image :: %{
          data: binary() | nil,
          url: String.t() | nil,
          content_type: String.t() | nil
        }

  @type image_result :: %{
          images: [image()],
          text: String.t() | nil,
          usage: map(),
          latency_ms: non_neg_integer(),
          model: String.t() | nil
        }

  @type options :: %{optional(atom()) => term()}

  @doc "Image-in, image-out: edit `refs` (first = the image to change) per `prompt`."
  @callback image_edit(Endpoint.t(), String.t(), [String.t()], options()) ::
              {:ok, image_result()} | {:error, term()}

  @doc "Text-to-image."
  @callback image_generate(Endpoint.t(), String.t(), options()) ::
              {:ok, image_result()} | {:error, term()}

  @doc "The provider's image models with their constraints, when it publishes them."
  @callback image_models(Endpoint.t()) :: {:ok, [ImageModel.t()]} | {:error, term()}

  @doc "Option names the adapter can send when no per-model listing exists."
  @callback image_options(Endpoint.t()) :: [atom()]

  @builtin %{
    "openrouter" => PhoenixKitAI.Providers.OpenRouter,
    "xai" => PhoenixKitAI.Providers.XAI,
    "openai" => PhoenixKitAI.Providers.OpenAI
  }

  @default PhoenixKitAI.Providers.OpenAICompatible

  @doc "Provider key → adapter module, built-ins under the host's `:provider_adapters`."
  @spec adapters() :: %{String.t() => module()}
  def adapters, do: Map.merge(@builtin, configured())

  @doc "The adapter for an endpoint's provider (the default one when unknown)."
  @spec for_endpoint(Endpoint.t() | map()) :: module()
  def for_endpoint(%{provider: provider}) when is_binary(provider) and provider != "",
    do: for_provider(Endpoint.base_provider(provider))

  def for_endpoint(_endpoint), do: @default

  @doc "The adapter for a provider key."
  @spec for_provider(String.t()) :: module()
  def for_provider(key) when is_binary(key), do: Map.get(adapters(), key, @default)

  @doc "The adapter used when a provider has no dedicated one."
  @spec default() :: module()
  def default, do: @default

  defp configured do
    case Application.get_env(:phoenix_kit_ai, :provider_adapters, %{}) do
      map when is_map(map) ->
        Map.new(map, fn {key, module} -> {to_string(key), module} end)

      other ->
        require Logger

        Logger.warning(
          "[PhoenixKitAI] :provider_adapters must be a map of provider key => module, got #{inspect(other)}; ignoring"
        )

        %{}
    end
  end
end
