defmodule PhoenixKitAI.Web.EndpointFormTest do
  use PhoenixKitAI.LiveCase

  describe "new" do
    test "renders the create form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")
      assert html =~ "Create Endpoint" or html =~ "Endpoint"
    end
  end

  describe "edit" do
    test "renders the edit form for an existing endpoint", %{conn: conn} do
      endpoint = fixture_endpoint(name: "Editable")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      assert html =~ "Editable"
    end

    test "redirects with an error flash when the endpoint doesn't exist", %{conn: conn} do
      missing_uuid = "01234567-89ab-7def-8000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/ai/endpoints/#{missing_uuid}/edit")

      assert flash["error"] =~ "Endpoint not found"
    end
  end
end
