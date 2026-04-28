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

  describe "load_endpoint active_connection wiring" do
    # Pins upstream `3d8c0a6` ("form improvement"). The load helpers no
    # longer fall back to the literal string `"openrouter"` when no
    # integration matches, and the edit branch ignores stale
    # `endpoint.provider` UUIDs that don't point at a live connection.
    # Without these tests a regression to the old `"openrouter"` /
    # provider-trust semantics passes the rest of the suite silently.

    test "new endpoint with zero connections leaves active_connection nil",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.integration_connected == false
    end

    test "new endpoint with exactly one connection auto-selects it",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("auto-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
    end

    test "edit endpoint whose provider matches a live connection keeps it",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("match-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(provider: uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
    end

    test "edit endpoint with stale provider + multiple connections falls to nil",
         %{conn: conn} do
      seed_openrouter_connection("a-#{System.unique_integer([:positive])}")
      seed_openrouter_connection("b-#{System.unique_integer([:positive])}")

      stale_uuid = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(provider: stale_uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      # Edit branch's `active && Integrations.connected?(active)` short-circuits
      # to nil when active is nil; the new-endpoint branch uses explicit
      # `false`. Both are falsy — assert on truthiness, not the literal.
      refute assigns.integration_connected
    end

    test "edit endpoint with stale provider + exactly one connection auto-selects it",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("solo-#{System.unique_integer([:positive])}")

      stale_uuid = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(provider: stale_uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
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

  describe "edge-case input handling" do
    # These pin C12 agent #2's "tests cover error paths, not just happy
    # paths" requirement. Each case is a class of input that has
    # historically tripped Phoenix forms or Ecto changesets.

    test "Unicode name round-trips through changeset + DB", _ do
      attrs = %{
        name: "日本語エンドポイント — Café 🚀 #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b"
      }

      assert {:ok, endpoint} = PhoenixKitAI.create_endpoint(attrs)
      assert endpoint.name =~ "日本語"
      assert endpoint.name =~ "🚀"

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.name == endpoint.name
    end

    test "SQL metacharacters in name don't break create_endpoint or get_endpoint", _ do
      malicious =
        "'; DROP TABLE phoenix_kit_ai_endpoints; -- #{System.unique_integer([:positive])}"

      assert {:ok, endpoint} =
               PhoenixKitAI.create_endpoint(%{
                 name: malicious,
                 provider: "openrouter",
                 model: "a/b"
               })

      # Round-trip — the literal string lives in the DB; Ecto's
      # parameterised query path makes injection a non-issue.
      assert endpoint.name == malicious
      assert PhoenixKitAI.get_endpoint!(endpoint.uuid).name == malicious
    end

    test "name longer than 100 chars is rejected by the changeset validator" do
      too_long = String.duplicate("X", 101)

      changeset =
        PhoenixKitAI.Endpoint.changeset(%PhoenixKitAI.Endpoint{}, %{
          name: too_long,
          provider: "openrouter",
          model: "a/b"
        })

      refute changeset.valid?

      assert changeset.errors[:name] |> elem(0) =~ "should be at most"
    end

    test "empty name on the validate event renders an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # `phx-change="validate"` fires on every keystroke. The form body
      # has a hidden `endpoint[model]` input that must match what the
      # LV rendered, so we trigger validate via render_change with the
      # field we actually want to vary, leaving the model alone.
      html =
        view
        |> render_change("validate", %{
          "endpoint" => %{"name" => "", "provider" => "openrouter", "model" => ""}
        })

      # Inline error renders because the LV's validate event sets
      # `:action = :validate` (endpoint_form.ex:236, 300, 324, 343),
      # gating `<.input>`'s error display.
      assert html =~ "can&#39;t be blank" or html =~ "blank"
    end
  end
end
