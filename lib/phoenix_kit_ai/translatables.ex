defmodule PhoenixKitAI.Translatables do
  @moduledoc """
  Discovery for AI-translatable adapters.

  A feature module opts a resource into AI translation by exporting
  `ai_translatables/0` returning `[{resource_type, adapter_module}]`, where
  `adapter_module` implements `PhoenixKitAI.Translatable`. This scans every
  module known to `PhoenixKit.ModuleRegistry` for that function (duck-typed —
  the function is **not** a `PhoenixKit.Module` callback, so feature modules
  declare AI-translatability without core knowing anything about AI).

  `resource_type` strings must be globally unique; on a collision the first
  registered module wins.
  """

  require Logger

  @doc """
  `%{resource_type => adapter_module}` for every registered module that
  exports `ai_translatables/0`.
  """
  @spec all() :: %{String.t() => module()}
  def all do
    PhoenixKit.ModuleRegistry.all_modules()
    |> Enum.flat_map(&safe_translatables/1)
    |> Enum.reduce(%{}, fn
      {type, adapter}, acc when is_binary(type) and is_atom(adapter) ->
        case acc do
          %{^type => existing} when existing != adapter ->
            Logger.warning(
              "[PhoenixKitAI] duplicate ai_translatable resource_type #{inspect(type)}: " <>
                "keeping #{inspect(existing)}, ignoring #{inspect(adapter)}"
            )

            acc

          _ ->
            Map.put(acc, type, adapter)
        end

      _other, acc ->
        acc
    end)
  end

  @doc "Resolve the adapter for a `resource_type`, or `nil`."
  @spec find(String.t()) :: module() | nil
  def find(resource_type) when is_binary(resource_type) do
    Map.get(all(), resource_type)
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
