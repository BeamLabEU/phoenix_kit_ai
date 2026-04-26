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

  describe "send button" do
    test "declares phx-disable-with so a slow send can't be double-submitted",
         %{conn: conn} do
      _endpoint = fixture_endpoint(name: "Playground Endpoint")
      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")

      # The submit button lives inside `<form phx-submit="send">` and
      # gets `phx-disable-with` from the C5 fix in the 2026-04-26
      # re-validation pass.
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      assert is_binary(render(view))
    end
  end
end
