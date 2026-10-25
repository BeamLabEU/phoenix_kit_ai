defmodule PhoenixKitAI.RetentionSettingsTest do
  @moduledoc """
  The person-facing side of `PhoenixKitAI.Retention`: saving the periods
  (`put_settings/3` — rights, merging, the stale check, the history entry),
  the preview and the manual run behind the same rights (`preview/2`,
  `run_now/2`), and the helpers the form reads (`shorter?/4`,
  `warnings/4`).

  `async: false`: the settings, the site time zone and the Oban instance
  are global.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.{ModuleRegistry, Settings}
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @key "ai_journal_retention"

  setup do
    Settings.update_setting("time_zone", "0")
    PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)

    # the first user is the Owner: made before anyone else
    owner = Scope.for_user(Fixtures.user_fixture())
    true = Scope.owner?(owner)

    %{
      owner: owner,
      admin: admin_scope(["ai", "ai.manage"]),
      viewer: admin_scope(["ai"])
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp history, do: Settings.history(@key)

  defp request!(at) do
    TestRepo.insert!(%Request{
      model: "m",
      request_type: "chat",
      status: "success",
      metadata: %{"messages" => [%{"content" => "x"}], "task" => "t"},
      inserted_at: at,
      updated_at: at
    })
  end

  defp floor_cut(kind), do: kind |> Retention.floor() |> DateTime.truncate(:second)

  defp start_oban, do: start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

  defp jobs,
    do: TestRepo.all(from(j in Oban.Job, where: j.worker == "PhoenixKitAI.JournalPruneWorker"))

  describe "put_settings/3" do
    test "ai.manage sets all three kinds; the periods are read back", %{admin: admin} do
      loaded = Retention.settings()
      attrs = %{content: {30, :day}, requests: {12, :month}, guard_events: {2, :year}}

      assert {:ok, saved} = Retention.put_settings(admin, attrs, loaded)
      assert Map.take(saved, Retention.kinds()) == attrs
      assert saved.unconfirmed == []
      assert Retention.settings() == saved
    end

    test "without ai.manage: forbidden, nothing written", %{viewer: viewer} do
      loaded = Retention.settings()

      assert Retention.put_settings(viewer, %{content: {30, :day}}, loaded) ==
               {:error, :forbidden}

      assert Retention.put_settings(nil, %{content: {30, :day}}, loaded) == {:error, :forbidden}
      assert Settings.get_json_setting(@key) == nil
      assert history() == []
    end

    test "an Owner without the permission may", %{owner: owner} do
      assert {:ok, %{requests: {3, :month}}} =
               Retention.put_settings(owner, %{requests: {3, :month}}, Retention.settings())
    end

    test "a value of the wrong form, N out of range, an unknown unit: refused, nothing written",
         %{admin: admin} do
      loaded = Retention.settings()

      for {kind, bad} <- [
            content: "30 days",
            content: {"30", :day},
            requests: {0, :month},
            requests: {Retention.max_n(:month) + 1, :month},
            guard_events: {Retention.max_n(:year) + 1, :year},
            guard_events: {3, :week},
            content: %{"n" => 3, "unit" => "week"},
            requests: nil
          ] do
        assert Retention.put_settings(admin, %{kind => bad}, loaded) ==
                 {:error, {:invalid_retention, kind}}
      end

      assert Settings.get_json_setting(@key) == nil
      assert history() == []
    end

    test "the stored form and the largest N are accepted", %{admin: admin} do
      attrs = %{
        content: %{"n" => Retention.max_n(:day), "unit" => "day"},
        requests: "forever",
        guard_events: {Retention.max_n(:year), :year}
      }

      assert {:ok, saved} = Retention.put_settings(admin, attrs, Retention.settings())
      assert saved.content == {Retention.max_n(:day), :day}
      assert saved.requests == :forever
      assert saved.guard_events == {Retention.max_n(:year), :year}
    end

    test "content kept longer than the rows is saved", %{admin: admin} do
      assert {:ok, %{content: {2, :year}, requests: {3, :month}}} =
               Retention.put_settings(
                 admin,
                 %{content: {2, :year}, requests: {3, :month}},
                 Retention.settings()
               )

      assert {:ok, %{content: :forever, requests: {1, :day}}} =
               Retention.put_settings(
                 admin,
                 %{content: :forever, requests: {1, :day}},
                 Retention.settings()
               )
    end

    test "back to forever", %{admin: admin} do
      {:ok, saved} = Retention.put_settings(admin, %{requests: {3, :month}}, Retention.settings())

      assert {:ok, %{requests: :forever}} =
               Retention.put_settings(admin, %{requests: :forever}, saved)

      assert Retention.settings().requests == :forever
      assert Settings.get_json_setting(@key)["requests"] == "forever"
    end

    test "every kind is written out, forever included", %{admin: admin} do
      {:ok, _} = Retention.put_settings(admin, %{content: {30, :day}}, Retention.settings())

      assert %{
               "content" => %{"n" => 30, "unit" => "day"},
               "requests" => "forever",
               "guard_events" => "forever"
             } =
               Settings.get_json_setting(@key)
    end

    test "changed_at is set by the server, and only for the kinds changed", %{admin: admin} do
      long_ago = ~U[2020-01-01 00:00:00Z]

      {:ok, _} =
        Retention.write_settings(%{
          "content" => %{"n" => 30, "unit" => "day"},
          "requests" => %{"n" => 12, "unit" => "month"},
          "guard_events" => "forever",
          "changed_at" => %{
            "content" => DateTime.to_iso8601(long_ago),
            "requests" => DateTime.to_iso8601(long_ago)
          }
        })

      loaded = Retention.settings()
      before = now()

      # the same content as loaded, a new requests period
      attrs = %{content: {30, :day}, requests: {6, :month}}
      assert {:ok, saved} = Retention.put_settings(admin, attrs, loaded)

      assert saved.changed_at.content == long_ago
      assert DateTime.compare(saved.changed_at.requests, before) != :lt
      assert saved.changed_at.guard_events == nil
      assert Retention.settings().changed_at == saved.changed_at
    end

    test "kinds may be named by their strings", %{owner: owner} do
      attrs = %{"content" => %{"n" => 30, "unit" => "day"}, "requests" => "forever"}

      assert {:ok, %{content: {30, :day}, requests: :forever}} =
               Retention.put_settings(owner, attrs, Retention.settings())

      assert Retention.settings().content == {30, :day}
    end

    test "any other key is refused, nothing written", %{owner: owner} do
      loaded = Retention.settings()

      for key <- [:changed_at, "changed_at", "Content", :rows, 1] do
        assert Retention.put_settings(owner, %{key => {30, :day}}, loaded) ==
                 {:error, {:unknown_kind, key}}
      end

      assert Retention.put_settings(
               owner,
               %{:content => {30, :day}, "content" => {1, :day}},
               loaded
             ) ==
               {:error, {:invalid_retention, :content}}

      assert Settings.get_json_setting(@key) == nil
    end

    test "loaded in the stored form, or by strings, is read like settings/0", %{owner: owner} do
      {:ok, _} = Retention.put_settings(owner, %{content: {30, :day}}, Retention.settings())

      for loaded <- [
            %{
              content: %{"n" => 30, "unit" => "day"},
              requests: "forever",
              guard_events: "forever"
            },
            %{"content" => %{"n" => 30, "unit" => "day"}, "requests" => "forever"}
          ] do
        # content as loaded, requests changed: not stale
        assert {:ok, %{content: {30, :day}, requests: {12, :month}}} =
                 Retention.put_settings(
                   owner,
                   %{content: {30, :day}, requests: {12, :month}},
                   loaded
                 )

        {:ok, _} = Retention.put_settings(owner, %{requests: :forever}, Retention.settings())
      end
    end

    test "a kind the form did not load is changed only if it is what is stored", %{owner: owner} do
      {:ok, _} = Retention.put_settings(owner, %{content: {30, :day}}, Retention.settings())
      history_before = length(history())

      for loaded <- [%{}, %{content: "garbage"}] do
        # the value stored: nothing to change, nothing written
        assert {:ok, %{content: {30, :day}}} =
                 Retention.put_settings(owner, %{content: {30, :day}}, loaded)

        # another value: what the form saw is unknown, so it is stale
        assert Retention.put_settings(owner, %{content: {60, :day}}, loaded) ==
                 {:error, :stale_retention}
      end

      assert length(history()) == history_before
      assert Retention.settings().content == {30, :day}
    end

    test "a kind missing from loaded, given as stored: nothing written, changed_at kept", %{
      owner: owner
    } do
      long_ago = ~U[2020-01-01 00:00:00Z]

      {:ok, _} =
        Retention.write_settings(%{
          "content" => %{"n" => 30, "unit" => "day"},
          "changed_at" => %{"content" => DateTime.to_iso8601(long_ago)}
        })

      seeded = history()
      assert {:ok, saved} = Retention.put_settings(owner, %{content: {30, :day}}, %{})
      assert saved.changed_at.content == long_ago
      assert Retention.settings().changed_at.content == long_ago
      assert history() == seeded
    end

    test "a period stored without changed_at is confirmed by saving it, forever included", %{
      owner: owner
    } do
      {:ok, _} = Retention.write_settings(%{"content" => %{"n" => 30, "unit" => "day"}})
      loaded = Retention.settings()
      assert %{content: :forever, unconfirmed: [:content]} = loaded

      # the form shows forever; saved as it is, it is now forever on purpose
      assert {:ok, saved} = Retention.put_settings(owner, %{content: :forever}, loaded)
      assert %{content: :forever, unconfirmed: []} = saved
      assert %DateTime{} = saved.changed_at.content
      assert Settings.get_json_setting(@key)["content"] == "forever"
      assert Retention.settings() == saved
      assert [%{actor_uuid: actor} | _seeded] = history()
      assert actor == owner.user.uuid
    end

    test "a period stored without changed_at is confirmed by saving a period", %{owner: owner} do
      {:ok, _} = Retention.write_settings(%{"content" => %{"n" => 30, "unit" => "day"}})

      assert {:ok, %{content: {30, :day}, unconfirmed: []}} =
               Retention.put_settings(owner, %{content: {30, :day}}, Retention.settings())
    end

    test "core's writer refusing the write: settings_write_failed, logged without values", %{
      owner: owner
    } do
      # an actor id the history entry refuses
      scope = %{owner | user: %{owner.user | uuid: "not-a-uuid"}}

      log =
        capture_log(fn ->
          assert Retention.put_settings(scope, %{content: {30, :day}}, Retention.settings()) ==
                   {:error, :settings_write_failed}
        end)

      assert log =~ "the periods could not be saved"
      refute log =~ "not-a-uuid"
      assert Settings.get_json_setting(@key) == nil
    end

    test "nothing changed: nothing written", %{admin: admin} do
      loaded = Retention.settings()
      assert {:ok, saved} = Retention.put_settings(admin, %{content: :forever}, loaded)
      assert Map.take(saved, Retention.kinds()) == Retention.defaults()
      assert Settings.get_json_setting(@key) == nil
      assert history() == []
    end

    test "two forms: the second one to save a kind the first changed is stale", %{
      admin: admin,
      owner: owner
    } do
      loaded = Retention.settings()

      assert {:ok, _} = Retention.put_settings(admin, %{requests: {12, :month}}, loaded)

      assert Retention.put_settings(owner, %{requests: {3, :month}}, loaded) ==
               {:error, :stale_retention}

      assert Retention.settings().requests == {12, :month}
      assert length(history()) == 1
    end

    test "two forms changing different kinds: both kept", %{admin: admin, owner: owner} do
      loaded = Retention.settings()

      assert {:ok, _} = Retention.put_settings(admin, %{requests: {12, :month}}, loaded)

      # the content unchanged on the page; the requests as the page loaded them
      assert {:ok, saved} =
               Retention.put_settings(
                 owner,
                 %{content: {30, :day}, requests: :forever},
                 loaded
               )

      assert saved.requests == {12, :month}
      assert saved.content == {30, :day}
    end

    test "setting.changed is recorded with the actor, from the settings page", %{admin: admin} do
      {:ok, _} = Retention.put_settings(admin, %{content: {30, :day}}, Retention.settings())

      assert [entry] = history()
      assert entry.action == "setting.changed"
      assert entry.actor_uuid == admin.user.uuid
      assert entry.permanent
      assert %{"key" => @key, "source" => "settings", "from" => nil} = entry.metadata
      assert Jason.decode!(entry.metadata["to"])["content"] == %{"n" => 30, "unit" => "day"}
    end

    test "the change is broadcast with the document written", %{admin: admin} do
      Settings.Events.subscribe_to_settings()

      {:ok, _} = Retention.put_settings(admin, %{content: {30, :day}}, Retention.settings())

      assert_receive {:setting_changed, @key, %{"content" => %{"n" => 30, "unit" => "day"}}}
    end
  end

  describe "preview/2" do
    test "ai.manage and an Owner may; it names the kinds held at the floor", %{
      admin: admin,
      owner: owner
    } do
      floor = floor_cut(:requests)
      request!(DateTime.add(floor, -60))
      request!(DateTime.add(floor, 60))

      for scope <- [admin, owner] do
        assert {:ok, %{requests: 1, clamped: [:requests]}} =
                 Retention.preview(scope, %{requests: DateTime.add(now(), -60)})

        assert {:ok, %{requests: 1, clamped: []}} = Retention.preview(scope, %{requests: floor})
      end
    end

    test "without ai.manage: forbidden", %{viewer: viewer} do
      assert Retention.preview(viewer, %{requests: floor_cut(:requests)}) == {:error, :forbidden}
      assert Retention.preview(viewer, %{}) == {:error, :forbidden}
      assert Retention.preview(nil, %{content: floor_cut(:content)}) == {:error, :forbidden}
    end

    test "a boundary in the future is refused", %{admin: admin} do
      assert Retention.preview(admin, %{content: DateTime.add(now(), 60)}) ==
               {:error, {:cutoff_in_future, :content}}
    end
  end

  describe "run_now/2" do
    setup do
      start_oban()
      :ok
    end

    test "ai.manage queues a manual job with the boundaries and the actor", %{admin: admin} do
      cutoffs = %{
        requests: floor_cut(:requests),
        content: floor_cut(:content),
        guard_events: floor_cut(:guard_events)
      }

      assert {:ok, %Oban.Job{args: args}} = Retention.run_now(admin, cutoffs)
      assert args["mode"] == "manual"
      assert args["actor_uuid"] == admin.user.uuid

      for {kind, at} <- cutoffs do
        assert {:ok, ^at, 0} = DateTime.from_iso8601(args["cutoffs"][Atom.to_string(kind)])
      end
    end

    test "an Owner without the permission may", %{owner: owner} do
      assert {:ok, %Oban.Job{}} = Retention.run_now(owner, %{content: floor_cut(:content)})
    end

    test "no kind chosen: nothing_to_run, nothing queued", %{admin: admin} do
      assert Retention.run_now(admin, %{}) == {:error, :nothing_to_run}
      assert Retention.run_now(admin, %{requests: nil, content: nil}) == {:error, :nothing_to_run}
      assert jobs() == []
    end

    test "without ai.manage: forbidden, nothing queued", %{viewer: viewer} do
      assert Retention.run_now(viewer, %{requests: floor_cut(:requests)}) == {:error, :forbidden}
      assert Retention.run_now(nil, %{}) == {:error, :forbidden}
      assert jobs() == []
    end

    test "a second run while one is queued: prune_running", %{admin: admin, owner: owner} do
      assert {:ok, _job} = Retention.run_now(admin, %{requests: floor_cut(:requests)})

      assert Retention.run_now(owner, %{content: floor_cut(:content)}) ==
               {:error, :prune_running}

      assert length(jobs()) == 1
    end

    test "the module off: module_disabled, nothing queued", %{admin: admin, owner: owner} do
      PhoenixKitAI.disable_system()

      for scope <- [admin, owner] do
        assert Retention.run_now(scope, %{requests: floor_cut(:requests)}) ==
                 {:error, :module_disabled}
      end

      assert jobs() == []
    end

    test "a forged boundary inside the month is held at the floor", %{admin: admin} do
      assert {:ok, %Oban.Job{args: %{"cutoffs" => cutoffs}}} =
               Retention.run_now(admin, %{
                 requests: DateTime.add(now(), -60),
                 content: DateTime.add(now(), -60)
               })

      {:ok, requests, 0} = DateTime.from_iso8601(cutoffs["requests"])
      {:ok, content, 0} = DateTime.from_iso8601(cutoffs["content"])
      assert DateTime.compare(requests, Retention.floor(:requests)) != :gt
      assert DateTime.compare(content, Retention.floor(:content)) != :gt
      assert cutoffs["guard_events"] == nil
    end

    test "a boundary in the future or not a moment: refused, nothing queued", %{admin: admin} do
      assert Retention.run_now(admin, %{guard_events: DateTime.add(now(), 60)}) ==
               {:error, {:cutoff_in_future, :guard_events}}

      assert Retention.run_now(admin, %{requests: "2020-01-01T00:00:00Z"}) ==
               {:error, {:invalid_cutoff, :requests}}

      assert jobs() == []
    end
  end

  describe "run_now/2 without a queue" do
    test "a job that cannot be inserted: enqueue_failed, logged", %{admin: admin} do
      log =
        capture_log(fn ->
          assert Retention.run_now(admin, %{requests: floor_cut(:requests)}) ==
                   {:error, :enqueue_failed}
        end)

      assert log =~ "the cleanup could not be queued"
    end
  end

  describe "shorter?/4" do
    @now ~U[2026-10-25 12:00:00Z]

    test "the new boundary later today than the saved one is shorter" do
      assert Retention.shorter?(:requests, {3, :month}, :forever, @now)
      assert Retention.shorter?(:requests, {3, :month}, {1, :year}, @now)
      assert Retention.shorter?(:requests, {30, :day}, {3, :month}, @now)
      refute Retention.shorter?(:requests, {1, :year}, {3, :month}, @now)
      refute Retention.shorter?(:requests, :forever, {3, :month}, @now)
      refute Retention.shorter?(:requests, :forever, :forever, @now)
    end

    test "across units: 12 months and 1 year are equal, so shorter; 400 days is not" do
      assert Retention.shorter?(:requests, {12, :month}, {1, :year}, @now)
      assert Retention.shorter?(:requests, {1, :year}, {12, :month}, @now)
      refute Retention.shorter?(:requests, {400, :day}, {1, :year}, @now)
      assert Retention.shorter?(:requests, {300, :day}, {1, :year}, @now)
    end

    test "in doubt: shorter" do
      assert Retention.shorter?(:content, {3, :month}, {0, :day}, @now)
      assert Retention.shorter?(:content, {3, :week}, {3, :month}, @now)
    end
  end

  describe "warnings/4" do
    @now ~U[2026-10-25 12:00:00Z]

    test "journal rows under 3 months: previous months deleted" do
      assert :previous_months_deleted in Retention.warnings(:requests, {2, :month}, @now)
      assert :previous_months_deleted in Retention.warnings(:requests, {89, :day}, @now)
      refute :previous_months_deleted in Retention.warnings(:requests, {3, :month}, @now)
      refute :previous_months_deleted in Retention.warnings(:requests, {1, :year}, @now)
      refute :previous_months_deleted in Retention.warnings(:guard_events, {2, :month}, @now)
      refute :previous_months_deleted in Retention.warnings(:content, {2, :month}, @now)
    end

    test "any kind under 30 days: short windows" do
      for kind <- Retention.kinds() do
        assert :short_windows in Retention.warnings(kind, {29, :day}, @now, {29, :day})
        refute :short_windows in Retention.warnings(kind, {30, :day}, @now, {30, :day})
        refute :short_windows in Retention.warnings(kind, {1, :month}, @now, {1, :month})
      end
    end

    test "guard events under 3 months: their history deleted" do
      assert :guard_history_deleted in Retention.warnings(:guard_events, {2, :month}, @now)
      refute :guard_history_deleted in Retention.warnings(:guard_events, {3, :month}, @now)
      refute :guard_history_deleted in Retention.warnings(:requests, {2, :month}, @now)
    end

    test "content kept longer than its rows: it lives as long as the row" do
      assert Retention.warnings(:content, :forever, @now, {3, :month}) == [:content_outlives_row]

      assert Retention.warnings(:content, {1, :year}, @now, {3, :month}) == [
               :content_outlives_row
             ]

      assert Retention.warnings(:content, {3, :month}, @now, {3, :month}) == []
      assert Retention.warnings(:content, {1, :month}, @now, {3, :month}) == []
      assert Retention.warnings(:content, :forever, @now, :forever) == []
      assert Retention.warnings(:content, {1, :year}, @now) == []
    end

    test "forever and an invalid period: none" do
      for kind <- Retention.kinds(), period <- [:forever, {0, :day}, {3, :week}] do
        assert Retention.warnings(kind, period, @now) == []
      end
    end

    test "the order: the rows' warnings, then the windows" do
      assert Retention.warnings(:requests, {7, :day}, @now) ==
               [:previous_months_deleted, :short_windows]

      assert Retention.warnings(:guard_events, {7, :day}, @now) ==
               [:short_windows, :guard_history_deleted]
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
end
