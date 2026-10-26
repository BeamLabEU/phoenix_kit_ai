defmodule PhoenixKitAI.Tasks.Builder do
  @moduledoc """
  The one writer of the AI task registry (`PhoenixKitAI.Tasks`). Reads are a
  lock-free `:persistent_term` hit; a caller that finds the registry missing,
  stale or due for a retry asks this process, which works out the current
  module and provider lists itself and builds only when the cache does not
  already fit them. Builds are therefore serial and always for the current
  config. Each module's `ai_tasks/0` runs in its own unlinked process with
  a timeout (`:task_registry_callback_timeout_ms`), so a hanging or crashing
  one cannot stall or kill it. Without this process no lookup caches.
  Started by `PhoenixKitAI.children/0`.
  """

  use GenServer

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call(:ensure, _from, state) do
    {:reply, PhoenixKitAI.Tasks.ensure_built(), state}
  end
end
