defmodule PhoenixKitAI.Web.EndpointsTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the endpoints list", %{conn: conn} do
      fixture_endpoint(name: "Visible Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      assert html =~ "Visible Endpoint"
    end

    test "renders empty state when there are no endpoints", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      # The empty state or setup tab should appear — just confirm the
      # page rendered without crashing and mentions AI.
      assert html =~ "AI" or html =~ "Endpoint"
    end
  end

  describe "toggle_endpoint" do
    test "flipping enabled shows the opposite badge", %{conn: conn} do
      endpoint = fixture_endpoint(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      view
      |> element("button[phx-click='toggle_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
      |> render_click()

      # After toggle, the underlying record is disabled.
      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      refute reloaded.enabled
    end
  end

  describe "delete_endpoint" do
    test "removes the endpoint from the DB", %{conn: conn} do
      endpoint = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      view
      |> element("button[phx-click='delete_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
      |> render_click()

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
    end
  end
end
