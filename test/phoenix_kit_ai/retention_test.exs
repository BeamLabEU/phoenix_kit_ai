defmodule PhoenixKitAI.RetentionTest do
  @moduledoc """
  The journal's retention (`PhoenixKitAI.Retention`): the policy, reading
  the periods, the boundaries and the floor, the preview and the three
  passes of a run — journal rows, content, guard events — in chunks, with
  what they keep, the stamp of the last runs and the Activity entries.

  `async: false`: the settings and the site time zone are global.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.{ModuleRegistry, Settings}
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{GuardBlock, GuardEvent, Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @content %{
    "messages" => [%{"role" => "user", "content" => "secret"}],
    "request_payload" => %{"messages" => []},
    "response" => "answer",
    "response_reasoning" => "thinking",
    "stacktrace" => ["A.b/1"],
    "caller_context" => %{"pid" => "#PID<0.1.0>"},
    "error_reason" => ":boom"
  }

  @small %{
    "task" => "ai.playground",
    "source" => "Test.call",
    "cost_source" => "provider",
    "cached" => false,
    "temperature" => 0.7,
    "prompt_snapshot" => %{"hash" => "abc123"}
  }

  # Fast chunks for the tests: small batches, no pause.
  @fast [request_batch: 2, content_batch: 2, event_batch: 2, pause_ms: 0]
  @zero %{content: 0, requests: 0, guard_events: 0, guard_reasons: 0}

  setup do
    Settings.update_setting("time_zone", "0")
    :ok
  end

  defp years_ago(n), do: DateTime.add(now(), -n * 365 * 86_400)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp request!(at, metadata \\ Map.merge(@small, @content), attrs \\ %{}) do
    base = %{
      model: "test/model",
      request_type: "chat",
      status: "success",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      cost: Decimal.new("0.25"),
      metadata: metadata,
      inserted_at: at,
      updated_at: at
    }

    TestRepo.insert!(struct(Request, Map.merge(base, attrs)))
  end

  defp event!(at, attrs \\ %{}) do
    TestRepo.insert!(
      struct(
        GuardEvent,
        Map.merge(%{kind: "limit_forgiven", task_key: "t", inserted_at: at}, attrs)
      )
    )
  end

  defp reload(%Request{uuid: uuid}), do: TestRepo.get(Request, uuid)
  defp reload(%GuardEvent{uuid: uuid}), do: TestRepo.get(GuardEvent, uuid)

  # The most recent boundary a run accepts as it is: the floor.
  defp floor_cut(kind), do: kind |> Retention.floor() |> DateTime.truncate(:second)

  defp all_cutoffs, do: Map.new(Retention.kinds(), &{&1, floor_cut(&1)})

  defp activities(action) do
    TestRepo.all(from(e in PhoenixKit.Activity.Entry, where: e.action == ^action))
  end

  defp counts(overrides), do: Map.merge(@zero, overrides)

  describe "policy" do
    test "every kind is kept forever by default" do
      assert Retention.defaults() == Map.new(Retention.kinds(), &{&1, :forever})
    end

    test "who may set and run a kind follows the owner-only list" do
      PhoenixKitAI.enable_system()
      :ok = ModuleRegistry.register(PhoenixKitAI)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)

      # the first user is the Owner
      owner = Scope.for_user(Fixtures.user_fixture())
      admin = admin_scope(["ai", "ai.manage"])
      viewer = admin_scope(["ai"])
      assert Scope.owner?(owner)

      for kind <- Retention.kinds() do
        assert Retention.may_set?(owner, kind)
        assert Retention.may_run?(owner, kind)
        refute Retention.may_set?(viewer, kind)
        refute Retention.may_run?(viewer, kind)
        refute Retention.may_set?(nil, kind)

        admin_may? = kind not in Retention.owner_only_kinds()
        assert Retention.may_set?(admin, kind) == admin_may?
        assert Retention.may_run?(admin, kind) == admin_may?
      end
    end

    test "periods: forever or N of a unit, N within the unit's range" do
      assert Retention.parse_period("forever") == {:ok, :forever}

      for unit <- Retention.units() do
        name = Atom.to_string(unit)
        max = Retention.max_n(unit)
        assert Retention.parse_period(%{"n" => 1, "unit" => name}) == {:ok, {1, unit}}
        assert Retention.parse_period(%{"n" => max, "unit" => name}) == {:ok, {max, unit}}
        assert Retention.parse_period(%{"n" => max + 1, "unit" => name}) == :error
        assert Retention.parse_period(%{"n" => 0, "unit" => name}) == :error
        assert Retention.period_to_json({max, unit}) == %{"n" => max, "unit" => name}
      end

      for bad <- [%{"n" => "3", "unit" => "month"}, %{"n" => 3, "unit" => "week"}, 3, nil, "3"] do
        assert Retention.parse_period(bad) == :error
      end
    end
  end

  describe "cutoff/3, floor/2, effective_cutoff/3" do
    @now ~U[2026-10-25 12:00:00Z]

    test "25.10.2026 in Europe/Tallinn: 3 months, 1 day, and the floor" do
      Settings.update_setting("time_zone", "Europe/Tallinn")

      assert Retention.cutoff(:requests, {3, :month}, @now) == {:ok, ~U[2026-06-30 21:00:00Z]}
      assert Retention.cutoff(:content, {1, :day}, @now) == {:ok, ~U[2026-10-23 21:00:00Z]}
      assert Retention.cutoff(:requests, {1, :year}, @now) == {:ok, ~U[2025-09-30 21:00:00Z]}

      # 3 months is before the floor: as it is
      assert Retention.effective_cutoff(:requests, ~U[2026-06-30 21:00:00Z], @now) ==
               {:ok, ~U[2026-06-30 21:00:00Z]}

      # 1 day: as it is for content (before now − 24 h), the floor for rows
      assert Retention.effective_cutoff(:content, ~U[2026-10-23 21:00:00Z], @now) ==
               {:ok, ~U[2026-10-23 21:00:00Z]}

      assert Retention.floor(:requests, @now) == ~U[2026-09-28 21:00:00Z]
      assert Retention.floor(:guard_events, @now) == ~U[2026-09-28 21:00:00Z]

      assert Retention.effective_cutoff(:requests, ~U[2026-10-23 21:00:00Z], @now) ==
               {:ok, ~U[2026-09-28 21:00:00Z]}
    end

    test "on the 1st at 01:00 the floor is before now − 24 h and the month" do
      Settings.update_setting("time_zone", "Europe/Tallinn")
      # 01.11.2026 01:00 local (EET, +2)
      now = ~U[2026-10-31 23:00:00Z]
      floor = Retention.floor(:requests, now)

      assert floor == ~U[2026-10-29 22:00:00Z]
      assert DateTime.compare(floor, DateTime.add(now, -86_400)) == :lt
      assert DateTime.diff(now, floor, :hour) >= 48
      assert Retention.floor(:content, now) == DateTime.add(now, -86_400)
    end

    test "a boundary after now is refused" do
      for kind <- Retention.kinds() do
        assert Retention.effective_cutoff(kind, DateTime.add(@now, 1), @now) ==
                 {:error, {:cutoff_in_future, kind}}
      end
    end

    test "each unit at its largest N" do
      for unit <- Retention.units() do
        assert {:ok, %DateTime{year: year}} =
                 Retention.cutoff(:requests, {Retention.max_n(unit), unit}, @now)

        assert year in 1925..1927
      end
    end

    test "an empty zone is UTC" do
      Settings.update_setting("time_zone", "")
      assert Retention.cutoff(:requests, {3, :month}, @now) == {:ok, ~U[2026-07-01 00:00:00Z]}
      assert Retention.floor(:requests, @now) == ~U[2026-09-29 00:00:00Z]
    end

    test "an old offset (\"2\") is a fixed offset" do
      Settings.update_setting("time_zone", "2")
      assert Retention.cutoff(:requests, {3, :month}, @now) == {:ok, ~U[2026-06-30 22:00:00Z]}
    end

    test "an unusable zone is UTC" do
      Settings.update_setting("time_zone", "Mars/Olympus")
      assert Retention.cutoff(:requests, {3, :month}, @now) == {:ok, ~U[2026-07-01 00:00:00Z]}
    end

    test "a period out of range or of an unknown unit is refused" do
      for period <- [{0, :day}, {Retention.max_n(:year) + 1, :year}, {3, :week}, :soon] do
        assert Retention.cutoff(:requests, period, @now) ==
                 {:error, {:invalid_retention, :requests}}
      end
    end

    test "forever keeps" do
      for kind <- Retention.kinds(), do: assert(Retention.cutoff(kind, :forever, @now) == :keep)
    end
  end

  describe "settings/0" do
    test "nothing set: every kind forever" do
      assert %{content: :forever, requests: :forever, guard_events: :forever, unconfirmed: []} =
               Retention.settings()
    end

    test "periods with their changed_at are read" do
      at = DateTime.add(now(), -3 * 86_400)

      Retention.write_settings(%{
        "content" => %{"n" => 30, "unit" => "day"},
        "requests" => %{"n" => 2, "unit" => "year"},
        "guard_events" => "forever",
        "changed_at" => %{
          "content" => DateTime.to_iso8601(at),
          "requests" => DateTime.to_iso8601(at)
        }
      })

      settings = Retention.settings()
      assert %{content: {30, :day}, requests: {2, :year}, guard_events: :forever} = settings
      assert settings.changed_at.content == at
      assert settings.changed_at.guard_events == nil
    end

    test "a value of the wrong form or out of range reads as forever, with a warning" do
      at = DateTime.to_iso8601(now())
      changed = %{"content" => at, "requests" => at, "guard_events" => at}

      log =
        capture_log(fn ->
          Retention.write_settings(%{
            "content" => 3,
            "requests" => %{"n" => Retention.max_n(:month) + 1, "unit" => "month"},
            "guard_events" => %{"n" => 2, "unit" => "week"},
            "changed_at" => changed
          })

          assert %{content: :forever, requests: :forever, guard_events: :forever} =
                   Retention.settings()
        end)

      assert log =~ "invalid period"
    end

    test "garbage instead of a document reads as forever" do
      capture_log(fn ->
        Retention.write_settings(%{"content" => %{"x" => 1}, "changed_at" => "yesterday"})
        assert %{content: :forever} = Retention.settings()
      end)
    end

    test "a period without its changed_at reads as forever and is marked to be saved again" do
      log =
        capture_log(fn ->
          Retention.write_settings(%{"requests" => %{"n" => 12, "unit" => "month"}})
          assert %{requests: :forever, unconfirmed: [:requests]} = Retention.settings()
        end)

      assert log =~ "no changed_at"
    end
  end

  describe "content_keys/0" do
    test "names the content, the legacy raw response and the debug context" do
      for key <-
            ~w(messages request_payload response response_reasoning response_tool_calls input raw_response stacktrace caller_context error_reason) do
        assert key in Retention.content_keys()
      end

      for key <-
            ~w(task source attribution cost_source cached refused answered_model content_redacted prompt_snapshot provider_error) do
        refute key in Retention.content_keys()
      end
    end
  end

  describe "run/3 — journal rows" do
    test "rows older than the boundary go, the boundary itself stays" do
      {:ok, cut} = Retention.cutoff(:requests, {3, :month})
      old = request!(DateTime.add(cut, -1))
      at_cut = request!(cut)
      recent = request!(now())

      assert {:ok, %{counts: %{requests: 1}, more_left: false}} =
               Retention.run(:manual, %{requests: cut}, @fast)

      refute reload(old)
      assert reload(at_cut)
      assert reload(recent)
    end

    test "a run that deleted rows leaves a marker no later run removes" do
      assert Retention.last_run().rows_deleted_before == nil
      cut = floor_cut(:requests)
      earlier = DateTime.add(cut, -10 * 86_400)

      # nothing deleted: no marker
      assert {:ok, %{counts: %{requests: 0}}} = Retention.run(:manual, %{requests: cut}, @fast)
      assert Retention.last_run().rows_deleted_before == nil

      request!(DateTime.add(cut, -3600))
      assert {:ok, %{counts: %{requests: 1}}} = Retention.run(:scheduled, %{requests: cut}, @fast)
      assert Retention.last_run().rows_deleted_before == cut

      # a later run that deletes nothing, then one with no journal boundary
      assert {:ok, _} = Retention.run(:scheduled, %{requests: cut}, @fast)
      assert {:ok, _} = Retention.run(:manual, %{content: floor_cut(:content)}, @fast)
      assert Retention.last_run().rows_deleted_before == cut

      # it moves back to an earlier boundary, never forward
      request!(DateTime.add(earlier, -3600))

      assert {:ok, %{counts: %{requests: 1}}} =
               Retention.run(:manual, %{requests: earlier}, @fast)

      assert Retention.last_run().rows_deleted_before == earlier

      request!(DateTime.add(cut, -3600))
      assert {:ok, %{counts: %{requests: 1}}} = Retention.run(:manual, %{requests: cut}, @fast)
      assert Retention.last_run().rows_deleted_before == earlier
    end

    test "the keyset walks to the end in small chunks" do
      cut = floor_cut(:requests)
      for n <- 1..7, do: request!(DateTime.add(cut, -n * 3600))

      assert {:ok, %{counts: %{requests: 7}, more_left: false}} =
               Retention.run(:manual, %{requests: cut}, @fast)

      assert TestRepo.aggregate(Request, :count) == 0
    end

    test "rows with the same time: chunks of one walk past each of them" do
      cut = floor_cut(:requests)
      at = DateTime.add(cut, -3600)
      for _ <- 1..4, do: request!(at)
      for _ <- 1..3, do: request!(DateTime.add(cut, 3600))

      opts = @fast ++ [request_batch: 1, content_batch: 1]

      assert {:ok, %{counts: %{requests: 4, content: 3}, more_left: false}} =
               Retention.run(:manual, %{requests: cut, content: floor_cut(:content)}, opts)

      assert TestRepo.aggregate(Request, :count) == 3
    end

    test "the row cap of a run stops it and says more is left" do
      cut = floor_cut(:requests)
      for n <- 1..5, do: request!(DateTime.add(cut, -n * 3600))

      assert {:ok, %{counts: %{requests: 3}, more_left: true}} =
               Retention.run(:manual, %{requests: cut}, @fast ++ [max_rows: 3])

      assert TestRepo.aggregate(Request, :count) == 2
      assert %{manual: %{more_left: true, counts: %{requests: 3}}} = Retention.last_run()
    end

    test "a cap or a time slice reached exactly at the end says nothing is left" do
      cut = floor_cut(:requests)
      for n <- 1..4, do: request!(DateTime.add(cut, -n * 3600))
      for n <- 1..2, do: event!(DateTime.add(floor_cut(:guard_events), -n * 3600))

      assert {:ok, %{counts: %{requests: 4}, more_left: false}} =
               Retention.run(:manual, %{requests: cut}, @fast ++ [max_rows: 4])

      assert {:ok, %{counts: %{guard_events: 2}, more_left: false}} =
               Retention.run(
                 :manual,
                 %{guard_events: floor_cut(:guard_events)},
                 @fast ++ [time_limits: %{guard_events: 0}]
               )
    end

    test "a deleted row's guard event keeps the event with the reference emptied" do
      row = request!(years_ago(5))
      event = event!(now(), %{request_uuid: row.uuid, kind: "off_purpose", reason: "r"})

      assert {:ok, _} = Retention.run(:manual, %{requests: floor_cut(:requests)}, @fast)
      assert %GuardEvent{request_uuid: nil} = reload(event)
    end

    test "a forged boundary inside the month deletes nothing newer than the floor" do
      floor = floor_cut(:requests)
      old = request!(DateTime.add(floor, -60))
      kept = request!(DateTime.add(floor, 60))
      today = request!(DateTime.add(now(), -3600))
      old_event = event!(DateTime.add(floor, -60))
      kept_event = event!(DateTime.add(floor, 60))
      forged = DateTime.add(now(), -60)

      assert {:ok, _} =
               Retention.run(:manual, %{requests: forged, guard_events: forged}, @fast)

      refute reload(old)
      refute reload(old_event)
      assert reload(kept)
      assert reload(today)
      assert reload(kept_event)
    end

    test "a boundary in the future is cancelled, nothing deleted" do
      row = request!(years_ago(10))

      assert {:cancel, {:cutoff_in_future, :requests}} =
               Retention.run(:manual, %{requests: DateTime.add(now(), 3600)}, @fast)

      assert reload(row)
      assert %{manual: %{status: :failed, error: "cutoff_in_future"}} = Retention.last_run()
    end

    test "a boundary that is not a moment is cancelled" do
      row = request!(years_ago(10))

      assert {:cancel, {:invalid_cutoff, :requests}} =
               Retention.run(:manual, %{requests: "2020-01-01"}, @fast)

      assert reload(row)
      assert %{manual: %{status: :failed, error: "invalid_cutoff"}} = Retention.last_run()

      assert [%{metadata: %{"requests_before" => nil, "error" => "invalid_cutoff"}}] =
               activities("journal.prune_failed")

      assert Retention.preview(%{content: 1}) == {:error, {:invalid_cutoff, :content}}
    end

    test "options that are not a keyword list are ignored, with a warning" do
      request!(years_ago(10))

      log =
        capture_log(fn ->
          assert {:ok, %{counts: %{requests: 1}}} =
                   Retention.run(:manual, %{requests: floor_cut(:requests)}, [1, 2])
        end)

      assert log =~ "not a keyword list"
    end

    test "the largest periods run" do
      for unit <- Retention.units() do
        cutoffs =
          Map.new(Retention.kinds(), fn kind ->
            {:ok, cut} = Retention.cutoff(kind, {Retention.max_n(unit), unit})
            {kind, cut}
          end)

        assert {:ok, %{counts: @zero}} = Retention.run(:manual, cutoffs, @fast)
        assert {:ok, %{requests: 0}} = Retention.preview(cutoffs)
      end
    end
  end

  describe "run/3 — content" do
    test "clears the content keys, keeps money, tokens and the small keys, stamps the row" do
      row = request!(years_ago(1))

      assert {:ok, %{counts: %{content: 1}}} =
               Retention.run(:manual, %{content: floor_cut(:content)}, @fast)

      pruned = reload(row)
      assert Decimal.equal?(pruned.cost, row.cost)
      assert {pruned.input_tokens, pruned.output_tokens, pruned.total_tokens} == {10, 5, 15}
      assert Map.drop(pruned.metadata, ["content_pruned_at"]) == @small
      assert {:ok, _, _} = DateTime.from_iso8601(pruned.metadata["content_pruned_at"])
    end

    test "an old row with raw_response is cleared" do
      row = request!(years_ago(3), %{"raw_response" => %{"choices" => []}, "task" => "t"})

      assert {:ok, _} = Retention.run(:manual, %{content: floor_cut(:content)}, @fast)
      assert %{"task" => "t", "content_pruned_at" => _} = reload(row).metadata
      refute Map.has_key?(reload(row).metadata, "raw_response")
    end

    test "rows without content and recent rows are not touched; a window walks past the bare ones" do
      cut = floor_cut(:content)
      bare = for n <- 1..3, do: request!(DateTime.add(cut, -(10 + n) * 3600), @small)
      full = for n <- 1..3, do: request!(DateTime.add(cut, -n * 3600))
      recent = request!(DateTime.add(cut, 1))

      assert {:ok, %{counts: %{content: 3}, more_left: false}} =
               Retention.run(:manual, %{content: cut}, @fast)

      assert Enum.all?(bare, &(reload(&1).metadata == @small))
      assert Enum.all?(full, &(not Map.has_key?(reload(&1).metadata, "messages")))
      assert reload(recent).metadata == Map.merge(@small, @content)
    end

    test "a forged boundary clears nothing newer than 24 hours" do
      day_old = request!(DateTime.add(now(), -25 * 3600))
      hour_old = request!(DateTime.add(now(), -3600))

      assert {:ok, %{counts: %{content: 1}}} =
               Retention.run(:manual, %{content: DateTime.add(now(), -60)}, @fast)

      refute Map.has_key?(reload(day_old).metadata, "messages")
      assert reload(hour_old).metadata["messages"]
    end

    test "the point already cleared moves to the boundary, and the next run starts from it" do
      cut = floor_cut(:content)
      for n <- 1..3, do: request!(DateTime.add(cut, -n * 86_400))

      assert {:ok, %{counts: %{content: 3}, content_done_before: ^cut}} =
               Retention.run(:manual, %{content: cut}, @fast)

      assert Retention.last_run().content_done_before == cut

      # a row below that point (written there by hand) is not walked again
      below = request!(DateTime.add(cut, -10 * 86_400))
      assert {:ok, %{counts: %{content: 0}}} = Retention.run(:manual, %{content: cut}, @fast)
      assert reload(below).metadata["messages"]
    end

    test "the journal step's tail: the content of the rows left is cleared all the same" do
      requests_cut = floor_cut(:requests)
      content_cut = floor_cut(:content)
      tail = for n <- 1..5, do: request!(DateTime.add(requests_cut, -n * 3600))
      kept = request!(DateTime.add(requests_cut, 86_400))

      # the journal step stops after one chunk of two
      assert {:ok, %{counts: %{requests: 2, content: content}, more_left: true}} =
               Retention.run(
                 :manual,
                 %{requests: requests_cut, content: content_cut},
                 @fast ++ [time_limits: %{requests: 0}]
               )

      # the row that stays, then the three left of the tail
      assert content == 4
      left = tail |> Enum.map(&reload/1) |> Enum.reject(&is_nil/1)
      assert length(left) == 3
      assert Enum.all?(left, &(not Map.has_key?(&1.metadata, "messages")))
      refute Map.has_key?(reload(kept).metadata, "messages")
      assert Retention.last_run().content_done_before == content_cut

      # the journal period back to forever: nothing more to clear
      assert {:ok, %{counts: %{content: 0}}} =
               Retention.run(:manual, %{content: content_cut}, @fast)
    end

    test "the reason of an off-purpose flag is cleared, others and an active block's are not" do
      at = years_ago(1)
      user = Fixtures.user_fixture()

      flag = event!(at, %{kind: "off_purpose", reason: "the user's words"})
      origin = event!(at, %{kind: "off_purpose", reason: "why blocked"})
      other = event!(at, %{kind: "anomaly", reason: "rule"})
      recent = event!(now(), %{kind: "off_purpose", reason: "fresh"})

      TestRepo.insert!(%GuardBlock{
        block_group: "free_text",
        user_uuid: user.uuid,
        origin_event_uuid: origin.uuid,
        blocked_at: at
      })

      assert {:ok, %{counts: %{guard_reasons: 1, content: 0}}} =
               Retention.run(:manual, %{content: floor_cut(:content)}, @fast)

      assert reload(flag).reason == nil
      assert reload(origin).reason == "why blocked"
      assert reload(other).reason == "rule"
      assert reload(recent).reason == "fresh"
      assert [%{metadata: %{"guard_reasons_cleared" => 1}}] = activities("journal.pruned")
    end

    test "task limits and the spend caps count the same before and after" do
      PhoenixKitAI.enable_system()
      user = Fixtures.user_fixture()
      endpoint = endpoint_fixture()
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:global, "1000")
      # past the content floor
      at = DateTime.add(now(), -25 * 3600)

      for _ <- 1..3 do
        request!(at, Map.merge(@small, @content), %{
          user_uuid: user.uuid,
          endpoint_uuid: endpoint.uuid
        })
      end

      # the task's day and month as of the rows
      usage = fn ->
        PhoenixKitAI.TaskLimits.usage("ai.playground", user.uuid, DateTime.add(at, 60))
      end

      spend = fn -> PhoenixKitAI.Budget.status(endpoint, user_uuid: user.uuid) end
      stats = fn -> PhoenixKitAI.get_usage_stats(endpoint_uuid: endpoint.uuid) end
      before = {usage.(), spend.(), stats.()}
      assert %{task: %{requests: %{day: 3}}} = elem(before, 0)

      assert {:ok, %{counts: %{content: 3}}} =
               Retention.run(:manual, %{content: floor_cut(:content)}, @fast)

      assert {usage.(), spend.(), stats.()} == before
    end

    test "a moment given later than now does not move the floor" do
      floor = floor_cut(:requests)
      old = request!(DateTime.add(floor, -60))
      minute_old = request!(DateTime.add(now(), -60))
      hour_old_content = request!(DateTime.add(now(), -3600))
      later = DateTime.add(now(), 400 * 86_400)

      assert {:cancel, {:cutoff_in_future, :requests}} =
               Retention.run(:manual, %{requests: DateTime.add(now(), 10)}, now: later)

      assert {:ok, %{counts: %{requests: 1}}} =
               Retention.run(
                 :manual,
                 %{requests: DateTime.add(now(), -30), content: DateTime.add(now(), -30)},
                 @fast ++ [now: later]
               )

      refute reload(old)
      assert reload(minute_old)
      assert reload(hour_old_content).metadata["messages"]

      assert {:ok, %{requests: 0, cutoffs: %{requests: used}}} =
               Retention.preview_counts(%{requests: DateTime.add(now(), -30)}, now: later)

      assert DateTime.compare(used, floor) == :eq
    end

    test "content stopped on its slice goes on where it stopped, run after run" do
      cut = floor_cut(:content)
      rows = for n <- 1..6, do: request!(DateTime.add(cut, -n * 3600))
      opts = @fast ++ [time_limits: %{content: 0}]

      cleared =
        for _run <- 1..6 do
          {:ok, %{counts: %{content: n}}} = Retention.run(:manual, %{content: cut}, opts)
          n
        end

      # each later run starts at the time it stopped at, so its window looks
      # at the last row cleared again
      assert cleared == [2, 1, 1, 1, 1, 0]
      assert Enum.all?(rows, &(not Map.has_key?(reload(&1).metadata, "messages")))
      assert Retention.last_run().content_done_before == cut
    end

    test "stopped on its slice with no row with content after the cursor: done" do
      cut = floor_cut(:content)
      for n <- 1..3, do: request!(DateTime.add(cut, -n * 3600), @small)
      for n <- 4..5, do: request!(DateTime.add(cut, -n * 3600))

      assert {:ok, %{counts: %{content: 2}, more_left: false, content_done_before: ^cut}} =
               Retention.run(:manual, %{content: cut}, @fast ++ [time_limits: %{content: 0}])
    end

    test "content stopped on its cap goes on where it stopped" do
      cut = floor_cut(:content)
      for n <- 1..5, do: request!(DateTime.add(cut, -n * 3600))

      assert {:ok, %{counts: %{content: 2}, more_left: true}} =
               Retention.run(:manual, %{content: cut}, @fast ++ [max_rows: 2])

      assert {:ok, %{counts: %{content: 2}}} =
               Retention.run(:manual, %{content: cut}, @fast ++ [max_rows: 2])

      assert {:ok, %{counts: %{content: 1}, content_done_before: ^cut}} =
               Retention.run(:manual, %{content: cut}, @fast)
    end
  end

  describe "run/3 — guard events" do
    test "events older than the boundary go; an active block's stays, a lifted one's goes" do
      cut = floor_cut(:guard_events)
      user = Fixtures.user_fixture()
      at = years_ago(1)

      old = event!(at)
      active_origin = event!(at)
      lifted_origin = event!(at)
      recent = event!(DateTime.add(cut, 60))

      TestRepo.insert!(%GuardBlock{
        block_group: "g1",
        user_uuid: user.uuid,
        origin_event_uuid: active_origin.uuid,
        blocked_at: at
      })

      TestRepo.insert!(%GuardBlock{
        block_group: "g2",
        user_uuid: user.uuid,
        origin_event_uuid: lifted_origin.uuid,
        blocked_at: at,
        lifted_at: at
      })

      assert {:ok, %{counts: %{guard_events: 2}}} =
               Retention.run(:manual, %{guard_events: cut}, @fast)

      refute reload(old)
      refute reload(lifted_origin)
      assert reload(active_origin)
      assert reload(recent)
    end
  end

  describe "run/3 — limits and order" do
    # The counter out of time does one chunk; the others go on to the end
    # (the content step also clears the three rows the journal step left).
    for {counter, expected} <- [
          requests: %{requests: 2, content: 8, guard_events: 5, guard_reasons: 5},
          content: %{requests: 5, content: 2, guard_events: 5, guard_reasons: 5},
          guard_reasons: %{requests: 5, content: 5, guard_events: 5, guard_reasons: 2},
          guard_events: %{requests: 5, content: 5, guard_events: 2, guard_reasons: 5}
        ] do
      test "#{counter} has its own time slice" do
        counter = unquote(counter)
        requests_cut = floor_cut(:requests)
        for n <- 1..5, do: request!(DateTime.add(requests_cut, -n * 3600))
        for n <- 1..5, do: request!(DateTime.add(requests_cut, n * 3600))

        for n <- 1..5,
            do: event!(DateTime.add(requests_cut, -n * 3600), %{kind: "off_purpose", reason: "r"})

        limits =
          Map.new(Map.keys(@zero), &{&1, if(&1 == counter, do: 0, else: 60_000)})

        assert {:ok, %{counts: counts, more_left: true}} =
                 Retention.run(:manual, all_cutoffs(), @fast ++ [time_limits: limits])

        assert counts == unquote(Macro.escape(expected))
      end
    end

    test "nothing is touched without a boundary" do
      row = request!(years_ago(10))
      event = event!(years_ago(10))

      assert {:ok, %{counts: @zero}} = Retention.run(:manual, %{}, @fast)

      assert reload(row).metadata == Map.merge(@small, @content)
      assert reload(event)
    end

    test "invalid options fall back to the defaults, with a warning" do
      request!(years_ago(10))

      log =
        capture_log(fn ->
          assert {:ok, %{counts: %{requests: 1}}} =
                   Retention.run(
                     :manual,
                     %{requests: floor_cut(:requests)},
                     request_batch: 0,
                     pause_ms: -1,
                     time_limits: %{requests: "soon"}
                   )
        end)

      assert log =~ "option request_batch is invalid"
      assert log =~ "option pause_ms is invalid"
      assert log =~ "option time_limits is invalid"
    end

    test "time slices that do not fit in the job's timeout fall back to the defaults" do
      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Retention.run(:manual, %{},
                     time_limits: %{requests: Retention.job_timeout_ms()}
                   )
        end)

      assert log =~ "do not fit in the job's timeout"
    end

    test "each counter's slice leaves room for one chunk and one probe past it" do
      # 4 counters × 2 × (30 s + 5 s) + 60 s: the defaults fit in 25 minutes
      refute capture_log(fn -> Retention.run(:manual, %{}) end) =~ "do not fit"

      # 20 minutes of slices fit with one statement per counter, not with two
      log =
        capture_log(fn ->
          assert {:ok, _} = Retention.run(:manual, %{}, time_limits: %{requests: 11 * 60_000})
        end)

      assert log =~ "do not fit in the job's timeout"
    end

    test "a statement timeout too long for even the default slices is lowered until they fit" do
      log =
        capture_log(fn ->
          opts = Retention.run_options(statement_timeout_ms: 60_000)

          assert opts[:statement_timeout_ms] < 60_000
          assert opts[:time_limits] == Retention.run_options([])[:time_limits]
          assert Retention.run_budget_ms(opts) < Retention.job_timeout_ms()
          # the largest that fits: one more millisecond would not
          refute Retention.run_budget_ms(Keyword.update!(opts, :statement_timeout_ms, &(&1 + 1))) <
                   Retention.job_timeout_ms()
        end)

      assert log =~ "option statement_timeout_ms does not fit in the job's timeout"
      # the slices were the defaults already: no fallback to report
      refute log =~ "the time limits do not fit"
    end

    test "a statement timeout that fits is kept" do
      refute capture_log(fn ->
               assert Retention.run_options(statement_timeout_ms: 20_000)[:statement_timeout_ms] ==
                        20_000
             end) =~ "statement_timeout_ms"
    end

    test "a run with a too long statement timeout still runs, within the job's timeout" do
      request!(years_ago(10))

      log =
        capture_log(fn ->
          assert {:ok, %{counts: %{requests: 1}}} =
                   Retention.run(
                     :manual,
                     %{requests: floor_cut(:requests)},
                     @fast ++ [statement_timeout_ms: 600_000]
                   )
        end)

      assert log =~ "option statement_timeout_ms does not fit in the job's timeout"
    end
  end

  describe "run/3 — stamp and Activity" do
    test "a manual run: stamp under manual, a permanent journal.pruned with the counts" do
      actor = Fixtures.user_fixture()
      request!(years_ago(10))
      event!(years_ago(10))
      cutoffs = all_cutoffs()

      assert {:ok, _} = Retention.run(:manual, cutoffs, @fast ++ [actor_uuid: actor.uuid])

      assert %{manual: manual, scheduled: nil} = Retention.last_run()
      assert %{status: :ok, error: nil, more_left: false} = manual
      assert manual.actor_uuid == actor.uuid
      assert manual.counts == counts(%{requests: 1, guard_events: 1})

      assert [entry] = activities("journal.pruned")
      assert entry.permanent
      assert entry.mode == "manual"
      assert entry.actor_uuid == actor.uuid

      assert entry.metadata == %{
               "content_cleared" => 0,
               "requests_deleted" => 1,
               "guard_events_deleted" => 1,
               "guard_reasons_cleared" => 0,
               "content_before" => DateTime.to_iso8601(cutoffs.content),
               "requests_before" => DateTime.to_iso8601(cutoffs.requests),
               "guard_events_before" => DateTime.to_iso8601(cutoffs.guard_events),
               "more_left" => false
             }
    end

    test "a nightly run is mode cron; a nightly run with nothing done writes only the stamp" do
      assert {:ok, _} = Retention.run(:scheduled, all_cutoffs(), @fast)
      assert activities("journal.pruned") == []
      assert %{scheduled: %{status: :ok}} = Retention.last_run()

      request!(years_ago(10))
      assert {:ok, _} = Retention.run(:scheduled, all_cutoffs(), @fast)
      assert [%{mode: "cron", permanent: true}] = activities("journal.pruned")
    end

    test "scheduled and manual are separate entries" do
      assert {:ok, _} = Retention.run(:scheduled, %{}, @fast)
      assert {:ok, _} = Retention.run(:manual, %{}, @fast)
      assert %{scheduled: %{status: :ok}, manual: %{status: :ok}} = Retention.last_run()
    end

    test "the stamp records no settings history" do
      assert {:ok, _} = Retention.run(:manual, %{}, @fast)

      refute Enum.any?(
               activities("setting.changed"),
               &(&1.metadata["key"] == Retention.last_run_key())
             )
    end
  end

  describe "preview/1" do
    test "counts what would go; content is the range that stays" do
      requests_cut = floor_cut(:requests)
      content_cut = floor_cut(:content)
      events_cut = floor_cut(:guard_events)
      for n <- 1..2, do: request!(DateTime.add(requests_cut, -n * 3600))
      for n <- 1..3, do: request!(DateTime.add(requests_cut, n * 3600), @small)
      request!(now())
      for n <- 1..4, do: event!(DateTime.add(events_cut, -n * 3600))

      assert {:ok, %{requests: 2, content: 3, guard_events: 4, clamped: []} = preview} =
               Retention.preview(%{
                 requests: requests_cut,
                 content: content_cut,
                 guard_events: events_cut
               })

      assert preview.cutoffs == %{
               requests: requests_cut,
               content: content_cut,
               guard_events: events_cut
             }

      assert {:ok, %{requests: 0, content: 5, guard_events: 0}} =
               Retention.preview(%{content: content_cut})

      # nothing was deleted
      assert TestRepo.aggregate(Request, :count) == 6
    end

    test "names the kinds held at the floor, and counts by the floor" do
      floor = floor_cut(:requests)
      request!(DateTime.add(floor, -60))
      request!(DateTime.add(floor, 60))

      assert {:ok, %{requests: 1, clamped: [:requests], cutoffs: %{requests: used}}} =
               Retention.preview(%{requests: DateTime.add(now(), -60)})

      assert DateTime.compare(used, floor) == :eq
    end

    test "content counts from the point already cleared" do
      cut = floor_cut(:content)
      done_before = DateTime.add(cut, -5 * 86_400)
      for n <- 1..2, do: request!(DateTime.add(done_before, -n * 3600))
      for n <- 1..3, do: request!(DateTime.add(done_before, n * 3600))

      {:ok, _} =
        Settings.update_json_setting_with_module(
          Retention.last_run_key(),
          %{"content_done_before" => DateTime.to_iso8601(done_before)},
          "ai",
          history: false
        )

      assert {:ok, %{content: 3}} = Retention.preview(%{content: cut})
    end

    test "a boundary in the future is refused" do
      assert Retention.preview(%{guard_events: DateTime.add(now(), 60)}) ==
               {:error, {:cutoff_in_future, :guard_events}}
    end
  end

  # A user with the Admin role holding exactly `keys`, as a fresh scope.
  defp admin_scope(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    Scope.for_user(user)
  end

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Retention-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "test/model",
        api_key: "sk-test-key"
      })

    ep
  end
end
