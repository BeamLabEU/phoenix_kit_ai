defmodule PhoenixKitAI.RetentionDDLTest do
  @moduledoc """
  The parts of `PhoenixKitAI.Retention` a test can only reach with DDL: a
  foreign key from another table onto the journal (refused unless it is
  `SET NULL` on a nullable, indexed column), a chunk that fails or times
  out (the run stops, the counts done so far are recorded), the content
  step halving its chunk after a timeout, and an unreadable settings table.

  `async: false`: DDL locks the tables it touches until the test's
  transaction ends, and the sandbox rolls all of it back.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{GuardEvent, Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @fast [request_batch: 2, content_batch: 2, event_batch: 2, pause_ms: 0]

  setup do
    PhoenixKit.Settings.update_setting("time_zone", "0")
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp request!(at, model \\ "m") do
    TestRepo.insert!(%Request{
      model: model,
      request_type: "chat",
      status: "success",
      metadata: %{"messages" => [%{"content" => "x"}], "task" => "t"},
      inserted_at: at,
      updated_at: at
    })
  end

  defp min_cutoff(kind), do: kind |> Retention.floor() |> DateTime.truncate(:second)

  defp old(n), do: DateTime.add(min_cutoff(:requests), -n * 3600)

  defp sql!(statement), do: TestRepo.query!(statement, [])

  defp jobs,
    do: TestRepo.all(from(j in Oban.Job, where: j.worker == "PhoenixKitAI.JournalPruneWorker"))

  defp entries(action),
    do: TestRepo.all(from(e in PhoenixKit.Activity.Entry, where: e.action == ^action))

  describe "foreign keys onto the journal" do
    for {name, ddl} <- [
          restrict:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE RESTRICT); CREATE INDEX ON retention_fk_test (ref)",
          no_action:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid)); CREATE INDEX ON retention_fk_test (ref)",
          cascade:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE CASCADE); CREATE INDEX ON retention_fk_test (ref)",
          set_null_without_index:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE SET NULL)",
          set_null_on_not_null:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid NOT NULL REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE SET NULL); CREATE INDEX ON retention_fk_test (ref)",
          set_null_index_not_leading:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, other int, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE SET NULL); CREATE INDEX ON retention_fk_test (other, ref)",
          set_null_other_predicate:
            "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, other int, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE SET NULL); CREATE INDEX ON retention_fk_test (ref) WHERE other > 0"
        ] do
      test "#{name}: refused, nothing deleted" do
        row = request!(old(1))
        for statement <- String.split(unquote(ddl), "; "), do: sql!(statement)

        assert {:error, {:foreign_key_blocks, "retention_fk_test"}} =
                 Retention.check_foreign_keys([:requests])

        assert {:error, {:foreign_key_blocks, "retention_fk_test"}} =
                 Retention.preview(%{requests: min_cutoff(:requests)})

        assert {:cancel, {:foreign_key_blocks, "retention_fk_test"}} =
                 Retention.run(:manual, %{requests: min_cutoff(:requests)}, @fast)

        assert TestRepo.get(Request, row.uuid)
        assert %{manual: %{status: :failed, error: "foreign_key_blocks"}} = Retention.last_run()
      end
    end

    test "SET NULL on a nullable, indexed column: deleted, the reference emptied" do
      row = request!(old(1))

      sql!(
        "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE SET NULL)"
      )

      sql!("CREATE INDEX ON retention_fk_test (ref) WHERE ref IS NOT NULL")

      TestRepo.query!("INSERT INTO retention_fk_test VALUES (gen_random_uuid(), $1)", [
        Ecto.UUID.dump!(row.uuid)
      ])

      assert :ok = Retention.check_foreign_keys([:requests])

      assert {:ok, %{counts: %{requests: 1}}} =
               Retention.run(:manual, %{requests: min_cutoff(:requests)}, @fast)

      assert %{rows: [[nil]]} = sql!("SELECT ref FROM retention_fk_test")
    end

    test "a key onto the journal does not hold back a content-only run" do
      sql!(
        "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE RESTRICT)"
      )

      row = request!(old(1))

      assert {:ok, %{counts: %{content: 1}}} =
               Retention.run(:manual, %{content: min_cutoff(:content)}, @fast)

      assert TestRepo.get(Request, row.uuid)
    end

    test "the keys onto the guard events are checked too" do
      sql!(
        "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_guard_events(uuid) ON DELETE CASCADE)"
      )

      assert :ok = Retention.check_foreign_keys([:requests])

      assert {:error, {:foreign_key_blocks, "retention_fk_test"}} =
               Retention.check_foreign_keys([:guard_events])
    end

    test "the installed keys pass" do
      assert :ok = Retention.check_foreign_keys()
    end
  end

  describe "a chunk that fails" do
    setup do
      sql!("""
      CREATE FUNCTION retention_test_refuse() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.model = 'refuse' THEN RAISE EXCEPTION 'refused by the test'; END IF;
        RETURN OLD;
      END $$
      """)

      sql!(
        "CREATE TRIGGER retention_test_refuse BEFORE DELETE ON phoenix_kit_ai_requests FOR EACH ROW EXECUTE FUNCTION retention_test_refuse()"
      )

      :ok
    end

    test "stops the run: prune_failed and a failed stamp with the counts done so far" do
      for n <- 10..6//-1, do: request!(old(n))
      request!(old(1), "refuse")

      log =
        capture_log(fn ->
          assert {:error, {:prune_failed, "raise_exception"}} =
                   Retention.run(:manual, %{requests: min_cutoff(:requests)}, @fast)
        end)

      refute log =~ "refused by the test"

      # two chunks of two, then the chunk holding the refused row rolled back
      assert %{manual: %{status: :failed, error: "raise_exception", counts: %{requests: 4}}} =
               Retention.last_run()

      assert [entry] = entries("journal.prune_failed")
      assert entry.permanent
      assert %{"error" => "raise_exception", "requests_deleted" => 4} = entry.metadata
      refute inspect(entry.metadata) =~ "refused by the test"
      assert TestRepo.aggregate(Request, :count) == 2
    end
  end

  describe "a chunk that times out" do
    setup do
      sql!("""
      CREATE FUNCTION retention_test_slow() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (TG_OP = 'DELETE' AND OLD.model = 'slow') OR (TG_OP = 'UPDATE' AND NEW.model = 'slow') THEN
          PERFORM pg_sleep(0.1);
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
      END $$
      """)

      sql!(
        "CREATE TRIGGER retention_test_slow BEFORE DELETE OR UPDATE ON phoenix_kit_ai_requests FOR EACH ROW EXECUTE FUNCTION retention_test_slow()"
      )

      :ok
    end

    test "the journal step: prune_failed with the counts done so far" do
      for n <- 10..7//-1, do: request!(old(n))
      for n <- 4..1//-1, do: request!(old(n), "slow")

      assert {:error, {:prune_failed, "query_canceled"}} =
               Retention.run(
                 :manual,
                 %{requests: min_cutoff(:requests)},
                 @fast ++ [statement_timeout_ms: 150]
               )

      assert %{manual: %{status: :failed, error: "query_canceled", counts: %{requests: 4}}} =
               Retention.last_run()

      assert [%{metadata: %{"requests_deleted" => 4}}] = entries("journal.prune_failed")
    end

    test "the content step halves its chunk and goes on; the smaller size is in the stamp" do
      for n <- 1..8, do: request!(old(n), "slow")

      # 8 slow rows take 800 ms, 4 take 400 ms: over and under the timeout
      assert {:ok, %{counts: %{content: 8}}} =
               Retention.run(
                 :manual,
                 %{content: min_cutoff(:content)},
                 @fast ++ [content_batch: 8, content_min_batch: 2, statement_timeout_ms: 600]
               )

      assert %{manual: %{status: :ok, content_batch: 4}} = Retention.last_run()
    end

    test "after a timeout past its slice, the content step stops instead of retrying" do
      for n <- 1..8, do: request!(old(n), "slow")

      assert {:ok, %{counts: %{content: 0}, more_left: true}} =
               Retention.run(
                 :manual,
                 %{content: min_cutoff(:content)},
                 @fast ++
                   [
                     content_batch: 8,
                     content_min_batch: 2,
                     statement_timeout_ms: 600,
                     time_limits: %{content: 0}
                   ]
               )

      assert %{manual: %{status: :ok, content_batch: 4}} = Retention.last_run()
    end

    test "the content step at its smallest chunk fails" do
      for n <- 1..4, do: request!(old(n), "slow")

      assert {:error, {:prune_failed, "query_canceled"}} =
               Retention.run(
                 :manual,
                 %{content: min_cutoff(:content)},
                 @fast ++ [content_batch: 4, content_min_batch: 2, statement_timeout_ms: 150]
               )

      assert %{manual: %{status: :failed, content_batch: 2}} = Retention.last_run()
    end
  end

  describe "an unreadable settings table" do
    test "every kind reads as forever" do
      {:ok, _} =
        Retention.write_settings(%{
          "requests" => 3,
          "changed_at" => %{"requests" => DateTime.to_iso8601(now())}
        })

      sql!("ALTER TABLE phoenix_kit_settings RENAME TO phoenix_kit_settings_hidden")

      capture_log(fn ->
        assert %{content: :forever, requests: :forever, guard_events: :forever} =
                 Retention.settings()
      end)
    end
  end

  describe "a first write of the periods" do
    # Another first write lands between the lock (no row to lock yet) and
    # this one's insert: the trigger inserts the same key first.
    setup do
      sql!("""
      CREATE FUNCTION retention_test_first() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF pg_trigger_depth() = 1 AND NEW.key = 'ai_journal_retention' THEN
          INSERT INTO phoenix_kit_settings (key, value_json, module)
          VALUES (NEW.key, '{"requests": {"n": 12, "unit": "month"}}', 'ai');
        END IF;
        RETURN NEW;
      END $$
      """)

      sql!(
        "CREATE TRIGGER retention_test_first BEFORE INSERT ON phoenix_kit_settings FOR EACH ROW EXECUTE FUNCTION retention_test_first()"
      )

      :ok
    end

    test "meeting another first write is stale, and nothing is recorded" do
      owner = Scope.for_user(Fixtures.user_fixture())

      assert Retention.put_settings(owner, %{content: {30, :day}}, Retention.settings()) ==
               {:error, :stale_retention}

      assert PhoenixKit.Settings.history("ai_journal_retention") == []
    end
  end

  test "events: the guard events table is not touched by a journal-only failure" do
    event =
      TestRepo.insert!(%GuardEvent{
        kind: "limit_forgiven",
        task_key: "t",
        inserted_at: ~U[2020-01-01 00:00:00Z]
      })

    sql!(
      "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE CASCADE)"
    )

    assert {:cancel, _} =
             Retention.run(
               :manual,
               %{requests: min_cutoff(:requests), guard_events: min_cutoff(:guard_events)},
               @fast
             )

    assert TestRepo.get(GuardEvent, event.uuid)
  end

  test "a nightly foreign-key refusal is logged once a night, stamped every time" do
    sql!(
      "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE RESTRICT)"
    )

    cutoffs = %{requests: min_cutoff(:requests)}
    assert {:cancel, {:foreign_key_blocks, _}} = Retention.run(:scheduled, cutoffs, @fast)
    first = Retention.last_run().scheduled
    assert {:cancel, {:foreign_key_blocks, _}} = Retention.run(:scheduled, cutoffs, @fast)

    assert [_once] = entries("journal.prune_failed")
    second = Retention.last_run().scheduled
    assert %{status: :failed, error: "foreign_key_blocks"} = second
    assert second.failure_logged_at == first.failure_logged_at

    # by hand, every refusal is logged
    assert {:cancel, _} = Retention.run(:manual, cutoffs, @fast)
    assert {:cancel, _} = Retention.run(:manual, cutoffs, @fast)
    assert length(entries("journal.prune_failed")) == 3
  end

  describe "the delete probe" do
    setup do
      sql!("""
      CREATE FUNCTION retention_test_keep() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.model = 'keep' THEN RETURN NULL; END IF;
        RETURN OLD;
      END $$
      """)

      sql!(
        "CREATE TRIGGER retention_test_keep BEFORE DELETE ON phoenix_kit_ai_requests FOR EACH ROW EXECUTE FUNCTION retention_test_keep()"
      )

      :ok
    end

    test "a row the delete left behind: more is left, and its content is cleared" do
      for n <- 4..2//-1, do: request!(old(n))
      kept = request!(old(1), "keep")
      content_cut = min_cutoff(:content)

      assert {:ok, %{counts: %{requests: 3, content: 1}, more_left: true}} =
               Retention.run(
                 :manual,
                 %{requests: min_cutoff(:requests), content: content_cut},
                 @fast
               )

      assert %Request{metadata: metadata} = TestRepo.get(Request, kept.uuid)
      refute Map.has_key?(metadata, "messages")

      assert %{manual: %{more_left: true}, content_done_before: ^content_cut} =
               Retention.last_run()
    end

    test "with a tail that stays, the content step still gets through, run after run" do
      requests_cut = min_cutoff(:requests)
      content_cut = min_cutoff(:content)
      tail = for n <- 1..2, do: request!(old(n), "keep")
      rows = for n <- 1..6, do: request!(DateTime.add(requests_cut, n * 3600))
      cutoffs = %{requests: requests_cut, content: content_cut}
      opts = @fast ++ [time_limits: %{content: 0}]

      results =
        for _run <- 1..6 do
          {:ok, %{counts: %{content: n}, more_left: more_left}} =
            Retention.run(:manual, cutoffs, opts)

          {n, more_left}
        end

      # windows of the rows that stay, each run going on from where the last
      # stopped (the stretch kept as cleared between runs); the run that
      # finishes them is past its slice and leaves the tail to the next one
      # (no later range starts after the slice); the kept rows are always
      # "more left"
      assert Enum.map(results, &elem(&1, 0)) == [2, 1, 1, 1, 1, 2]
      assert Enum.all?(results, &elem(&1, 1))

      for row <- tail ++ rows do
        refute Map.has_key?(TestRepo.get(Request, row.uuid).metadata, "messages")
      end

      assert %{content_done_before: ^content_cut, content_resume: nil} = Retention.last_run()
    end
  end

  describe "the guard events' probe" do
    # A row the statement leaves behind makes a chunk short without the
    # step being through: only the probe can tell.
    setup do
      sql!("""
      CREATE FUNCTION retention_test_keep_event() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.task_key = 'keep' THEN RETURN NULL; END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
      END $$
      """)

      sql!(
        "CREATE TRIGGER retention_test_keep_event BEFORE DELETE OR UPDATE ON phoenix_kit_ai_guard_events FOR EACH ROW EXECUTE FUNCTION retention_test_keep_event()"
      )

      :ok
    end

    for {counter, cutoffs} <- [
          guard_events: [:guard_events],
          guard_reasons: [:content]
        ] do
      test "#{counter}: a short chunk with a row left says more is left" do
        TestRepo.insert!(%GuardEvent{
          kind: "off_purpose",
          task_key: "keep",
          reason: "r",
          inserted_at: DateTime.add(min_cutoff(:guard_events), -3600)
        })

        cutoffs = Map.new(unquote(cutoffs), &{&1, min_cutoff(&1)})

        assert {:ok, %{counts: %{unquote(counter) => 0}, more_left: true}} =
                 Retention.run(:manual, cutoffs, @fast)
      end
    end
  end

  describe "run_now/2's checks" do
    setup do
      start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})
      PhoenixKitAI.enable_system()
      %{owner: Scope.for_user(Fixtures.user_fixture())}
    end

    test "a key that blocks: refused, nothing queued", %{owner: owner} do
      sql!(
        "CREATE TABLE retention_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE RESTRICT)"
      )

      sql!("CREATE INDEX ON retention_fk_test (ref)")

      assert Retention.run_now(owner, %{requests: min_cutoff(:requests)}) ==
               {:error, {:foreign_key_blocks, "retention_fk_test"}}

      assert jobs() == []
    end

    test "a database error during the check: prune_failed with its class, nothing queued", %{
      owner: owner
    } do
      sql!("CREATE SCHEMA retention_shadow")
      sql!("CREATE TABLE retention_shadow.pg_constraint (x int)")
      sql!("SET search_path TO retention_shadow, pg_catalog, public")

      assert Retention.run_now(owner, %{requests: min_cutoff(:requests)}) ==
               {:error, {:prune_failed, "undefined_column"}}

      sql!("SET search_path TO public")
      assert jobs() == []
    end
  end

  test "a database error during the checks: a failed stamp and prune_failed with its class" do
    row = request!(old(1))

    # an unqualified catalogue name now resolves to a table of the wrong shape
    sql!("CREATE SCHEMA retention_shadow")
    sql!("CREATE TABLE retention_shadow.pg_constraint (x int)")
    sql!("SET search_path TO retention_shadow, pg_catalog, public")

    assert {:error, {:prune_failed, "undefined_column"}} =
             Retention.run(:manual, %{requests: min_cutoff(:requests)}, @fast)

    assert TestRepo.get(Request, row.uuid)
    assert %{manual: %{status: :failed, error: "undefined_column"}} = Retention.last_run()
    assert [%{metadata: %{"error" => "undefined_column"}}] = entries("journal.prune_failed")
  end

  describe "a chunk takes no more than its size, whatever the plan" do
    # A plan that rescans a `LIMIT … SKIP LOCKED` subquery inside `IN (…)`:
    # each rescan skips the rows the same statement already deleted and
    # returns the next ones, so the whole table went in one chunk.
    setup do
      for setting <-
            ~w(enable_hashjoin enable_mergejoin enable_material enable_hashagg enable_sort enable_indexscan enable_bitmapscan),
          do: sql!("SET #{setting} = off")

      :ok
    end

    test "journal rows, guard events and reasons stop at the cap" do
      # oldest first in the table, as a plan walking it meets them
      for n <- 20..1//-1, do: request!(old(n))

      for n <- 20..1//-1 do
        TestRepo.insert!(%GuardEvent{
          kind: "off_purpose",
          task_key: "t",
          reason: "r",
          inserted_at: DateTime.add(min_cutoff(:guard_events), -n * 3600)
        })
      end

      assert {:ok, %{counts: counts, more_left: true}} =
               Retention.run(
                 :manual,
                 %{
                   requests: min_cutoff(:requests),
                   content: min_cutoff(:content),
                   guard_events: min_cutoff(:guard_events)
                 },
                 @fast ++ [max_rows: 2]
               )

      assert %{requests: 2, guard_events: 2, guard_reasons: 2} = counts
      assert TestRepo.aggregate(Request, :count) == 18
      assert TestRepo.aggregate(GuardEvent, :count) == 18
    end

    # Without a lock to skip, a rescan of the events' and reasons' chunk
    # finds the same rows, so the count above cannot tell a rescanned chunk
    # from one taken once; the plan can. Every chunk statement of a run,
    # explained against the rows left, takes its LIMIT once.
    test "every chunk statement takes its LIMIT once" do
      for n <- 20..1//-1, do: request!(old(n))

      for n <- 20..1//-1 do
        TestRepo.insert!(%GuardEvent{
          kind: "off_purpose",
          task_key: "t",
          reason: "r",
          inserted_at: DateTime.add(min_cutoff(:guard_events), -n * 3600)
        })
      end

      statements =
        capture_statements(fn ->
          Retention.run(
            :manual,
            %{
              requests: min_cutoff(:requests),
              content: min_cutoff(:content),
              guard_events: min_cutoff(:guard_events)
            },
            @fast ++ [max_rows: 2]
          )
        end)

      # journal rows, content (the rows that stay, then the tail), reasons, events
      sqls = Enum.map(statements, &elem(&1, 0))
      assert length(sqls) == 5
      assert Enum.any?(sqls, &(&1 =~ ~s(DELETE FROM "phoenix_kit_ai_requests")))
      assert Enum.any?(sqls, &(&1 =~ "SET reason = NULL"))
      assert Enum.any?(sqls, &(&1 =~ ~s(DELETE FROM "phoenix_kit_ai_guard_events")))

      for {sql, params} <- statements do
        loops = limit_loops(sql, params)
        assert loops != [], "no LIMIT in the plan of: #{sql}"
        assert Enum.all?(loops, &(&1 <= 1)), "a LIMIT taken #{inspect(loops)} times: #{sql}"
      end
    end
  end

  # The chunk statements a run sent (a LIMIT, then a DELETE or an UPDATE),
  # each once, with the parameters of its first use.
  defp capture_statements(fun) do
    test = self()
    handler = "retention-statements-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_ai, :test, :repo, :query],
      fn _event, _measurements, %{query: sql, params: params}, _config ->
        if sql =~ "LIMIT $" and sql =~ ~r/\b(DELETE|UPDATE)\b/,
          do: send(test, {:sql, sql, params})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_statements([])
  end

  defp collect_statements(acc) do
    receive do
      {:sql, sql, params} ->
        if List.keymember?(acc, sql, 0),
          do: collect_statements(acc),
          else: collect_statements(acc ++ [{sql, params}])
    after
      0 -> acc
    end
  end

  # How many times each Limit node of the statement's plan ran, the
  # statement run (and rolled back) under EXPLAIN ANALYZE.
  defp limit_loops(sql, params) do
    {:error, loops} =
      TestRepo.transaction(fn ->
        %{rows: [[[%{"Plan" => plan}]]]} =
          TestRepo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

        TestRepo.rollback(plan_limits(plan))
      end)

    loops
  end

  defp plan_limits(node) do
    own = if node["Node Type"] == "Limit", do: [node["Actual Loops"]], else: []
    own ++ Enum.flat_map(node["Plans"] || [], &plan_limits/1)
  end
end
