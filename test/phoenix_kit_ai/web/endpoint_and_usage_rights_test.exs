defmodule PhoenixKitAI.Web.EndpointAndUsageRightsTest do
  @moduledoc """
  `ai.view_usage` (the Usage tab: every request with its prompt and
  response) and `ai.manage_endpoints` (creating, editing, enabling,
  reordering and deleting endpoints). The base `ai` key still lists the
  endpoints. Each page checks at mount, each event again against the scope
  as it is now; the stored legacy API key is never sent in clear; and the
  one-time backfill carries roles that held `ai` across the split.
  """

  use PhoenixKitAI.LiveCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Role, Roles}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @usage_flag "ai_view_usage_backfilled"
  @endpoints_flag "ai_manage_endpoints_backfilled"

  setup do
    :ok = ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)
    :ok
  end

  defp as(conn, permissions), do: put_test_scope(conn, scope_with(permissions))

  # Swap the mounted page's scope — what core's live scope refresh does when
  # a role loses a grant while the page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)
  end

  defp request_fixture(endpoint) do
    {:ok, request} =
      PhoenixKitAI.create_request(%{
        endpoint_uuid: endpoint.uuid,
        endpoint_name: endpoint.name,
        model: "secret-model",
        request_type: "chat",
        status: "success"
      })

    request
  end

  describe "the Usage tab" do
    test "the tab carries ai.view_usage, and the page refuses every other key set",
         %{conn: conn} do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_usage))
      assert tab.permission == "ai.view_usage"

      # Every AI key but the one: the page itself must refuse, not the tab.
      others = ["ai", "ai.manage", "ai.manage_endpoints"]

      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(as(conn, others), "/en/admin/ai/usage")

      assert error =~ "permission"
    end

    test "the base key alone is refused", %{conn: conn} do
      request_fixture(fixture_endpoint())

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(as(conn, ["ai"]), "/en/admin/ai/usage")

      assert to =~ "/admin/ai/endpoints"
      assert flash["error"] =~ "permission"
    end

    test "a holder of ai.view_usage opens it", %{conn: conn} do
      request_fixture(fixture_endpoint())

      {:ok, _view, html} = live(as(conn, ["ai", "ai.view_usage"]), "/en/admin/ai/usage")
      assert html =~ "secret-model"
    end

    test "a revoked key stops the live reload and leaves the tab", %{conn: conn} do
      request_fixture(fixture_endpoint())

      {:ok, view, html} = live(as(conn, ["ai", "ai.view_usage"]), "/en/admin/ai/usage")
      assert html =~ "secret-model"

      swap_scope(view, scope_with(["ai"]))
      send(view.pid, :refresh_usage)

      assert {path, flash} = assert_redirect(view)
      assert path =~ "/admin/ai/endpoints"
      assert flash["error"] =~ "permission"
    end

    test "a revoke through core's scope refresh closes the open request and leaves the tab",
         %{conn: conn} do
      request = request_fixture(fixture_endpoint())

      # The first user registered becomes the Owner, who holds every key.
      _owner = Fixtures.user_fixture()
      user = Fixtures.user_fixture()

      {:ok, role} =
        Roles.create_role(%{name: "Usage #{System.unique_integer([:positive])}"})

      {:ok, _} = Roles.assign_role(user, role.name)
      :ok = Permissions.set_permissions(role.uuid, ["ai", "ai.view_usage"])

      # Mounted under core's own scope hook (see the test router), so the
      # revoke below reaches the page the way it does in production.
      conn = put_test_scope(conn, Scope.for_user(user))
      {:ok, view, _html} = live(conn, "/core-scope/admin/ai/usage")

      render_click(view, "show_request_details", %{"uuid" => request.uuid})
      assert has_element?(view, "#ai-request-details")

      :ok = Permissions.revoke_permission(role.uuid, "ai.view_usage")

      assert {path, flash} = assert_redirect(view)
      assert path =~ "/admin/ai/endpoints"
      assert flash["error"] =~ "permission"
    end

    test "loading and opening requests re-check the key", %{conn: conn} do
      endpoint = fixture_endpoint()
      request = request_fixture(endpoint)

      {:ok, view, _html} = live(as(conn, ["ai", "ai.view_usage"]), "/en/admin/ai/usage")
      swap_scope(view, scope_with(["ai"]))

      html = render_click(view, "show_request_details", %{"uuid" => request.uuid})
      assert html =~ "permission"
      refute has_element?(view, "#ai-request-details")

      assert render_click(view, "load_more_requests", %{}) =~ "permission"
    end
  end

  describe "endpoint management" do
    test "the base key lists endpoints but offers no change", %{conn: conn} do
      endpoint = fixture_endpoint()

      {:ok, _view, html} = live(as(conn, ["ai"]), "/en/admin/ai/endpoints")

      assert html =~ endpoint.name
      refute html =~ "/endpoints/new"
      refute html =~ "/endpoints/#{endpoint.uuid}/edit"
      refute html =~ "delete_endpoint"
    end

    test "the base key cannot open the new or edit form", %{conn: conn} do
      endpoint = fixture_endpoint()

      for path <- ["/en/admin/ai/endpoints/new", "/en/admin/ai/endpoints/#{endpoint.uuid}/edit"] do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} = live(as(conn, ["ai"]), path)
        assert to =~ "/admin/ai/endpoints"
        assert flash["error"] =~ "permission"
      end
    end

    test "crafted toggle, delete and reorder events change nothing", %{conn: conn} do
      a = fixture_endpoint()
      b = fixture_endpoint()
      before = Enum.map([a, b], &PhoenixKitAI.get_endpoint(&1.uuid).sort_order)

      {:ok, view, _html} = live(as(conn, ["ai"]), "/en/admin/ai/endpoints")

      assert render_click(view, "toggle_endpoint", %{"uuid" => a.uuid}) =~ "permission"
      assert render_click(view, "delete_endpoint", %{"uuid" => a.uuid}) =~ "permission"

      assert render_click(view, "reorder_endpoints", %{"ordered_ids" => [b.uuid, a.uuid]}) =~
               "permission"

      reloaded = PhoenixKitAI.get_endpoint(a.uuid)
      assert reloaded.enabled == a.enabled
      assert Enum.map([a, b], &PhoenixKitAI.get_endpoint(&1.uuid).sort_order) == before
    end

    test "a holder of ai.manage_endpoints deletes and opens the forms", %{conn: conn} do
      endpoint = fixture_endpoint()
      conn = as(conn, ["ai", "ai.manage_endpoints"])

      {:ok, _view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      {:ok, _view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints")
      assert html =~ "/endpoints/new"

      render_click(view, "delete_endpoint", %{"uuid" => endpoint.uuid})
      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
    end

    test "saving the form re-checks the key", %{conn: conn} do
      endpoint = fixture_endpoint()

      {:ok, view, _html} =
        live(
          as(conn, ["ai", "ai.manage_endpoints"]),
          "/en/admin/ai/endpoints/#{endpoint.uuid}/edit"
        )

      swap_scope(view, scope_with(["ai"]))

      html =
        render_submit(view, "save", %{"endpoint" => %{"name" => "Renamed by a crafted save"}})

      assert html =~ "permission"
      assert PhoenixKitAI.get_endpoint(endpoint.uuid).name == endpoint.name
    end
  end

  describe "the integration key on the endpoint list" do
    test "shows a base ai holder at most its last 4 characters", %{conn: conn} do
      key = "sk-or-v1-verysecretmiddle-WXYZ"

      %{uuid: integration_uuid} =
        seed_openrouter_connection("mask-#{System.unique_integer([:positive])}",
          data: %{"api_key" => key}
        )

      fixture_endpoint(integration_uuid: integration_uuid)

      {:ok, _view, html} = live(as(conn, ["ai"]), "/en/admin/ai/endpoints")

      assert html =~ "•••WXYZ"
      refute html =~ "sk-or-v1"
      refute html =~ "verysecret"
    end
  end

  describe "the legacy API key" do
    test "is shown masked, never in clear", %{conn: conn} do
      key = "sk-or-v1-abcdefghijklmnopqrstuvwxyz-1234"
      endpoint = fixture_endpoint(api_key: key, integration_uuid: nil)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert html =~ "Legacy API key (recovery)"
      refute html =~ key
      assert html =~ PhoenixKitAI.Endpoint.masked_api_key(key)
    end
  end

  describe "migrate_legacy/0 — the sub-permission backfill" do
    defp role!(name) do
      TestRepo.insert!(%Role{
        name: "#{name} #{System.unique_integer([:positive])}",
        is_system_role: false
      })
    end

    defp clear_flags do
      for flag <- [@usage_flag, @endpoints_flag], do: Settings.delete_setting(flag)
    end

    test "a role holding ai gets both keys once; later roles do not" do
      clear_flags()
      holder = role!("Support")
      outsider = role!("Outsider")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "ai", nil)

      assert {:ok, %{permissions_backfill: :ok}} = PhoenixKitAI.migrate_legacy()

      granted = Permissions.get_permissions_for_role(holder.uuid)
      assert "ai.view_usage" in granted
      assert "ai.manage_endpoints" in granted
      assert Permissions.get_permissions_for_role(outsider.uuid) == []
      assert Settings.get_setting(@usage_flag) == "true"
      assert Settings.get_setting(@endpoints_flag) == "true"

      # Granted the base key after the backfill: the narrow meaning.
      late = role!("Late")
      {:ok, _} = Permissions.grant_permission(late.uuid, "ai", nil)
      PhoenixKitAI.migrate_legacy()
      assert Permissions.get_permissions_for_role(late.uuid) == ["ai"]

      # A revoke sticks across the next boot.
      :ok = revoke(holder.uuid, "ai.view_usage")
      PhoenixKitAI.migrate_legacy()
      refute "ai.view_usage" in Permissions.get_permissions_for_role(holder.uuid)
    end

    test "a failed permission lookup leaves the flag unset and grants nothing" do
      clear_flags()
      holder = role!("Support")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "ai", nil)

      broken_lookup = fn -> raise DBConnection.ConnectionError, "lookup failed" end

      assert {:error, {"ai.view_usage", %DBConnection.ConnectionError{}}} =
               PhoenixKitAI.backfill_sub_permission("ai.view_usage", @usage_flag,
                 role_grants: broken_lookup
               )

      assert Settings.get_setting(@usage_flag) != "true"
      refute "ai.view_usage" in Permissions.get_permissions_for_role(holder.uuid)
    end

    test "a failed grant leaves the flag unset, so the next boot retries" do
      clear_flags()
      holder = role!("Support")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "ai", nil)

      failing = fn _role, _key, _by -> {:error, :boom} end

      assert {:error, {"ai.view_usage", failures}} =
               PhoenixKitAI.backfill_sub_permission("ai.view_usage", @usage_flag, grant: failing)

      assert {holder.uuid, {:error, :boom}} in failures

      assert Settings.get_setting(@usage_flag) != "true"
      refute "ai.view_usage" in Permissions.get_permissions_for_role(holder.uuid)

      assert :ok = PhoenixKitAI.backfill_sub_permission("ai.view_usage", @usage_flag)
      assert Settings.get_setting(@usage_flag) == "true"
      assert "ai.view_usage" in Permissions.get_permissions_for_role(holder.uuid)
    end
  end

  defp revoke(role_uuid, key), do: Permissions.revoke_permission(role_uuid, key)
end
