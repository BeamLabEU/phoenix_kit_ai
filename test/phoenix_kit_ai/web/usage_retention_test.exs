defmodule PhoenixKitAI.Web.UsageRetentionTest do
  @moduledoc """
  The "Journal retention" card on AI → Usage: saving the periods (with the
  preview for a shorter one, without it for a longer one), the warnings,
  the rights (none: read only and every event refused; taken away while
  the page is open), the nightly line in each of its states, the cleanup
  by hand (an asynchronous preview, the boundaries of the confirmation
  taken from the page and never from the event, "already running", after
  a preview that timed out), the broadcasts of the two settings, the
  caption of the totals and the notice in a row's details.

  `async: false`: the settings, the site time zone, the Oban instance and
  the table locks are global.
  """

  use PhoenixKitAI.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.{ModuleRegistry, Settings}
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @path "/en/admin/ai/usage"
  @key "ai_journal_retention"
  @last_run_key "ai_journal_retention_last_run"
  @async_ms 5_000

  setup do
    Settings.update_setting("time_zone", "0")
    :ok = ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)

    # the first user is the Owner: made before anyone else
    owner = Fixtures.user_fixture()
    {:ok, owner: owner}
  end

  defp admin(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    {user, role_uuid}
  end

  defp open(conn, user, path \\ @path) do
    {:ok, view, _html} = conn |> put_test_scope(Scope.for_user(user)) |> live(path)
    view
  end

  defp start_oban, do: start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

  defp jobs,
    do: TestRepo.all(from(j in Oban.Job, where: j.worker == "PhoenixKitAI.JournalPruneWorker"))

  defp request!(at, metadata \\ %{"messages" => [%{"content" => "x"}], "task" => "t"}) do
    TestRepo.insert!(%Request{
      model: "m",
      request_type: "chat",
      status: "success",
      metadata: metadata,
      inserted_at: at,
      updated_at: at
    })
  end

  defp long_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.truncate(:second)

  defp save_periods(owner, attrs),
    do: {:ok, _} = Retention.put_settings(Scope.for_user(owner), attrs, Retention.settings())

  # The periods document written as it is: a period changed long ago, or
  # one without its change time.
  defp write_periods!(doc), do: {:ok, _} = Retention.write_settings(doc)

  defp write_last_run!(doc),
    do:
      {:ok, _} =
        Settings.update_json_setting_with_module(@last_run_key, doc, "ai", history: false)

  defp iso(at), do: DateTime.to_iso8601(at)

  defp period_params(kind, n, unit, forever \\ "false"),
    do: %{"retention" => %{kind => %{"n" => n, "unit" => unit, "forever" => forever}}}

  defp run_params(kind, mode, n, unit),
    do: %{"retention_run" => %{kind => %{"mode" => mode, "n" => n, "unit" => unit}}}

  # As a person does it: untick "keep forever" (the number and the unit
  # come alive), then type and save.
  defp submit_period(view, kind, n, unit) do
    untick(view, kind)
    view |> form("#ai-retention-form", period_params(kind, n, unit)) |> render_submit()
  end

  defp change_period(view, kind, n, unit) do
    untick(view, kind)
    view |> form("#ai-retention-form", period_params(kind, n, unit)) |> render_change()
  end

  defp untick(view, kind) do
    view
    |> form("#ai-retention-form", %{"retention" => %{kind => %{"forever" => "false"}}})
    |> render_change()
  end

  # Choose "older than…" (the number and the unit appear), then count.
  defp count_run(view, kind, n, unit) do
    view
    |> form("#ai-retention-run-form", %{"retention_run" => %{kind => %{"mode" => "value"}}})
    |> render_change()

    view |> form("#ai-retention-run-form", run_params(kind, "value", n, unit)) |> render_submit()
  end

  describe "without ai.manage" do
    test "the card is read only: the periods, no forms", %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {12, :month}})
      {user, _role} = admin(["ai"])
      view = open(conn, user)

      assert has_element?(view, "#ai-retention-read-only")
      assert has_element?(view, "#ai-retention-periods [data-period=requests]", "12 months")
      assert has_element?(view, "#ai-retention-periods [data-period=content]", "Kept forever")
      refute has_element?(view, "#ai-retention-form")
      refute has_element?(view, "#ai-retention-run-form")
    end

    test "every event that acts is refused, also without any permission", %{conn: conn} do
      start_oban()
      request!(long_ago(90))

      for keys <- [[], ["ai"]] do
        {user, _role} = admin(keys)
        view = open(conn, user)

        for {event, params} <- [
              {"retention_save", period_params("requests", "1", "day")},
              {"retention_save_confirm", %{}},
              {"retention_run_preview", run_params("requests", "value", "1", "day")},
              {"retention_run_confirm", %{"cutoffs" => %{"requests" => iso(long_ago(1))}}}
            ] do
          assert render_hook(view, event, params) =~ "You are not allowed to do this",
                 "#{event} was not refused"
        end
      end

      assert Settings.get_json_setting(@key) == nil
      assert jobs() == []
    end

    test "the form's own events read no rights and change nothing stored", %{conn: conn} do
      start_oban()
      {user, _role} = admin(["ai"])
      view = open(conn, user)

      for {event, params} <- [
            {"retention_validate", period_params("requests", "1", "day")},
            {"retention_save_cancel", %{}},
            {"retention_run_change", run_params("requests", "value", "1", "day")},
            {"retention_run_open", %{}},
            {"retention_run_cancel", %{}}
          ] do
        refute render_hook(view, event, params) =~ "You are not allowed to do this", event
      end

      assert has_element?(view, "#ai-retention-read-only")
      assert Settings.get_json_setting(@key) == nil
      assert jobs() == []
    end

    test "a permission taken away while the page is open is refused at the next event",
         %{conn: conn} do
      {user, role_uuid} = admin(["ai", "ai.manage"])
      view = open(conn, user)
      assert has_element?(view, "#ai-retention-form")

      :ok = Permissions.set_permissions(role_uuid, ["ai"])

      html = render_hook(view, "retention_save", period_params("requests", "24", "month"))
      assert html =~ "You are not allowed to do this"
      refute has_element?(view, "#ai-retention-form")
      assert Settings.get_json_setting(@key) == nil
    end
  end

  describe "saving the periods" do
    test "a longer period is saved at once, without a preview", %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {3, :month}})
      view = open(conn, owner)

      submit_period(view, "requests", "12", "month")

      html = render(view)
      refute html =~ "Save a shorter period"
      assert html =~ "Retention periods saved"
      assert Retention.settings().requests == {12, :month}
    end

    test "a shorter period goes through the preview: numbers, the floor, the first night",
         %{conn: conn, owner: owner} do
      floor = Retention.floor(:requests)
      request!(DateTime.add(floor, -3600))
      request!(DateTime.add(floor, -7200))
      request!(DateTime.utc_now() |> DateTime.truncate(:second))
      view = open(conn, owner)

      html =
        submit_period(view, "requests", "5", "day")

      assert html =~ "Counting…"
      assert Retention.settings().requests == :forever

      html = render_async(view, @async_ms)
      assert html =~ "2 journal entries older than"
      assert html =~ "not deleted — the spend limits read them"
      assert html =~ "The first nightly cleanup runs no earlier than"

      render_click(view, "retention_save_confirm", %{})
      assert Retention.settings().requests == {5, :day}
      assert has_element?(view, "#ai-retention-status-first-requests", "runs no earlier than")
    end

    test "cancelling the preview saves nothing", %{conn: conn, owner: owner} do
      view = open(conn, owner)
      submit_period(view, "content", "3", "month")
      render_async(view, @async_ms)
      render_click(view, "retention_save_cancel", %{})
      assert Settings.get_json_setting(@key) == nil
    end

    test "a number that is not a whole number in range is a form error", %{
      conn: conn,
      owner: owner
    } do
      view = open(conn, owner)

      for {n, message} <- [
            {"abc", "Enter a whole number"},
            {"2.5", "Enter a whole number"},
            {"", "Enter a whole number"},
            {"0", "A whole number from 1 to 1200"},
            {"1201", "A whole number from 1 to 1200"}
          ] do
        change_period(view, "requests", n, "month")
        assert has_element?(view, "[data-retention-error=requests]", message), n

        submit_period(view, "requests", n, "month")
        assert Settings.get_json_setting(@key) == nil
      end
    end

    test "the warnings under the field", %{conn: conn, owner: owner} do
      view = open(conn, owner)
      untick(view, "requests")
      untick(view, "guard_events")

      view
      |> form("#ai-retention-form", %{
        "retention" => %{
          "requests" => %{"n" => "2", "unit" => "month", "forever" => "false"},
          "content" => %{"forever" => "true"},
          "guard_events" => %{"n" => "20", "unit" => "day", "forever" => "false"}
        }
      })
      |> render_change()

      assert has_element?(
               view,
               "#ai-retention-requests [data-retention-warning=previous_months_deleted]",
               "nothing to check the provider"
             )

      refute has_element?(view, "#ai-retention-requests [data-retention-warning=short_windows]")

      assert has_element?(
               view,
               "#ai-retention-guard_events [data-retention-warning=short_windows]",
               "30-day windows"
             )

      assert has_element?(
               view,
               "#ai-retention-guard_events [data-retention-warning=guard_history_deleted]",
               "Flags and forgiven limits before"
             )

      assert has_element?(
               view,
               "#ai-retention-content [data-retention-warning=content_outlives_row]",
               "live as long as its entry does"
             )
    end

    test "a second open page shows the new periods after a save on the first",
         %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {3, :month}})
      first = open(conn, owner)
      {user, _role} = admin(["ai"])
      second = open(build_conn(), user)
      assert has_element?(second, "[data-period=requests]", "3 months")

      submit_period(first, "requests", "12", "month")

      assert has_element?(second, "[data-period=requests]", "12 months")
    end

    test "a page with something typed is told when another save replaces it",
         %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {3, :month}})
      first = open(conn, owner)
      {user, _role} = admin(["ai", "ai.manage"])
      second = open(build_conn(), user)
      untouched = open(build_conn(), user)

      change_period(second, "content", "45", "day")
      submit_period(first, "requests", "12", "month")

      assert render(second) =~ "Someone else changed the retention periods"
      assert has_element?(second, "#ai-retention-requests-n[value='12']")
      assert has_element?(second, "#ai-retention-content-forever[checked]")

      # nothing typed there: the new periods, no notice
      refute render(untouched) =~ "Someone else changed the retention periods"
      assert has_element?(untouched, "#ai-retention-requests-n[value='12']")
      # the saving page's own save coming back is no news either
      refute render(first) =~ "Someone else changed the retention periods"
    end

    test "an event naming one kind leaves the others' boxes as they were",
         %{conn: conn, owner: owner} do
      view = open(conn, owner)
      assert has_element?(view, "#ai-retention-content-forever[checked]")
      assert has_element?(view, "#ai-retention-guard_events-forever[checked]")

      render_hook(view, "retention_validate", %{
        "retention" => %{"requests" => %{"forever" => "false"}}
      })

      refute has_element?(view, "#ai-retention-requests-forever[checked]")
      refute has_element?(view, "#ai-retention-requests-n[disabled]")

      for kind <- ~w(content guard_events) do
        assert has_element?(view, "#ai-retention-#{kind}-forever[checked]"), kind
        assert has_element?(view, "#ai-retention-#{kind}-n[disabled]"), kind
        refute has_element?(view, "[data-retention-error=#{kind}]"), kind
      end
    end

    test "a value typed survives a change of the usage filters", %{conn: conn, owner: owner} do
      view = open(conn, owner)
      change_period(view, "requests", "7", "day")

      view |> form("#ai-usage-filters", %{"date" => "30d"}) |> render_change()
      assert_patch(view)

      assert has_element?(view, "#ai-retention-requests-n[value='7']")
      assert has_element?(view, "#ai-retention-requests-unit option[value=day][selected]")
      refute has_element?(view, "#ai-retention-requests-forever[checked]")
    end

    test "a save over a change made since the page loaded is refused as stale",
         %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {3, :month}})
      view = open(conn, owner)

      # Changed behind the page's back: no broadcast reaches it.
      doc = Settings.get_json_setting(@key) |> Map.put("requests", %{"n" => 6, "unit" => "month"})

      TestRepo.update_all(from(s in "phoenix_kit_settings", where: s.key == ^@key),
        set: [value_json: doc]
      )

      html =
        submit_period(view, "requests", "24", "month")

      assert html =~ "changed by someone else; reload the page"
      assert Retention.settings().requests == {6, :month}
    end
  end

  describe "the nightly line" do
    test "everything forever: the cleanup is off", %{conn: conn, owner: owner} do
      view = open(conn, owner)
      assert has_element?(view, "#ai-retention-status-off", "kept forever")
    end

    test "done last night, with what it did and more left", %{conn: conn, owner: owner} do
      write_periods!(%{
        "requests" => %{"n" => 3, "unit" => "month"},
        "changed_at" => %{"requests" => iso(long_ago(5))}
      })

      write_last_run!(%{
        "scheduled" => %{
          "at" => iso(long_ago(0)),
          "status" => "ok",
          "counts" => %{"requests" => 3, "content" => 1, "guard_events" => 2},
          "more_left" => true
        }
      })

      view = open(conn, owner)
      assert has_element?(view, "#ai-retention-status-night", "Last nightly cleanup")
      assert has_element?(view, "#ai-retention-status-night", "3 journal entries deleted")
      assert has_element?(view, "#ai-retention-status-night", "2 guard events deleted")
      assert has_element?(view, "#ai-retention-status-night-more", "More is left")
    end

    test "failed: the date and the class of the error", %{conn: conn, owner: owner} do
      write_periods!(%{
        "requests" => %{"n" => 3, "unit" => "month"},
        "changed_at" => %{"requests" => iso(long_ago(5))}
      })

      write_last_run!(%{
        "scheduled" => %{
          "at" => iso(long_ago(1)),
          "status" => "failed",
          "error" => "query_canceled"
        }
      })

      view = open(conn, owner)
      assert has_element?(view, "#ai-retention-status-night", "The nightly cleanup failed on")
      assert has_element?(view, "#ai-retention-status-night", "query_canceled")
    end

    test "failed by a refusal of the checks: its sentence, not the bare class",
         %{conn: conn, owner: owner} do
      write_periods!(%{
        "requests" => %{"n" => 3, "unit" => "month"},
        "changed_at" => %{"requests" => iso(long_ago(5))}
      })

      write_last_run!(%{
        "scheduled" => %{
          "at" => iso(long_ago(1)),
          "status" => "failed",
          "error" => "foreign_key_blocks"
        },
        "manual" => %{"at" => iso(long_ago(1)), "status" => "failed", "error" => "invalid_args"}
      })

      view = open(conn, owner)

      assert has_element?(
               view,
               "#ai-retention-status-night",
               "would block or spread the deletion"
             )

      refute has_element?(view, "#ai-retention-status-night", "foreign_key_blocks")
      assert has_element?(view, "#ai-retention-status-manual", "arguments could not be read")
    end

    test "a period set and no night run: the crontab hint", %{conn: conn, owner: owner} do
      write_periods!(%{
        "requests" => %{"n" => 3, "unit" => "month"},
        "changed_at" => %{"requests" => iso(long_ago(5))}
      })

      write_last_run!(%{"scheduled" => %{"at" => iso(long_ago(3)), "status" => "ok"}})

      view = open(conn, owner)
      assert has_element?(view, "#ai-retention-status-night", "has not run")
      assert has_element?(view, "#ai-retention-status-night", "PhoenixKitAI.JournalPruneWorker")
      assert has_element?(view, "#ai-retention-status-night", "mix phoenix_kit.update")
    end

    test "a period changed today: its first cleanup is not before tomorrow, no crontab hint",
         %{conn: conn, owner: owner} do
      save_periods(owner, %{guard_events: {2, :year}})
      view = open(conn, owner)

      assert has_element?(view, "#ai-retention-status-first-guard_events", "runs no earlier than")
      refute has_element?(view, "#ai-retention-status-night")
    end

    @tag capture_log: true
    test "a period stored without its change time: save it again", %{conn: conn, owner: owner} do
      write_periods!(%{"content" => %{"n" => 30, "unit" => "day"}})
      view = open(conn, owner)

      assert has_element?(
               view,
               "#ai-retention-status-unconfirmed-content",
               "save the period again"
             )

      assert has_element?(view, "#ai-retention-status-off")

      # saved as the card shows it (unchanged): confirmed, the line goes
      view |> form("#ai-retention-form") |> render_submit()

      assert Retention.settings().unconfirmed == []
      assert Retention.settings().content == :forever
      refute has_element?(view, "#ai-retention-status-unconfirmed-content")
    end

    test "the outcome of a run arrives by the settings broadcast", %{conn: conn, owner: owner} do
      request!(long_ago(2))
      view = open(conn, owner)
      refute has_element?(view, "#ai-retention-status-manual")
      refute has_element?(view, "#ai-usage-retained-since")

      write_last_run!(%{
        "manual" => %{
          "at" => iso(long_ago(0)),
          "status" => "ok",
          "counts" => %{"requests" => 4, "content" => 0, "guard_events" => 0},
          "actor_uuid" => owner.uuid
        }
      })

      assert has_element?(view, "#ai-retention-status-manual", "4 journal entries deleted")
      # the totals follow the stamp's marker, not the last run's counts
      refute has_element?(view, "#ai-usage-retained-since")

      write_last_run!(%{
        "manual" => %{"at" => iso(long_ago(0)), "status" => "ok", "counts" => %{}},
        "rows_deleted_before" => iso(long_ago(1))
      })

      assert has_element?(view, "#ai-retention-status-manual", "0 journal entries deleted")
      assert has_element?(view, "#ai-usage-retained-since", "For the retained period, since")
    end
  end

  describe "cleaning up by hand" do
    setup do
      start_oban()
      floor = Retention.floor(:requests)
      request!(DateTime.add(floor, -3600))
      request!(DateTime.add(floor, -7200))
      {:ok, floor: floor}
    end

    test "count asynchronously, confirm, the job takes the page's boundaries",
         %{conn: conn, owner: owner, floor: floor} do
      view = open(conn, owner)

      html =
        count_run(view, "requests", "5", "day")

      assert html =~ "Counting…"
      assert has_element?(view, "#ai-retention-run-delete[disabled]")

      render_async(view, @async_ms)
      assert has_element?(view, "#ai-retention-run-preview", "2 journal entries older than")
      assert has_element?(view, "#ai-retention-run-preview", "spend limits read them")
      refute has_element?(view, "#ai-retention-run-delete[disabled]")

      view |> element("#ai-retention-run-delete") |> render_click()
      # a forged boundary in the event is ignored: the page's preview counts
      render_hook(view, "retention_run_confirm", %{
        "cutoffs" => %{
          "requests" => iso(DateTime.utc_now()),
          "guard_events" => iso(DateTime.utc_now())
        }
      })

      assert [job] = jobs()
      assert job.args["mode"] == "manual"
      assert job.args["actor_uuid"] == owner.uuid
      assert job.args["cutoffs"]["guard_events"] == nil
      assert job.args["cutoffs"]["content"] == nil
      {:ok, cut, 0} = DateTime.from_iso8601(job.args["cutoffs"]["requests"])
      assert DateTime.compare(cut, floor) == :eq

      assert render(view) =~ "The journal cleanup is queued"
      assert has_element?(view, "#ai-retention-job", "waiting in the queue")
    end

    test "a second run while one is queued: already running", %{conn: conn, owner: owner} do
      view = open(conn, owner)

      for _ <- 1..2 do
        count_run(view, "requests", "5", "day")

        render_async(view, @async_ms)
        view |> element("#ai-retention-run-delete") |> render_click()
        render_click(view, "retention_run_confirm", %{})
      end

      assert render(view) =~ "A journal cleanup is already running"
      assert length(jobs()) == 1
    end

    test "nothing to delete: the delete button stays off", %{conn: conn, owner: owner} do
      view = open(conn, owner)

      count_run(view, "guard_events", "5", "day")

      render_async(view, @async_ms)
      assert has_element?(view, "#ai-retention-run-preview", "0 guard events older than")
      assert has_element?(view, "#ai-retention-run-delete[disabled]")
      render_click(view, "retention_run_open", %{})
      render_click(view, "retention_run_confirm", %{})
      assert jobs() == []
    end

    test "by the saved period", %{conn: conn, owner: owner} do
      save_periods(owner, %{requests: {1, :month}})
      view = open(conn, owner)

      view
      |> form("#ai-retention-run-form", %{
        "retention_run" => %{"requests" => %{"mode" => "saved"}}
      })
      |> render_submit()

      render_async(view, @async_ms)

      assert has_element?(view, "#ai-retention-run-preview", "journal entries older than")
      refute has_element?(view, "#ai-retention-run-preview", "spend limits read them")
    end

    test "a foreign key that would block is shown in the preview", %{conn: conn, owner: owner} do
      TestRepo.query!(
        "CREATE TABLE retention_ui_fk_test (uuid uuid PRIMARY KEY, ref uuid REFERENCES phoenix_kit_ai_requests(uuid) ON DELETE RESTRICT)",
        []
      )

      view = open(conn, owner)

      count_run(view, "requests", "5", "day")

      render_async(view, @async_ms)
      assert has_element?(view, "#ai-retention-run-preview", "retention_ui_fk_test")
      assert has_element?(view, "#ai-retention-run-delete[disabled]")
    end

    test "after a preview that timed out the cleanup can still be confirmed",
         %{conn: conn, owner: owner} do
      view = open(conn, owner)

      with_events_locked(fn ->
        count_run(view, "guard_events", "5", "day")

        render_async(view, @async_ms)
      end)

      assert has_element?(view, "#ai-retention-run-preview", "took too long")
      assert has_element?(view, "#ai-retention-run-preview", "You can still go on")
      refute has_element?(view, "#ai-retention-run-delete[disabled]")

      view |> element("#ai-retention-run-delete") |> render_click()
      render_click(view, "retention_run_confirm", %{})

      assert [job] = jobs()
      {:ok, cut, 0} = DateTime.from_iso8601(job.args["cutoffs"]["guard_events"])
      assert DateTime.compare(cut, Retention.floor(:guard_events)) == :eq
    end

    test "a preview that comes back after the form changed is dropped",
         %{conn: conn, owner: owner} do
      view = open(conn, owner)

      with_events_locked(fn ->
        count_run(view, "guard_events", "5", "day")
        # changed while the count waits for the lock: that count is stale
        view
        |> form("#ai-retention-run-form", %{
          "retention_run" => %{"guard_events" => %{"n" => "6"}}
        })
        |> render_change()

        render_async(view, @async_ms)
      end)

      refute has_element?(view, "#ai-retention-run-preview")
      refute has_element?(view, "#ai-retention-run-delete")
      refute render(view) =~ "took too long"
    end

    test "after a save preview that timed out the period can still be saved",
         %{conn: conn, owner: owner} do
      view = open(conn, owner)

      with_events_locked(fn ->
        submit_period(view, "guard_events", "5", "day")

        render_async(view, @async_ms)
      end)

      assert render(view) =~ "took too long"
      render_click(view, "retention_save_confirm", %{})
      assert Retention.settings().guard_events == {5, :day}
    end
  end

  describe "the totals and the row details" do
    test "all time while nothing can have been deleted; the retained period after",
         %{conn: conn, owner: owner} do
      request!(long_ago(40))
      view = open(conn, owner)
      refute has_element?(view, "#ai-usage-retained-since")

      save_periods(owner, %{requests: {12, :month}})
      view = open(conn, owner)
      assert has_element?(view, "#ai-usage-retained-since", "For the retained period, since")

      fixture_endpoint()
      endpoints = open(conn, owner, "/en/admin/ai/endpoints")
      assert has_element?(endpoints, "#ai-endpoints-retained-since", "since")
    end

    test "a row whose content was removed says so", %{conn: conn, owner: owner} do
      row =
        request!(long_ago(1), %{"task" => "t", "content_pruned_at" => iso(long_ago(0))})

      view = open(conn, owner)
      render_click(view, "show_request_details", %{"uuid" => row.uuid})

      assert has_element?(view, "#ai-request-content-pruned", "removed by the retention period")
    end
  end

  # The guard events table locked from another connection while `fun`
  # runs, with the preview's statement timeout short: the count waits for
  # the lock and gives up.
  defp with_events_locked(fun) do
    previous = Application.get_env(:phoenix_kit_ai, :journal_prune)
    Application.put_env(:phoenix_kit_ai, :journal_prune, preview_timeout_ms: 300)

    config = TestRepo.config()

    {:ok, locker} =
      Postgrex.start_link(
        Keyword.take(config, [:hostname, :port, :username, :password, :database])
      )

    try do
      Postgrex.query!(locker, "BEGIN", [])
      Postgrex.query!(locker, "SET LOCAL lock_timeout = '5s'", [])

      Postgrex.query!(
        locker,
        "LOCK TABLE phoenix_kit_ai_guard_events IN ACCESS EXCLUSIVE MODE",
        []
      )

      fun.()
    after
      Postgrex.query!(locker, "ROLLBACK", [])
      GenServer.stop(locker)

      if previous,
        do: Application.put_env(:phoenix_kit_ai, :journal_prune, previous),
        else: Application.delete_env(:phoenix_kit_ai, :journal_prune)
    end
  end
end
