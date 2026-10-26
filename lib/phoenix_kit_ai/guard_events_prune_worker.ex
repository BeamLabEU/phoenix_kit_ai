defmodule PhoenixKitAI.GuardEventsPruneWorker do
  @moduledoc """
  The old daily pruning of the guard's events, kept as a shim: it deletes
  nothing and only queues `PhoenixKitAI.JournalPruneWorker`, whose
  uniqueness and once-a-night rule keep a host that has both in its
  crontab, or a job of this worker already queued, from running the
  cleanup twice. The guard's events are no longer deleted after a fixed
  180 days: they follow the period set for them (`PhoenixKitAI.Retention`,
  kept forever by default). No longer in the module's `oban_crons/0`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  @doc """
  The fixed period this worker used to apply, in days.

  Deprecated: the guard's events follow `PhoenixKitAI.Retention` now.
  """
  @deprecated "The guard's events follow PhoenixKitAI.Retention"
  @spec retention_days() :: pos_integer()
  def retention_days, do: 180

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with {:ok, _job} <- %{} |> PhoenixKitAI.JournalPruneWorker.new() |> Oban.insert(), do: :ok
  end
end
