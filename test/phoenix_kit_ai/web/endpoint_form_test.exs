defmodule PhoenixKitAI.Web.EndpointFormTest do
  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Web.EndpointForm

  describe "new" do
    test "renders the create form with submit button + phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # The submit button must declare phx-disable-with so a slow save
      # can't be double-submitted by accident — this was a HIGH finding
      # in PR #1's review.
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/

      # Page heading and form structure should be present.
      assert html =~ "New AI Endpoint"
      assert html =~ ~s(name="endpoint[name]")
    end
  end

  describe "edit" do
    test "renders the edit form with phx-disable-with on the submit button",
         %{conn: conn} do
      endpoint = fixture_endpoint(name: "Editable")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert html =~ "Editable"
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
    end

    test "redirects with a translated error flash when the endpoint doesn't exist",
         %{conn: conn} do
      missing_uuid = "01234567-89ab-7def-8000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/ai/endpoints/#{missing_uuid}/edit")

      assert flash["error"] =~ "Endpoint not found"
    end
  end

  describe "integration_warning/1" do
    # `save_success_message/2` calls `integration_warning/1` after a
    # successful save and appends the result to the flash. The flash
    # path is hard to drive end-to-end because the form's `provider`
    # is bound to the integration_picker's active_connection assign,
    # not a free-text input. Pinning the helper directly keeps the
    # branches honest.

    test "returns nil for nil/empty provider" do
      assert EndpointForm.integration_warning(%{provider: nil, api_key: nil}) == nil
      assert EndpointForm.integration_warning(%{provider: "", api_key: nil}) == nil
    end

    test "returns nil when there is a non-empty legacy api_key (fallback path works)" do
      result =
        EndpointForm.integration_warning(%{
          provider: "openrouter-not-set-up-#{System.unique_integer([:positive])}",
          api_key: "sk-or-v1-legacy"
        })

      assert result == nil
    end

    test "returns the warning string for a disconnected provider with no api_key" do
      provider = "openrouter-not-set-up-#{System.unique_integer([:positive])}"

      result =
        EndpointForm.integration_warning(%{
          provider: provider,
          api_key: nil
        })

      assert is_binary(result)
      assert result =~ "is not connected"
      assert result =~ provider
    end

    test "returns the warning when api_key is the empty string (treated as no fallback)" do
      provider = "openrouter-not-set-up-#{System.unique_integer([:positive])}"

      result =
        EndpointForm.integration_warning(%{
          provider: provider,
          api_key: ""
        })

      assert is_binary(result)
      assert result =~ "is not connected"
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      assert is_binary(render(view))
    end
  end
end
