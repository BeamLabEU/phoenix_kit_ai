defmodule PhoenixKitAI.Images.ImageModels do
  @moduledoc """
  A provider's image models and what each accepts, cached per base URL.

  Backed by the endpoint's `PhoenixKitAI.Provider` adapter. Providers
  that publish no listing (xAI, plain OpenAI-compatible APIs) yield
  `{:error, :not_supported}`; callers then fall back to the adapter's
  static `image_options/1`.

  The cache is a `:persistent_term` per `{adapter, base_url}` with a
  30-minute lifetime — the listing changes rarely and every image request
  would otherwise pay a round trip for it. `refresh: true` bypasses it.
  """

  alias PhoenixKitAI.{Completion, Provider}
  alias PhoenixKitAI.Images.ImageModel

  @ttl_ms :timer.minutes(30)

  @doc "All image models the endpoint's provider offers."
  @spec list(PhoenixKitAI.Endpoint.t(), keyword()) :: {:ok, [ImageModel.t()]} | {:error, term()}
  def list(endpoint, opts \\ []) do
    adapter = Provider.for_endpoint(endpoint)
    key = {__MODULE__, adapter, base_url(endpoint)}
    now = System.monotonic_time(:millisecond)

    case {Keyword.get(opts, :refresh, false), :persistent_term.get(key, nil)} do
      {false, {fetched_at, models}} when now - fetched_at < @ttl_ms ->
        {:ok, models}

      _ ->
        case adapter.image_models(endpoint) do
          {:ok, models} ->
            :persistent_term.put(key, {now, models})
            {:ok, models}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc "One model by id, or nil (also nil when the provider has no listing)."
  @spec get(PhoenixKitAI.Endpoint.t(), String.t() | nil) :: ImageModel.t() | nil
  def get(_endpoint, nil), do: nil

  def get(endpoint, model_id) when is_binary(model_id) do
    case list(endpoint) do
      {:ok, models} -> Enum.find(models, &(&1.id == model_id))
      {:error, _} -> nil
    end
  end

  @doc "Drops every cached listing (tests, or after a provider change)."
  @spec clear() :: :ok
  def clear do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, _, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp base_url(endpoint) do
    Completion.url(endpoint, "")
  rescue
    ArgumentError -> endpoint.provider
  end
end
