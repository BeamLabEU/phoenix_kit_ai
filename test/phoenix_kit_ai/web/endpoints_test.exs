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
  end

  describe "toggle_endpoint" do
    test "flipping enabled persists, surfaces a flash, and emits an activity row",
         %{conn: conn} do
      endpoint = fixture_endpoint(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("button[phx-click='toggle_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
        |> render_click()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      refute reloaded.enabled
      assert html =~ "Endpoint disabled"

      assert_activity_logged("endpoint.disabled", resource_uuid: endpoint.uuid)
    end
  end

  describe "delete_endpoint" do
    test "removes the row, flashes success, and logs `endpoint.deleted`", %{conn: conn} do
      endpoint = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("button[phx-click='delete_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
        |> render_click()

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
      assert html =~ "Endpoint deleted"

      assert_activity_logged("endpoint.deleted", resource_uuid: endpoint.uuid)
    end
  end
end
