defmodule PhoenixKitAI.RetentionClientTimeoutTest do
  @moduledoc """
  A statement of the cleanup ends by the database's timeout, never the
  client's: the client waits longer than the statement may run.

  A table lock held from another connection keeps the preview's count
  waiting; the repo the count runs on has a client timeout (1 s) shorter
  than the count's statement timeout. The answer must come at the
  statement timeout. Runs on its own unsandboxed repo instance, which only
  reads. Saving the periods likewise ends at its own lock timeout when
  another connection holds the setting's row.

  `async: false`: the lock is on a shared table.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
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

  # The periods' row, committed from another connection and held there
  # under FOR UPDATE: a save waits for it, up to its lock timeout, and then
  # answers busy instead of overwriting. The row is removed before and after.
  test "a save meeting the periods' row locked elsewhere waits, then answers busy" do
    {:ok, locker} = Postgrex.start_link(connection_options())

    owner = Scope.for_user(Fixtures.user_fixture())
    key = clean_committed_row!()

    {micros, result} =
      try do
        Postgrex.query!(
          locker,
          "INSERT INTO phoenix_kit_settings (key, value_json, module) VALUES ($1, $2, 'ai')",
          [key, %{"content" => "forever", "requests" => "forever", "guard_events" => "forever"}]
        )

        Postgrex.query!(locker, "BEGIN", [])

        Postgrex.query!(locker, "SELECT 1 FROM phoenix_kit_settings WHERE key = $1 FOR UPDATE", [
          key
        ])

        :timer.tc(fn ->
          Retention.put_settings(owner, %{content: {30, :day}}, Retention.settings())
        end)
      after
        Postgrex.query!(locker, "ROLLBACK", [])
        GenServer.stop(locker)
      end

    assert result == {:error, :retention_busy}
    ms = div(micros, 1000)
    # the save's own lock timeout (5 s), not the client's (15 s)
    assert ms >= 4_500, "ended after #{ms} ms: it did not wait"
    assert ms < 9_000, "ended after #{ms} ms: not the lock timeout"
  end

  describe "a save waiting for the periods' row" do
    # Another writer holds the row and changes the rows' period meanwhile.
    # The save locks the row before it reads it, so it reads the other
    # writer's period once that commits: nothing of it is lost, and a save
    # of the same kind is stale. The save runs on its own unsandboxed repo
    # instance (its write is committed); the setting's row and the history
    # entries are removed before and after.

    test "a save of another kind keeps the other writer's change" do
      {result, stored} = save_while_another_writes(%{content: {30, :day}})

      assert {:ok, %{content: {30, :day}, requests: {12, :month}}} = result
      assert stored["content"] == %{"n" => 30, "unit" => "day"}
      assert stored["requests"] == %{"n" => 12, "unit" => "month"}
    end

    test "a save of the same kind is stale" do
      {result, stored} = save_while_another_writes(%{requests: {3, :month}})

      assert result == {:error, :stale_retention}
      assert stored["requests"] == %{"n" => 12, "unit" => "month"}
    end
  end

  defp save_while_another_writes(attrs) do
    {:ok, locker} = Postgrex.start_link(connection_options())

    {:ok, repo} =
      TestRepo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 2)

    owner = Scope.for_user(Fixtures.user_fixture())
    # the user is only in this test's sandbox: no actor on the committed write
    scope = %{owner | user: %{owner.user | uuid: nil}}
    key = clean_committed_row!()
    forever = %{"content" => "forever", "requests" => "forever", "guard_events" => "forever"}

    other =
      Map.merge(forever, %{
        "requests" => %{"n" => 12, "unit" => "month"},
        "changed_at" => %{"requests" => DateTime.to_iso8601(DateTime.utc_now())}
      })

    try do
      Postgrex.query!(
        locker,
        "INSERT INTO phoenix_kit_settings (key, value_json, module) VALUES ($1, $2, 'ai')",
        [key, forever]
      )

      loaded = Retention.settings()
      Postgrex.query!(locker, "BEGIN", [])

      Postgrex.query!(locker, "SELECT 1 FROM phoenix_kit_settings WHERE key = $1 FOR UPDATE", [
        key
      ])

      task =
        Task.async(fn ->
          TestRepo.put_dynamic_repo(repo)
          Retention.put_settings(scope, attrs, loaded)
        end)

      await_lock_wait(locker, 100)

      Postgrex.query!(locker, "UPDATE phoenix_kit_settings SET value_json = $2 WHERE key = $1", [
        key,
        other
      ])

      Postgrex.query!(locker, "COMMIT", [])
      result = Task.await(task, 20_000)

      %{rows: [[stored]]} =
        Postgrex.query!(locker, "SELECT value_json FROM phoenix_kit_settings WHERE key = $1", [
          key
        ])

      {result, stored}
    after
      Postgrex.query!(locker, "ROLLBACK", [])
      GenServer.stop(locker)
      Supervisor.stop(repo)
    end
  end

  # The periods' row these tests commit, and the history entries of its
  # committed saves: removed before each test (a run killed midway leaves
  # them behind, and every later run of this and other modules would read
  # them) and after it, in on_exit, from a connection of its own, each
  # statement on its own so one failing does not keep the next from running.
  defp clean_committed_row! do
    key = Retention.setting_key()
    remove_committed(key)
    on_exit(fn -> remove_committed(key) end)
    key
  end

  defp remove_committed(key) do
    {:ok, conn} = Postgrex.start_link(connection_options())

    for {sql, params} <- [
          {"SET lock_timeout = 5000", []},
          {"DELETE FROM phoenix_kit_settings WHERE key = $1", [key]},
          {"DELETE FROM phoenix_kit_activities WHERE action = 'setting.changed' AND metadata->>'key' = $1",
           [key]}
        ] do
      try do
        Postgrex.query!(conn, sql, params)
      rescue
        error -> IO.warn("cleanup of #{key} failed: #{inspect(error.__struct__)} in #{sql}")
      end
    end

    GenServer.stop(conn)
  end

  defp connection_options,
    do: Keyword.take(TestRepo.config(), [:hostname, :port, :username, :password, :database])

  # Until a statement of this database waits for a lock (the save, on the
  # row the locker holds), polling every 20 ms.
  defp await_lock_wait(_locker, 0), do: flunk("the save never waited for the row")

  defp await_lock_wait(locker, tries) do
    %{rows: [[waiting]]} =
      Postgrex.query!(
        locker,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'",
        []
      )

    if waiting > 0 do
      :ok
    else
      Process.sleep(20)
      await_lock_wait(locker, tries - 1)
    end
  end
end
