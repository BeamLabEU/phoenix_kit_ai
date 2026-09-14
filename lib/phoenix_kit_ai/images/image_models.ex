defmodule PhoenixKitAI.Images.ImageModels do
  @moduledoc """
  A provider's image models and what each accepts, cached per base URL.

  Backed by the endpoint's `PhoenixKitAI.Provider` adapter. Providers
  that publish no listing (xAI, plain OpenAI-compatible APIs) yield
  `{:error, :not_supported}`; callers then fall back to the adapter's
  static `image_options/1`.

  The cache is a `:persistent_term` per `{adapter, base_url, account}`
  (the endpoint's integration, so two accounts on one gateway never share
  a listing) with a 30-minute lifetime — the listing changes rarely and
  every image request would otherwise pay a round trip for it.
  `refresh: true` bypasses it.
  """

  alias PhoenixKitAI.{Completion, Provider}
  alias PhoenixKitAI.Images.ImageModel

  @ttl_ms :timer.minutes(30)

  @doc "All image models the endpoint's provider offers."
  @spec list(PhoenixKitAI.Endpoint.t(), keyword()) :: {:ok, [ImageModel.t()]} | {:error, term()}
  def list(endpoint, opts \\ []) do
    adapter = Provider.for_endpoint(endpoint)
    key = {__MODULE__, adapter, base_url(endpoint), account(endpoint)}
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
  def get(endpoint, model_id) do
    case lookup(endpoint, model_id) do
      {:ok, model} -> model
      {:error, _} -> nil
    end
  end

  @doc """
  One model by id, saying why when there is none: `:not_supported` (the
  provider publishes no listing), `:not_listed` (a listing exists and
  the model is not in it) or `{:unavailable, reason}` (the listing could
  not be fetched right now).
  """
  @spec lookup(PhoenixKitAI.Endpoint.t(), String.t() | nil) ::
          {:ok, ImageModel.t()} | {:error, :not_supported | :not_listed | {:unavailable, term()}}
  def lookup(_endpoint, nil), do: {:error, :not_listed}

  def lookup(endpoint, model_id) when is_binary(model_id) do
    case list(endpoint) do
      {:ok, models} ->
        case Enum.find(models, &(&1.id == model_id)) do
          nil -> {:error, :not_listed}
          model -> {:ok, model}
        end

      {:error, :not_supported} ->
        {:error, :not_supported}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  @doc "Drops every cached listing (tests, or after a provider change)."
  @spec clear() :: :ok
  def clear do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, _, _, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  # The listing belongs to an account: the pinned integration, or the
  # legacy key on the row, or the endpoint itself when neither is set.
  defp account(endpoint) do
    cond do
      is_binary(endpoint.integration_uuid) -> endpoint.integration_uuid
      is_binary(endpoint.api_key) and endpoint.api_key != "" -> :erlang.phash2(endpoint.api_key)
      true -> endpoint.uuid
    end
  end

  defp base_url(endpoint) do
    Completion.url(endpoint, "")
  rescue
    ArgumentError -> endpoint.provider
  end
end
