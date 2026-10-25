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
      # stopped (the stretch kept as cleared between runs), then the tail in
      # the run that finishes them; the kept rows are always "more left"
      assert Enum.map(results, &elem(&1, 0)) == [2, 1, 1, 1, 3, 0]
      assert Enum.all?(results, &elem(&1, 1))

      for row <- tail ++ rows do
        refute Map.has_key?(TestRepo.get(Request, row.uuid).metadata, "messages")
      end

      assert %{content_done_before: ^content_cut, content_resume: nil} = Retention.last_run()
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
  end
end
