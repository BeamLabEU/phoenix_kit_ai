defmodule PhoenixKitAI.RetentionClientTimeoutTest do
  @moduledoc """
  A statement of the cleanup ends by the database's timeout, never the
  client's: the client waits longer than the statement may run.

  A table lock held from another connection keeps the preview's count
  waiting; the repo the count runs on has a client timeout (1 s) shorter
  than the count's statement timeout. The answer must come at the
  statement timeout. Runs on its own unsandboxed repo instance, which only
  reads.

  `async: false`: the lock is on a shared table.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Retention
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  test "a count held by a lock ends in the database's timeout, not the client's" do
    config = TestRepo.config()

    {:ok, locker} =
      Postgrex.start_link(
        Keyword.take(config, [:hostname, :port, :username, :password, :database])
      )

    {:ok, repo} =
      TestRepo.start_link(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        timeout: 1_000
      )

    floor = Retention.floor(:requests)

    {micros, result} =
      try do
        Postgrex.query!(locker, "BEGIN", [])
        Postgrex.query!(locker, "LOCK TABLE phoenix_kit_ai_requests IN ACCESS EXCLUSIVE MODE", [])
        TestRepo.put_dynamic_repo(repo)
        :timer.tc(fn -> Retention.preview_counts(%{requests: floor}, timeout_ms: 2_500) end)
      after
        TestRepo.put_dynamic_repo(TestRepo)
        Postgrex.query!(locker, "ROLLBACK", [])
        GenServer.stop(locker)
        Supervisor.stop(repo)
      end

    assert result == {:error, :preview_timeout}
    assert div(micros, 1000) >= 2_400, "ended after #{div(micros, 1000)} ms: the client's timeout"
  end
end
