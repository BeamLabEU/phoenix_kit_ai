defmodule PhoenixKitAI.Web.PlaygroundTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the playground heading + configuration card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      assert html =~ "AI Playground"
      assert html =~ "Configuration"
    end

    test "pre-populates the endpoint dropdown from the DB", %{conn: conn} do
      endpoint = fixture_endpoint(name: "Playground Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      # The endpoint name appears in the <option> within the
      # configuration <select>; assert against the actual rendered
      # name rather than a fallback that hides UI regressions.
      assert html =~ "Playground Endpoint"
      assert html =~ endpoint.uuid
    end
  end

  describe "send with no endpoint selected" do
    test "flashes a translated error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      html = render_click(view, "send", %{})
      assert html =~ "Please select an endpoint"
    end
  end
end
