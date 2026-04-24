defmodule PhoenixKitAI.Web.PlaygroundTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the playground UI", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      # Playground page title or heading is locale-dependent; just
      # confirm we rendered SOMETHING without crashing.
      assert is_binary(html)
      assert byte_size(html) > 100
    end

    test "pre-populates the endpoint list from the DB", %{conn: conn} do
      endpoint = fixture_endpoint(name: "Playground Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      assert html =~ "Playground Endpoint" or html =~ endpoint.uuid
    end
  end
end
