defmodule PhoenixKitAI.GuardEventsPruneWorker do
  @moduledoc """
  Deletes the AI task guard's events (`phoenix_kit_ai_guard_events`) older
  than 180 days. Scheduled once a day by the module's `oban_crons/0`, which
  `mix phoenix_kit.install` / `mix phoenix_kit.update` write into the host's
  crontab; it runs in the core `default` queue, so the host lists no queue
  of its own. While the module is off it does nothing.

  A dedupe key of an event older than that is long past its window, so
  pruning never lets a signal go out twice.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAI.GuardEvent

  @retention_days 180

  @doc "How long an event is kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if PhoenixKitAI.enabled?() do
      cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 86_400)

      {deleted, _} =
        from(e in GuardEvent, where: e.inserted_at < ^cutoff)
        |> PhoenixKit.RepoHelper.repo().delete_all()

      {:ok, deleted}
    else
      {:ok, 0}
    end
  end
end
