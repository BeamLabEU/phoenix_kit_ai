defmodule PhoenixKitAI.Translatables do
  @moduledoc """
  Discovery for AI-translatable adapters.

  A feature module opts a resource into AI translation by exporting
  `ai_translatables/0` returning `[{resource_type, adapter_module}]`, where
  `adapter_module` implements `PhoenixKitAI.Translatable`. This scans every
  module known to `PhoenixKit.ModuleRegistry` for that function (duck-typed —
  the function is **not** a `PhoenixKit.Module` callback, so feature modules
  declare AI-translatability without core knowing anything about AI).

  A host application that is not a kit module joins the same pipeline
  through config:

      config :phoenix_kit_ai, translatables: [{"product", MyApp.AI.ProductTranslatable}]

  `resource_type` strings must be globally unique; on a collision the first
  registered module wins — configured entries come first, so a host can
  also override a module's adapter for a type.
  """

  require Logger

  @doc """
  `%{resource_type => adapter_module}` for every registered module that
  exports `ai_translatables/0`.
  """
  @spec all() :: %{String.t() => module()}
  def all do
    configured = configured()
    overrides = MapSet.new(configured, fn {type, _adapter} -> type end)
    discovered = Enum.flat_map(PhoenixKit.ModuleRegistry.all_modules(), &safe_translatables/1)

    Enum.reduce(configured ++ discovered, %{}, fn
      {type, adapter}, acc when is_binary(type) and is_atom(adapter) ->
        put_adapter(acc, type, adapter, overrides)

      _other, acc ->
        acc
    end)
  end

  # First registration wins. A host entry shadowing a module's adapter is
  # the documented override, not a mistake — no warning for it.
  defp put_adapter(acc, type, adapter, overrides) do
    case acc do
      %{^type => existing} when existing != adapter ->
        unless MapSet.member?(overrides, type) do
          Logger.warning(
            "[PhoenixKitAI] duplicate ai_translatable resource_type #{inspect(type)}: " <>
              "keeping #{inspect(existing)}, ignoring #{inspect(adapter)}"
          )
        end

        acc

      _ ->
        Map.put(acc, type, adapter)
    end
  end

  @doc "Resolve the adapter for a `resource_type`, or `nil`."
  @spec find(String.t()) :: module() | nil
  def find(resource_type) when is_binary(resource_type) do
    Map.get(all(), resource_type)
  end

  # `config :phoenix_kit_ai, translatables: [{type, module}]` — a host app's
  # own schemas, which have no module to export `ai_translatables/0` from.
  defp configured do
    case Application.get_env(:phoenix_kit_ai, :translatables, []) do
      list when is_list(list) ->
        Enum.filter(list, &valid_entry?/1)

      other ->
        Logger.warning(
          "[PhoenixKitAI] :translatables must be a list of {type, module}, got #{inspect(other)}"
        )

        []
    end
  end

  # Kept even when the module is missing — a host module may not be loaded
  # yet at boot — but a typo should not wait for the first translation job.
  defp valid_entry?({type, adapter}) when is_binary(type) and is_atom(adapter) do
    unless Code.ensure_loaded?(adapter) and function_exported?(adapter, :fetch, 2) do
      Logger.warning(
        "[PhoenixKitAI] :translatables entry #{inspect(type)}: #{inspect(adapter)} " <>
          "is not loaded or has no fetch/2 (implement PhoenixKitAI.Translatable)"
      )
    end

    true
  end

  defp valid_entry?(other) do
    Logger.warning(
      "[PhoenixKitAI] ignoring :translatables entry #{inspect(other)} (want {type, module})"
    )

    false
  end

  # function_exported? is false for not-yet-loaded modules; ensure_loaded first.
  defp safe_translatables(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :ai_translatables, 0) do
      case mod.ai_translatables() do
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end
end
