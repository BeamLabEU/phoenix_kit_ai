defmodule PhoenixKitAI.Web.EndpointFormTest do
  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Test.Repo, as: TestRepo
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

  describe "edit — legacy api_key recovery field" do
    # When the migration hasn't completed for this endpoint
    # (api_key column populated, integration_uuid still NULL), the
    # form surfaces the legacy key in a read-only password field with
    # a copy button so the operator can paste it into a new
    # Integration. Once an integration is selected and saved, the
    # changeset clears api_key in the same write so the field
    # disappears and stays gone.

    test "renders the recovery card when api_key is set and integration_uuid is nil",
         %{conn: conn} do
      endpoint = fixture_endpoint(api_key: "sk-or-recovery-test", integration_uuid: nil)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert html =~ "Legacy API key (recovery)"
      # Field is rendered with the legacy value (masked via type=password
      # client-side, but the value attr is in the markup so the copy
      # button can grab it).
      assert html =~ ~s(value="sk-or-recovery-test")
      assert html =~ "data-copy-target=\"#legacy-api-key-field\""
    end

    test "does NOT render the recovery card when integration_uuid is set",
         %{conn: conn} do
      %{uuid: integration_uuid} = seed_openrouter_connection("recovery-hidden")

      endpoint =
        fixture_endpoint(
          api_key: "sk-still-here-but-hidden",
          integration_uuid: integration_uuid
        )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      refute html =~ "Legacy API key (recovery)"
    end

    test "does NOT render the recovery card when api_key is the empty string",
         %{conn: conn} do
      # The post-clear state. `api_key` is NOT NULL in the schema, so
      # the changeset clears to "" rather than NULL — empty string is
      # treated as "no fallback" by every downstream consumer.
      endpoint = fixture_endpoint(api_key: "sk-temp")

      TestRepo.query!(
        "UPDATE phoenix_kit_ai_endpoints SET api_key = '' WHERE uuid = $1",
        [Ecto.UUID.dump!(endpoint.uuid)]
      )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      refute html =~ "Legacy API key (recovery)"
    end

    test "is hidden after picking an integration and saving (clear-on-save round trip)",
         %{conn: conn} do
      # Pre-stage: an integration row to pick, plus a legacy endpoint.
      %{uuid: integration_uuid} = seed_openrouter_connection("clear-on-save")

      endpoint =
        fixture_endpoint(api_key: "sk-or-will-be-cleared", integration_uuid: nil)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      assert html =~ "Legacy API key (recovery)"

      # Simulate the integration_picker setting active_connection. The
      # form LV exposes "select_provider_connection" for this.
      view
      |> render_hook("select_provider_connection", %{"uuid" => integration_uuid})

      # Submit the form. The active_connection feeds integration_uuid
      # into the params via the form's save handler.
      view
      |> form("form[phx-submit=\"save\"]",
        endpoint: %{
          name: endpoint.name,
          provider: "openrouter",
          model: endpoint.model
        }
      )
      |> render_submit()

      # Reload from DB: api_key cleared, integration_uuid set, both
      # in the same transaction. Cleared to "" (not NULL) since the
      # column is NOT NULL — same end-state semantics for downstream.
      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == integration_uuid
      assert reloaded.api_key == ""

      # Recovery card no longer renders on a fresh mount.
      {:ok, _view2, html2} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      refute html2 =~ "Legacy API key (recovery)"
    end
  end

  describe "integration_warning/1" do
    # `save_success_message/2` calls `integration_warning/1` after a
    # successful save and appends the result to the flash. The flash
    # path is hard to drive end-to-end because the form's `provider`
    # is bound to the integration_picker's active_connection assign,
    # not a free-text input. Pinning the helper directly keeps the
    # branches honest.

    test "warns when nothing is configured (no integration_uuid, no provider, no api_key)" do
      # Pre-fix this returned nil because the function only knew about
      # `provider` and quietly skipped when it was empty. That hid the
      # "you saved a totally unconfigured endpoint" case from the
      # operator. Now the empty-everything endpoint surfaces the
      # "No integration configured" warning.
      result_nil = EndpointForm.integration_warning(%{provider: nil, api_key: nil})
      result_empty = EndpointForm.integration_warning(%{provider: "", api_key: nil})

      assert is_binary(result_nil)
      assert result_nil =~ "No integration configured"
      assert result_empty == result_nil
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

    test "returns nil when integration_uuid resolves to a connected integration" do
      # Pre-warning fix, this branch was unreachable — the function
      # only checked `provider`. After the fix, integration_uuid takes
      # precedence and a connected pinned integration silences the
      # warning regardless of whatever `provider` still holds (it
      # defaults to the literal "openrouter" for new endpoints).
      %{uuid: uuid} =
        seed_openrouter_connection("warn-ok-#{System.unique_integer([:positive])}",
          data: %{"api_key" => "sk-test-warn", "status" => "connected"}
        )

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: uuid,
          provider: "openrouter",
          api_key: nil
        })

      assert result == nil
    end

    test "returns the warning for a pinned integration that isn't connected" do
      # `integration_uuid` set but the row isn't reachable (deleted /
      # unreachable). With no api_key fallback, the request would
      # fail — surface that.
      stale_uuid = "01234567-89ab-7def-8000-000000warning"

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: stale_uuid,
          provider: "openrouter",
          api_key: nil
        })

      assert is_binary(result)
      assert result =~ "selected integration is not connected"
    end

    test "returns nil when integration_uuid is unreachable but api_key fallback exists" do
      # Even with a broken pin, a stored legacy api_key keeps the
      # request working via OpenRouterClient.resolve_api_key/1's final
      # fallback. No warning needed.
      stale_uuid = "01234567-89ab-7def-8000-000000warning"

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: stale_uuid,
          provider: "openrouter",
          api_key: "sk-or-v1-legacy"
        })

      assert result == nil
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

    test "new endpoint with exactly one connection still leaves picker empty",
         %{conn: conn} do
      # The picker mirrors the endpoint's actual stored state. A new
      # endpoint has no integration pinned, so the picker shows nothing
      # selected — even when only one connection exists. Auto-selecting
      # would mask "no integration set" with "an integration is set".
      seed_openrouter_connection("auto-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
      assert assigns.integration_connected == false
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

    test "edit endpoint with stale provider + exactly one connection leaves picker empty",
         %{conn: conn} do
      # Stale provider doesn't resolve, integration_uuid is nil, only
      # one other connection exists — the picker still shows nothing
      # selected. The endpoint isn't pinned to that connection, so
      # surfacing it as "selected" would be a lie.
      seed_openrouter_connection("solo-#{System.unique_integer([:positive])}")

      stale_uuid = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(provider: stale_uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
    end
  end

  describe "load_endpoint active_connection — integration_uuid path" do
    # Post-V107, endpoints reference the chosen integration via the
    # dedicated `integration_uuid` column. The picker should light up
    # the matching connection regardless of whatever the legacy
    # `provider` field still holds.

    test "edit endpoint with integration_uuid set picks the matching connection",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("uuid-pinned-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: uuid, provider: "openrouter")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
    end

    test "integration_uuid wins over a stale provider value", %{conn: conn} do
      %{uuid: real_uuid} =
        seed_openrouter_connection("winner-#{System.unique_integer([:positive])}")

      stale_provider = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(integration_uuid: real_uuid, provider: stale_provider)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == real_uuid
    end

    test "endpoint with deleted integration_uuid surfaces the orphan instead of auto-picking",
         %{conn: conn} do
      # Regression: when an endpoint's `integration_uuid` points at a
      # deleted integration AND there happens to be exactly one OTHER
      # current connection, the cond fall-through used to auto-select
      # that unrelated connection — silently switching the endpoint to
      # the wrong integration with no warning. Now `active` stays nil
      # for orphaned uuids and the picker renders its "Integration
      # deleted" warning card via `selected_uuids`.
      orphaned_uuid = "01234567-89ab-7def-8000-000000010001"

      # Seed a different integration so there's a "tempting" auto-pick
      # candidate available.
      %{uuid: live_uuid} =
        seed_openrouter_connection("decoy-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: orphaned_uuid)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns

      # `active_connection` is nil — we do NOT silently switch the
      # endpoint to the unrelated `live_uuid`.
      assert assigns.active_connection == nil
      refute assigns.active_connection == live_uuid

      # `selected_uuids` carries the orphan so the picker renders the
      # "Integration deleted" warning card.
      assert assigns.selected_uuids == [orphaned_uuid]

      # The warning text reaches the rendered HTML.
      assert html =~ "Integration deleted"
    end

    test "endpoint with deleted integration_uuid AND no other connections still surfaces orphan",
         %{conn: conn} do
      # No live connection at all — the picker should still render the
      # orphan warning, not just an empty state.
      orphaned_uuid = "01234567-89ab-7def-8000-000000020002"

      endpoint = fixture_endpoint(integration_uuid: orphaned_uuid)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == [orphaned_uuid]
      assert html =~ "Integration deleted"
    end
  end

  describe "select_provider_connection event" do
    # The picker dispatches this event with the chosen integration's
    # uuid. The form should write it into `form.params` under
    # `integration_uuid` (not `provider`) so save persists the new
    # column. Pins the Phase 3a swap.

    test "writes the picked uuid into form.params['integration_uuid']",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("pick-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      view
      |> element(~s(button[phx-click="select_provider_connection"][phx-value-uuid="#{uuid}"]))
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == uuid
      assert assigns.form.params["integration_uuid"] == uuid
    end

    test "clicking the selected card again deselects it",
         %{conn: conn} do
      # The picker emits action="deselect" when the currently-selected
      # card is clicked. The form should clear active_connection,
      # selected_uuids, and write nil into form.params so save
      # persists the unpinning instead of silently re-using the
      # previously-stamped value.
      %{uuid: uuid} =
        seed_openrouter_connection("toggle-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Pick it.
      view
      |> render_hook("select_provider_connection", %{
        "uuid" => uuid,
        "action" => "select"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == uuid
      assert assigns.selected_uuids == [uuid]
      assert assigns.form.params["integration_uuid"] == uuid

      # Click it again — the picker emits action="deselect".
      view
      |> render_hook("select_provider_connection", %{
        "uuid" => uuid,
        "action" => "deselect"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
      assert assigns.integration_connected == false
      assert assigns.form.params["integration_uuid"] == nil
    end

    test "deselect on an existing endpoint clears integration_uuid on save",
         %{conn: conn} do
      # Edit an endpoint that's pinned to a connection, deselect via
      # the picker, save — the DB row should end up with
      # integration_uuid = nil (not the original uuid).
      %{uuid: integration_uuid} =
        seed_openrouter_connection("clear-on-save-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: integration_uuid, provider: "openrouter")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      # Sanity: load_endpoint resolved the pin.
      assert :sys.get_state(view.pid).socket.assigns.active_connection == integration_uuid

      view
      |> render_hook("select_provider_connection", %{
        "uuid" => integration_uuid,
        "action" => "deselect"
      })

      view |> form("form", endpoint: %{name: endpoint.name}) |> render_submit()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == nil
    end
  end

  describe "select_provider_connection on :new mount — drained handle_info" do
    # Regression: `select_provider_connection` queues
    # `send(self(), :fetch_models_from_integration)` which calls
    # `current_models_base_url/1`. That function had a
    # `endpoint && endpoint.provider == cp` chain feeding a strict
    # `and is_binary(url) and url != ""` — when `@endpoint` is nil
    # (the `:new` action), the left side reduces to `nil`, and
    # `nil and ...` raises `BadBooleanError`. The fix is `&&`
    # throughout. Pinning here so a regression to strict `and`
    # would fail this test.
    #
    # The synchronous picker handler isn't enough — the crashing
    # code lives in the queued handle_info. We have to drain the
    # mailbox by rendering after the hook (or `:sys.get_state`,
    # which also drains up to its own message).

    test "picking an integration on /endpoints/new doesn't crash the LV",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("new-mount-pick-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Sanity: no endpoint loaded yet (new mode).
      assert :sys.get_state(view.pid).socket.assigns.endpoint == nil

      # Pick — this queues :fetch_models_from_integration.
      view
      |> render_hook("select_provider_connection", %{
        "uuid" => uuid,
        "action" => "select"
      })

      # Drain the mailbox. `render(view)` round-trips through the LV
      # process which forces it to process queued messages (including
      # the `:fetch_models_from_integration` self-send). If the
      # `current_models_base_url/1` `and`-vs-`&&` regression
      # returned, this call would raise.
      html = render(view)

      # Post-pick state holds: the LV is still alive, the pick took
      # effect, and the model-fetch lifecycle assigns flipped.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == uuid
      assert assigns.selected_uuids == [uuid]
      # Either still loading or completed — both prove handle_info ran
      # without crashing.
      assert is_boolean(assigns.models_loading)
      # And the rendered HTML still looks like the endpoint form (not
      # a crash page).
      assert html =~ "Provider Configuration"
    end

    test "switching integrations clears stale model state from the previous selection",
         %{conn: conn} do
      # Regression: pre-fix, `select_provider_connection` only set
      # `active_connection` and triggered a new fetch — it didn't
      # clear `@models_grouped` / `@models` / `@selected_provider` /
      # `@provider_models`. If integration A's fetch had previously
      # populated those and integration B's fetch fails (or just
      # hasn't returned yet), the picker rendered A's stale model
      # list alongside B's error pane or loading spinner. Confusing
      # and misleading.
      %{uuid: uuid_a} =
        seed_openrouter_connection("first-#{System.unique_integer([:positive])}")

      %{uuid: uuid_b} =
        seed_openrouter_connection("second-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Pick A and pretend A's fetch completed with some models.
      view
      |> render_hook("select_provider_connection", %{
        "uuid" => uuid_a,
        "action" => "select"
      })

      :sys.replace_state(view.pid, fn state ->
        assigns = state.socket.assigns
        models = [%PhoenixKitAI.AIModel{id: "fake/model-a", name: "Fake A"}]
        grouped = [{"fake", models}]

        new_assigns =
          assigns
          |> Map.put(:models, models)
          |> Map.put(:models_grouped, grouped)
          |> Map.put(:selected_provider, "fake")
          |> Map.put(:provider_models, models)
          |> Map.put(:__changed__, %{})

        %{state | socket: %{state.socket | assigns: new_assigns}}
      end)

      assigns_after_a = :sys.get_state(view.pid).socket.assigns
      assert assigns_after_a.models_grouped == [{"fake", assigns_after_a.models}]

      # Now switch to B. Stale model state from A must be wiped
      # synchronously — even before B's fetch returns.
      view
      |> render_hook("select_provider_connection", %{
        "uuid" => uuid_b,
        "action" => "select"
      })

      assigns_after_b = :sys.get_state(view.pid).socket.assigns
      assert assigns_after_b.active_connection == uuid_b
      assert assigns_after_b.models == []
      assert assigns_after_b.models_grouped == []
      assert assigns_after_b.selected_provider == nil
      assert assigns_after_b.provider_models == []
      assert assigns_after_b.selected_model == nil
    end
  end

  describe "Provider dropdown — filtered to providers with integrations" do
    # The select used to render every entry in `Endpoint.provider_options()`
    # regardless of whether the operator had set up an integration for
    # that provider. Now the LV filters the option list to providers
    # with ≥1 connection (plus the currently-edited endpoint's provider,
    # so edit flows don't lose the saved selection).

    # `value="openrouter"` substring matches both the unselected and
    # selected variants of the rendered `<option>`. The select wraps in
    # `selected=""` when that value is currently bound, which would
    # break a stricter `<option value="..">` match.

    test "dropdown lists only providers with at least one connection (new mode)",
         %{conn: conn} do
      seed_openrouter_connection("filter-#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # OpenRouter has a connection, so it's in the option list.
      assert html =~ ~s(value="openrouter">OpenRouter)
      # Mistral and DeepSeek have none seeded → omitted.
      refute html =~ ~s(value="mistral">Mistral)
      refute html =~ ~s(value="deepseek">DeepSeek)
    end

    test "falls back to all providers when none have any connection",
         %{conn: conn} do
      # No seed: zero integrations of any provider. Filter would yield
      # an empty list, which would render an unusable dropdown — the
      # LV falls back to the full provider list so the operator can
      # still scan the available providers + see the hint pointing to
      # Settings → Integrations.
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      assert html =~ ~s(value="openrouter">OpenRouter)
      assert html =~ ~s(value="mistral">Mistral)
      assert html =~ ~s(value="deepseek">DeepSeek)
    end

    test "edit flow keeps the endpoint's saved provider in the list even if it has 0 connections",
         %{conn: conn} do
      # Seed only mistral. Pin an endpoint to openrouter (zero
      # connections). The edit dropdown must still include openrouter
      # so the user's existing choice doesn't vanish mid-flow.
      seed_mistral_connection("keep-saved-#{System.unique_integer([:positive])}")

      endpoint =
        fixture_endpoint(
          provider: "openrouter",
          integration_uuid: nil
        )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      # Mistral has a connection → in list.
      assert html =~ ~s(value="mistral">Mistral)
      # Openrouter has no connection BUT is the endpoint's saved
      # provider → included.
      assert html =~ ~s(value="openrouter">OpenRouter)
      # DeepSeek has neither → excluded.
      refute html =~ ~s(value="deepseek">DeepSeek)
    end

    test "renders the 'Add one in Settings → Integrations' hint link",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # With no integrations, the picker renders its empty state with a
      # link into Settings → Integrations (copy changed from the old
      # "Need another integration?" hint).
      assert html =~ "No integrations configured."
      # The link target — uses prefix path helpers.
      assert html =~ "/admin/settings/integrations"
      assert html =~ "Add one in Settings → Integrations"
    end

    test "new mount with only mistral connection doesn't surface openrouter as a dead-end option",
         %{conn: conn} do
      # Regression: `current_provider` is mount-defaulted to
      # "openrouter" even on `:new` with no saved endpoint. The
      # filter previously padded `current_provider` into the
      # dropdown unconditionally, surfacing OpenRouter as a clickable
      # dead-end (no connection → "Pick an integration above" placeholder
      # with no integration to pick). Padding now requires
      # `socket.assigns.endpoint != nil` (i.e. edit mode).
      seed_mistral_connection("only-mistral-#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      assert html =~ ~s(value="mistral">Mistral)
      refute html =~ ~s(value="openrouter">OpenRouter)
      refute html =~ ~s(value="deepseek">DeepSeek)
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
        model: "a/b",
        api_key: "sk-test-key"
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
                 model: "a/b",
                 api_key: "sk-test-key"
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

    test "empty name on the validate event does NOT surface 'can't be blank'", %{conn: conn} do
      # The boss explicitly didn't want "can't be blank" popping up
      # mid-typing. The validate handler still rebuilds the changeset
      # (to keep `@form` and `@selected_model` in sync), but it no
      # longer stamps `:action, :validate` — which is what `<.input>`
      # checks before rendering error markup. Errors come back on
      # save-failure (see the test below).
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html =
        view
        |> render_change("validate", %{
          "endpoint" => %{"name" => "", "provider" => "openrouter", "model" => ""}
        })

      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end

    test "submitting with empty required fields renders inline errors", %{conn: conn} do
      # The save path lets `AI.create_endpoint/2` run the changeset
      # through `Repo.insert`, which stamps `action: :insert` on the
      # returned `{:error, changeset}`. That action is what gates
      # `<.input>`'s error markup, so blanks finally show up to the
      # operator — but only after they tried to commit.
      #
      # Note: the Model Selection card (with its hidden `endpoint[model]`
      # input) is gated on `@active_connection`, so on the /new mount
      # with no integration picked, that field isn't in the DOM. The
      # form-helper bindings only cover what's currently rendered;
      # blank `name` alone is sufficient to drive the error path.
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html =
        view
        |> form("form[phx-submit=\"save\"]",
          endpoint: %{"name" => "", "provider" => "openrouter"}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "format_price/1" do
    # OpenRouter pricing comes back as either a JSON number or a
    # stringified float depending on the model row's age. The helper
    # normalises both into a rounded "$X.XX" per-million display
    # string, and returns nil for empty/missing values so the
    # template can render-or-skip cleanly.

    test "renders a JSON-number price as $/M dollars rounded to 2 places" do
      assert EndpointForm.format_price(0.0000015) == "$1.50"
      assert EndpointForm.format_price(0.000010) == "$10.00"
    end

    test "parses a stringified float and renders the same shape" do
      assert EndpointForm.format_price("0.0000015") == "$1.50"
      assert EndpointForm.format_price("0.00000025") == "$0.25"
    end

    test "returns nil for empty / nil inputs so the template can :if-skip" do
      assert EndpointForm.format_price(nil) == nil
      assert EndpointForm.format_price("") == nil
    end

    test "returns nil for unparseable strings — doesn't render '$NaN'" do
      assert EndpointForm.format_price("not-a-number") == nil
    end

    test "renders zero as $0.00" do
      # OpenRouter occasionally lists free models with 0 pricing.
      # Should render explicitly, not get swallowed by an empty check.
      assert EndpointForm.format_price(0.0) == "$0.00"
      assert EndpointForm.format_price("0") == "$0.00"
    end

    test "renders a bare integer without crashing" do
      # `:erlang.float_to_binary/2` requires a float; integer input
      # raises `ArgumentError`. Jason decodes a bare-integer JSON
      # value (e.g. free-tier `0` pricing) into an Elixir integer,
      # which `is_number/1` accepts but `float_to_binary/2` rejects.
      # The helper coerces via `value * 1.0` before formatting — pin
      # the integer paths so a regression would surface here.
      assert EndpointForm.format_price(0) == "$0.00"
      assert EndpointForm.format_price(2) == "$2000000.00"
    end
  end

  describe "Section gating — greyed headers when no integration picked" do
    # Boss flagged that an unreachable card body is dead weight, but
    # the headers should still appear (greyed) so the operator knows
    # the form has more sections beyond Provider Configuration. Pin
    # the three card headers that gate on `@active_connection`.

    test "Model Selection header renders with greyed class when no integration",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # Header visible (we don't hide the section)…
      assert html =~ "Model Selection"
      # …but greyed — the muted styling now sits on the whole section
      # (opacity-60) rather than the header text class.
      assert html =~
               ~r|<section class="card bg-base-100 shadow-lg opacity-60">.{0,200}Model Selection|s

      # And body shows the "pick an integration" placeholder, not
      # the rich grid.
      assert html =~ "Pick an integration above to load available models"
      # Sanity — no model-card scaffolding rendered.
      refute html =~ ~s|id="model_grid"|
    end

    test "Generation Parameters header greyed + placeholder shown",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # The "no model" placeholder card carries both the greyed
      # header and the no-integration-specific placeholder copy.
      assert html =~ "Generation Parameters"

      assert html =~
               "Pick an integration above, then a model, to configure generation parameters."
    end

    test "Optional Provider Settings header greyed + placeholder shown",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      assert html =~ "Optional Provider Settings"
      assert html =~ "Pick an integration above to see optional provider-specific settings."

      # The OpenRouter-specific HTTP-Referer / X-Title inputs are
      # NOT rendered when the gate doesn't open.
      refute html =~ ~s|name="endpoint[provider_settings][http_referer]"|

      # The Enabled toggle is EDIT-only now (`:if={@endpoint}` in the
      # template — new endpoints inherit the schema's enabled: true
      # default, so a "create + disabled" flow isn't exposed). On /new
      # it must NOT render.
      refute html =~ ~s|name="endpoint[enabled]"|
    end
  end

  describe "Manual model-id fallback — gating + accessibility" do
    # The fallback `<input>` and "Set Model" `<button>` appear when
    # the model grid is empty. Without an integration connected,
    # there's no way to actually load models — so both controls go
    # `disabled` rather than tempting the operator to type into a
    # field whose action is unreachable.

    test "input + submit button are disabled when no integration is picked",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # With no integration picked, `@active_connection` is nil
      # AND the Model Selection card is in placeholder mode, so
      # the manual-id fallback isn't even rendered in this state
      # (it lives inside the gated body block). The placeholder
      # IS rendered.
      assert html =~ "Pick an integration above to load available models"

      # And specifically the manual model id input + button are
      # NOT in the DOM at all (gated out with the rest of the
      # body).
      refute html =~ ~s|id="manual_model_input"|
      refute html =~ "Set Model"
    end
  end
end
