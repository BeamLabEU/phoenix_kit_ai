defmodule PhoenixKitAI.Web.EndpointsTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the endpoints list with the seeded endpoint", %{conn: conn} do
      fixture_endpoint(name: "Visible Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      assert html =~ "Visible Endpoint"
    end

    test "renders the empty/setup state with no endpoints", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      # The LiveView swaps to the "setup" tab when there are no
      # endpoints. Either the setup copy or the empty endpoints heading
      # should be visible — assert against actual page content rather
      # than a tautology like `is_binary(html)`.
      assert html =~ ~r/setup|No endpoints/i
    end

    test "endpoint with deleted integration_uuid renders 'Integration missing' badge",
         %{conn: conn} do
      # Regression: the list previously showed only the `enabled`
      # badge ("Active") regardless of integration health, so an
      # endpoint pinned to a deleted integration looked fine at a
      # glance. The connection_status map (loaded once per render
      # to avoid an N+1 of `Integrations.connected?/1`) now drives
      # a per-endpoint health badge alongside the enabled badge.
      orphaned_uuid = "01234567-89ab-7def-8000-000000010001"

      _endpoint =
        fixture_endpoint(
          name: "Orphan Endpoint",
          integration_uuid: orphaned_uuid,
          enabled: true
        )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      assert html =~ "Orphan Endpoint"
      assert html =~ "Integration missing"
      # `enabled` badge stays — `enabled` is config, integration
      # health is orthogonal. Both render so the operator sees
      # "Active config, but connectivity is broken."
      assert html =~ "Active"
    end

    test "endpoint with no integration_uuid renders 'No integration' badge",
         %{conn: conn} do
      _endpoint = fixture_endpoint(name: "Unwired Endpoint", integration_uuid: nil)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      assert html =~ "No integration"
    end

    test "endpoint with a connected integration_uuid renders no health badge",
         %{conn: conn} do
      # Healthy: integration exists AND status is "connected". No
      # extra health badge — the enabled badge ("Active") alone is
      # sufficient signal.
      %{uuid: integration_uuid} =
        seed_openrouter_connection(
          "live-#{System.unique_integer([:positive])}",
          data: %{"api_key" => "sk-live", "status" => "connected"}
        )

      _endpoint =
        fixture_endpoint(name: "Healthy Endpoint", integration_uuid: integration_uuid)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      assert html =~ "Healthy Endpoint"
      refute html =~ "Integration missing"
      refute html =~ "Integration error"
      refute html =~ "Not connected"
      refute html =~ "No integration"
    end

    test "card shows the integration name + masked api_key for healthy endpoints",
         %{conn: conn} do
      # The card's second row surfaces which integration the endpoint
      # resolves through and a partial view of the credential — first
      # 8 + last 4 characters joined by `…`. Identifies the OpenRouter
      # prefix and the unique suffix without leaking the full key.
      connection_name = "card-display-#{System.unique_integer([:positive])}"

      %{uuid: integration_uuid} =
        seed_openrouter_connection(
          connection_name,
          data: %{"api_key" => "sk-or-v1-abcdefghijklmnop", "status" => "connected"}
        )

      _endpoint =
        fixture_endpoint(name: "Card Display", integration_uuid: integration_uuid)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      # Integration name is shown verbatim.
      assert html =~ connection_name
      # Masked api_key — first 8 (`sk-or-v1`) + last 4 (`mnop`).
      assert html =~ "sk-or-v1…mnop"
      # The full key never reaches the rendered HTML.
      refute html =~ "sk-or-v1-abcdefghijklmnop"
    end

    test "card shows 'Deleted' for orphaned endpoints",
         %{conn: conn} do
      orphaned_uuid = "01234567-89ab-7def-8000-000000010001"

      _endpoint =
        fixture_endpoint(name: "Orphan Card", integration_uuid: orphaned_uuid)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      assert html =~ "Orphan Card"
      assert html =~ "Deleted"
    end

    test "card shows 'none' when integration_uuid is nil",
         %{conn: conn} do
      _endpoint = fixture_endpoint(name: "Unwired Card", integration_uuid: nil)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      assert html =~ "Unwired Card"
      # The integration field falls back to "none" italics.
      assert html =~ ~r/Integration:.*none/s
    end
  end

  describe "toggle_endpoint" do
    test "flipping enabled persists, surfaces a flash, and emits an activity row",
         %{conn: conn} do
      # Inject a scope so the LV's `actor_opts/1` threads `actor_uuid`
      # through to the activity log. Without this the test couldn't
      # distinguish a working actor-threading from a regression that
      # silently drops the keyword arg.
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      endpoint = fixture_endpoint(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("#endpoint-tbl-menu-#{endpoint.uuid} button[phx-click='toggle_endpoint']")
        |> render_click()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      refute reloaded.enabled
      assert html =~ "Endpoint disabled"

      # Pin every threaded opt — `actor_uuid` proves the LV passed
      # `actor_opts(socket)` through; `metadata.name` proves the
      # log helper extracted the resource correctly; `actor_role`
      # confirms the role argument survived.
      assert_activity_logged(
        "endpoint.disabled",
        resource_uuid: endpoint.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => endpoint.name,
          "actor_role" => "user"
        }
      )
    end
  end

  describe "delete_endpoint" do
    test "removes the row, flashes success, and logs `endpoint.deleted`", %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      endpoint = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("#endpoint-tbl-menu-#{endpoint.uuid} button[phx-click='delete_endpoint']")
        |> render_click()

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
      assert html =~ "Endpoint deleted"

      assert_activity_logged(
        "endpoint.deleted",
        resource_uuid: endpoint.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => endpoint.name,
          "actor_role" => "user"
        }
      )
    end

    test "delete button declares phx-disable-with so a slow delete can't be double-clicked",
         %{conn: conn} do
      _endpoint = fixture_endpoint()

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      # Pin the C5 fix from the 2026-04-26 re-validation pass — matches
      # the canonical attribute regex used elsewhere in the suite.
      assert html =~ ~r/phx-click="delete_endpoint"[^>]+phx-disable-with/
    end
  end

  describe "reorder_endpoints" do
    test "drag-to-reorder rewrites sort_order, flashes ok, and logs `endpoint.reordered`",
         %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      a = fixture_endpoint(name: "Drag A")
      b = fixture_endpoint(name: "Drag B")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=sort_order&dir=asc")

      # Simulate the SortableGrid hook's drop event — the JS hook sends
      # `ordered_ids` (new order) + `moved_id` (the row that was
      # dragged). Pin this entry point because a regression in the
      # phx-hook attrs would silently 404 the drop event server-side.
      render_hook(view, "reorder_endpoints", %{
        "ordered_ids" => [b.uuid, a.uuid],
        "moved_id" => b.uuid
      })

      assert PhoenixKitAI.get_endpoint(b.uuid).sort_order == 1
      assert PhoenixKitAI.get_endpoint(a.uuid).sort_order == 2

      assert_activity_logged("endpoint.reordered",
        resource_uuid: b.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{"count" => 2, "actor_role" => "user"}
      )
    end

    test "Manual sort_order option renders in the sort dropdown", %{conn: conn} do
      fixture_endpoint(name: "Sort Manual A")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      # Pin the gettext-wrapped Manual label in the sort selector — a
      # regression that drops the option (or breaks extraction) is
      # invisible without this assertion.
      assert html =~ ~s(value="sort_order">Manual)
    end

    test "oversized payload flashes the error message", %{conn: conn} do
      _ = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=sort_order&dir=asc")

      oversized = for _ <- 1..501, do: Ecto.UUID.generate()

      html =
        render_hook(view, "reorder_endpoints", %{
          "ordered_ids" => oversized,
          "moved_id" => List.first(oversized)
        })

      assert html =~ "Too many endpoints to reorder at once."
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages and logs at :debug", %{conn: conn} do
      # Lift the global Logger level to :debug for the duration of this
      # test — test config sets `level: :warning` which filters debug
      # messages BEFORE `capture_log` sees them. The `[level: :debug]`
      # opt on capture_log is the handler-level filter, not the global
      # one. Per workspace AGENTS.md "Logger.level must be lifted".
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, :unknown_msg_from_another_module)
          send(view.pid, {:something_we_dont_care_about, %{}, %{}})

          # Render again — this is the LV's flush of pending messages.
          # If the catch-all is missing, this round-trip surfaces
          # FunctionClauseError. The `=~` assertion below proves the
          # page actually rendered (vs. is_binary which is true for any
          # error page too) AND that handle_info didn't break the LV.
          html = render(view)
          assert html =~ "AI Endpoints"
        end)

      # Pin the catch-all's Logger.debug — proves this branch fired
      # rather than the LV silently swallowing the message.
      assert log =~ "[PhoenixKitAI.Web.Endpoints] unhandled handle_info"
    end
  end
end
