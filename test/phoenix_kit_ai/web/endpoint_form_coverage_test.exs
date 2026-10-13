defmodule PhoenixKitAI.Web.EndpointFormCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.EndpointForm` LiveView.

  Drives select_provider, select_model, set_manual_model, clear_model,
  toggle_reasoning, select_provider_connection, save (success +
  error), and the various `handle_info` clauses for integration events.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.Integrations.Events, as: IntegrationsEvents
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Web.EndpointForm

  @models %{
    "data" => [
      %{
        "id" => "anthropic/claude-3-haiku",
        "name" => "Claude 3 Haiku",
        "context_length" => 200_000,
        "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
        "pricing" => %{"prompt" => "0.00000025", "completion" => "0.00000125"}
      },
      %{
        "id" => "openai/gpt-4o-probe",
        "name" => "GPT-4o Probe",
        "context_length" => 128_000,
        "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
        "pricing" => %{"prompt" => "0.000005", "completion" => "0.000015"}
      }
    ]
  }

  @model_input "input[name='endpoint[model]']"

  # Routes this module's HTTP through a stub answering `/models`, reporting
  # each request's host and path to the test.
  defp stub_models(body \\ @models) do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:fetched_url, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
    end)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    stub
  end

  # Picks `connection` in the form's integration picker. It is picked while
  # it has no key, so the form starts no validation of its own (core's
  # validation goes over the network).
  defp pick(view, %{uuid: uuid}) do
    render_hook(view, "select_provider_connection", %{"uuid" => uuid})
  end

  # Gives the picked connection a key and delivers the validation result
  # the form would have received, then waits for the model list.
  defp load_models(view, seed, %{uuid: uuid, name: name}) do
    seed.(name, data: %{"api_key" => "sk-test-key"})
    send(view.pid, {:validation_done, uuid, :ok})
    render_async(view, 2_000)
  end

  # The new-endpoint form with an OpenRouter connection picked and its
  # model list loaded.
  defp form_with_models(conn) do
    stub = stub_models()
    connection = seed_openrouter_connection("cov-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
    Req.Test.allow(stub, self(), view.pid)
    pick(view, connection)
    load_models(view, &seed_openrouter_connection/2, connection)

    view
  end

  defp model_input_value(view) do
    view
    |> element(@model_input)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
  end

  describe "select_provider event" do
    test "shows the picked provider's models, and none once the pick is cleared", %{conn: conn} do
      view = form_with_models(conn)

      # Two providers answered, so nothing is auto-selected.
      refute render(view) =~ "GPT-4o Probe"

      html = render_hook(view, "select_provider", %{"provider" => "openai"})
      assert html =~ "GPT-4o Probe"
      refute html =~ "Claude 3 Haiku"

      html = render_hook(view, "select_provider", %{"provider" => ""})
      refute html =~ "GPT-4o Probe"
    end

    test "a provider the list does not have shows no models", %{conn: conn} do
      view = form_with_models(conn)

      html = render_hook(view, "select_provider", %{"provider" => "nobody"})
      refute html =~ "GPT-4o Probe"
      refute html =~ "Claude 3 Haiku"
    end
  end

  describe "select_model + clear_model + set_manual_model" do
    test "select_model makes the model current; the placeholder and stray params leave it", %{
      conn: conn
    } do
      view = form_with_models(conn)

      html = render_hook(view, "select_model", %{"model" => "openai/gpt-4o-probe"})
      assert html =~ "GPT-4o Probe"
      assert model_input_value(view) == ["openai/gpt-4o-probe"]

      render_hook(view, "select_model", %{"_target" => ["model"], "model" => ""})
      assert model_input_value(view) == ["openai/gpt-4o-probe"]

      render_hook(view, "select_model", %{"weird" => "params"})
      assert model_input_value(view) == ["openai/gpt-4o-probe"]
    end

    test "clear_model empties the selection", %{conn: conn} do
      view = form_with_models(conn)
      render_hook(view, "select_model", %{"model" => "openai/gpt-4o-probe"})

      html = render_hook(view, "clear_model", %{})

      assert html =~ "No model selected"
      assert model_input_value(view) == [""]
    end

    test "set_manual_model stamps an id the list does not have, and ignores an empty one", %{
      conn: conn
    } do
      view = form_with_models(conn)

      html = render_hook(view, "set_manual_model", %{"model" => "vendor/unlisted-model"})
      assert html =~ "Not in current model list"
      assert model_input_value(view) == ["vendor/unlisted-model"]

      render_hook(view, "set_manual_model", %{})
      assert model_input_value(view) == ["vendor/unlisted-model"]

      render_hook(view, "set_manual_model", %{"model" => ""})
      assert model_input_value(view) == ["vendor/unlisted-model"]
    end
  end

  describe "toggle_reasoning event" do
    test "shows the reasoning options, then hides them again", %{conn: conn} do
      view = form_with_models(conn)
      render_hook(view, "select_model", %{"model" => "openai/gpt-4o-probe"})
      refute render(view) =~ "Effort Level"

      assert render_hook(view, "toggle_reasoning", %{}) =~ "Effort Level"
      refute render_hook(view, "toggle_reasoning", %{}) =~ "Effort Level"
    end
  end

  describe "select_provider_connection event" do
    test "a uuid naming no connection starts no fetch and keeps manual entry locked", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html =
        render_hook(view, "select_provider_connection", %{
          "uuid" => "01234567-89ab-7def-8000-000000000abc"
        })

      refute html =~ "Loading models..."
      assert has_element?(view, "#manual_model_input[disabled]")
    end
  end

  describe "save event — success + error paths" do
    test "successful save creates the endpoint and navigates back to the AI section", %{
      conn: conn
    } do
      connection = seed_openrouter_connection("save-#{System.unique_integer([:positive])}")
      name = "SavedViaLV-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      pick(view, connection)

      # Drive the save event directly (bypasses DOM lookup so we don't
      # depend on which form fields are conditionally rendered).
      result =
        render_hook(view, "save", %{
          "endpoint" => %{
            "name" => name,
            "provider" => "openrouter",
            "model" => "anthropic/claude-3-haiku",
            "temperature" => "0.5",
            "max_tokens" => "100",
            "top_p" => "0.9",
            "top_k" => "40",
            "frequency_penalty" => "0.0",
            "presence_penalty" => "0.0",
            "repetition_penalty" => "1.0",
            "seed" => "",
            "dimensions" => "",
            "stop" => "",
            "provider_settings" => %{"http_referer" => "", "x_title" => ""}
          }
        })

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == "/en/admin/ai"

      assert %PhoenixKitAI.Endpoint{temperature: 0.5, max_tokens: 100, top_k: 40} =
               saved = PhoenixKitAI.get_endpoint_by_name(name)

      assert saved.integration_uuid == connection.uuid
    end

    test "validation error keeps the form on-page with errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html =
        render_hook(view, "save", %{
          "endpoint" => %{
            "name" => "",
            "provider" => "openrouter",
            "model" => "",
            "provider_settings" => %{"http_referer" => "", "x_title" => ""}
          }
        })

      # `:action = :validate` is set so `<.input>` displays inline errors.
      assert html =~ "blank" or html =~ "can&#39;t be"
    end
  end

  describe "validate event with model field" do
    test "validate makes a listed model current, and an empty one clears it", %{conn: conn} do
      view = form_with_models(conn)

      html =
        render_change(view, "validate", %{
          "endpoint" => %{
            "name" => "X",
            "provider" => "openrouter",
            "model" => "anthropic/claude-3-haiku"
          }
        })

      # The model's own limits render only once it is the selected model.
      assert html =~ "200,000"

      html =
        render_change(view, "validate", %{
          "endpoint" => %{"name" => "X", "provider" => "openrouter", "model" => ""}
        })

      assert html =~ "No model selected"
      refute html =~ "200,000"
    end

    # Pins the provider-change handling: when the operator switches
    # provider on an existing form, model strings are provider-shaped
    # (`"anthropic/claude-3-opus"` on OpenRouter vs `"mistral-large-latest"`
    # on Mistral). The previous behaviour kept the stale model id in
    # the form, which the template's `params["model"] || endpoint.model`
    # fallback re-displayed under a "Not in current model list" warning
    # while the changeset disagreed (`"can't be blank"`). Empty string
    # is the sentinel — `nil` would fall through the `||` to the saved
    # `endpoint.model`.
    test "switching provider via validate clears the model param", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Stamp an OpenRouter model first so the form has a value to clear.
      render_change(view, "validate", %{
        "endpoint" => %{
          "name" => "PV",
          "provider" => "openrouter",
          "model" => "anthropic/claude-3-haiku"
        }
      })

      # Switching provider should empty the model param via
      # `maybe_handle_provider_change/2`. The Model Selection card
      # (which carries the hidden `endpoint[model]` input in the DOM)
      # is gated on `@active_connection`, so on this no-integration
      # mount we assert directly on the form's params rather than the
      # rendered HTML.
      render_change(view, "validate", %{
        "endpoint" => %{
          "name" => "PV",
          "provider" => "mistral",
          "model" => "anthropic/claude-3-haiku"
        }
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.form.params["model"] == ""
      assert assigns.form.params["provider"] == "mistral"
    end
  end

  describe "edit form load + integration PubSub" do
    test "edit form mounts with the existing endpoint", %{conn: conn} do
      ep = fixture_endpoint(name: "EditCov-#{System.unique_integer([:positive])}")
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{ep.uuid}/edit")
      assert html =~ ep.name
    end

    test "live_patch between two edit URLs reloads the endpoint", %{conn: conn} do
      # Pins the `:loaded_id` per-params reload guard. If `handle_params/3`
      # short-circuits on a boolean `:loaded` flag instead of comparing
      # the actual `params["id"]`, a same-process navigation between two
      # edit URLs (push_patch / live_patch) would keep the wrong endpoint
      # in the form. No production caller does this today, but the gate
      # has to be safe under it.
      ep_a = fixture_endpoint(name: "Patch-A-#{System.unique_integer([:positive])}")
      ep_b = fixture_endpoint(name: "Patch-B-#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{ep_a.uuid}/edit")
      assert html =~ ep_a.name
      refute html =~ ep_b.name

      patched_html =
        view
        |> render_patch("/en/admin/ai/endpoints/#{ep_b.uuid}/edit")

      assert patched_html =~ ep_b.name,
             "expected live_patch to reload — endpoint B should appear"

      refute patched_html =~ ep_a.name,
             "expected live_patch to clear endpoint A from the form"
    end
  end

  describe "public helpers — get_supported_params + model_max_tokens + format_number" do
    test "get_supported_params/1 with nil returns all params grouped" do
      result = EndpointForm.get_supported_params(nil)
      assert is_map(result)
      assert is_list(result[:basic] || [])
    end

    test "get_supported_params/1 with AIModel filters to supported keys only" do
      model = %AIModel{id: "x", supported_parameters: ["temperature", "top_p"]}
      result = EndpointForm.get_supported_params(model)

      keys =
        result
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn {k, _} -> k end)

      assert "temperature" in keys
      refute "max_tokens" in keys
    end

    test "get_supported_params/1 with map shape filters to supported keys" do
      result = EndpointForm.get_supported_params(%{"supported_parameters" => ["seed"]})

      keys =
        result |> Map.values() |> List.flatten() |> Enum.map(fn {k, _} -> k end)

      assert "seed" in keys
    end

    test "model_max_tokens/1 — nil + AIModel + map" do
      assert EndpointForm.model_max_tokens(nil) == nil

      assert EndpointForm.model_max_tokens(%AIModel{
               id: "x",
               max_completion_tokens: 4096,
               context_length: 100_000
             }) == 4096

      assert EndpointForm.model_max_tokens(%AIModel{
               id: "x",
               max_completion_tokens: nil,
               context_length: 8000
             }) == 8000

      assert EndpointForm.model_max_tokens(%{"max_completion_tokens" => 1024}) == 1024
      assert EndpointForm.model_max_tokens(%{"context_length" => 2048}) == 2048
    end

    test "format_number/1 — nil + integer + float + binary" do
      assert EndpointForm.format_number(nil) == "0"
      assert EndpointForm.format_number(1_234_567) == "1,234,567"
      assert EndpointForm.format_number(123.4) == "123"
      assert EndpointForm.format_number("9000") == "9000"
    end

    test "parameter_definitions/0 returns the canonical UI knob list" do
      defs = EndpointForm.parameter_definitions()
      assert Map.has_key?(defs, "temperature")
      assert Map.has_key?(defs, "max_tokens")
      assert defs["temperature"].type == :float
    end
  end

  describe "Integration PubSub handle_info clauses" do
    # Each integration event reloads the picker's connections; the form
    # shows a connection created after it mounted.
    for {label, message} <- [
          {"setup saved", {:integration_setup_saved, "openrouter", %{"status" => "connected"}}},
          {"connected", {:integration_connected, "openrouter", %{}}},
          {"connection added", {:integration_connection_added, "openrouter", %{}}},
          {"disconnected", {:integration_disconnected, "openrouter"}},
          {"connection removed", {:integration_connection_removed, "openrouter"}},
          {"validated", {:integration_validated, "openrouter", true}}
        ] do
      test "#{label} reloads the connection picker", %{conn: conn} do
        {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/new")
        name = "late-arrival-#{System.unique_integer([:positive])}"
        refute html =~ name

        seed_openrouter_connection(name)
        send(view.pid, unquote(Macro.escape(message)))

        assert render(view) =~ name
      end
    end

    test "an integration event unlocks manual model entry once the picked connection has a key",
         %{conn: conn} do
      connection = seed_openrouter_connection("unlock-#{System.unique_integer([:positive])}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      pick(view, connection)
      assert has_element?(view, "#manual_model_input[disabled]")

      seed_openrouter_connection(connection.name, data: %{"api_key" => "sk-test-key"})
      send(view.pid, {:integration_setup_saved, "openrouter", %{}})
      render(view)

      refute has_element?(view, "#manual_model_input[disabled]")
    end

    test ":fetch_models_from_integration with no key on the connection says so", %{conn: conn} do
      connection = seed_openrouter_connection("nokey-#{System.unique_integer([:positive])}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      pick(view, connection)

      send(view.pid, :fetch_models_from_integration)

      assert render(view) =~ "No API key configured"
    end

    # Regression: when editing an existing endpoint and the operator
    # switches the provider dropdown, the next model fetch must hit the
    # NEW provider's URL — not the saved `endpoint.base_url` (which is
    # for the old provider): a Mistral integration picked after switching
    # providers would otherwise have its model list fetched from
    # openrouter.ai with the Mistral key (wrong host, wrong list).
    test "a model fetch after a provider switch hits the new provider's URL", %{conn: conn} do
      stub = stub_models(%{"data" => []})

      # Endpoint is saved as openrouter. base_url is set to OpenRouter's
      # URL by the changeset's `maybe_set_default_base_url`.
      ep = fixture_endpoint(provider: "openrouter")
      mistral = seed_mistral_connection("switch-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{ep.uuid}/edit")
      Req.Test.allow(stub, self(), view.pid)

      # Operator switches to Mistral via the form. `current_provider`
      # flips to "mistral" but `socket.assigns.endpoint.base_url` is
      # still the OpenRouter URL until save.
      render_change(view, "validate", %{
        "endpoint" => %{"name" => ep.name, "provider" => "mistral", "model" => ""}
      })

      pick(view, mistral)
      load_models(view, &seed_mistral_connection/2, mistral)

      assert_receive {:fetched_url, host, path}, 1_000
      assert host == "api.mistral.ai", "expected mistral host, got #{inspect(host)}"
      assert path == "/v1/models", "expected /v1/models, got #{inspect(path)}"
    end

    test "a model fetch on the edit form selects the endpoint's saved model", %{conn: conn} do
      stub = stub_models()
      connection = seed_openrouter_connection("edit-#{System.unique_integer([:positive])}")

      ep =
        fixture_endpoint(model: "anthropic/claude-3-haiku", integration_uuid: connection.uuid)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{ep.uuid}/edit")
      Req.Test.allow(stub, self(), view.pid)
      # Not in the (empty) list yet, so the saved id renders as drift.
      assert html =~ "Not in current model list"

      html = load_models(view, &seed_openrouter_connection/2, connection)

      refute html =~ "Not in current model list"
      assert html =~ "Claude 3 Haiku"
      assert html =~ "200,000"
    end

    test ":model_fetch_slow flips models_loading_slow when fetch is in progress",
         %{conn: conn} do
      # Pin the 10s "still loading" hint behavior. The handler is
      # idempotent against a completed fetch: only flips when
      # models_loading is still true.
      seed_openrouter_connection("slow-hint",
        data: %{"api_key" => "sk-x", "status" => "connected"}
      )

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Force the LV into "loading" state by setting the assign
      # directly (would otherwise require an in-flight async fetch).
      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket
        socket = %{socket | assigns: Map.put(socket.assigns, :models_loading, true)}
        %{lv_state | socket: socket}
      end)

      # Fire the slow-hint message synchronously.
      send(view.pid, :model_fetch_slow)
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.models_loading_slow == true
    end

    test ":model_fetch_slow is a no-op when fetch already completed",
         %{conn: conn} do
      # If the fetch returned before 10s, the timer fires harmlessly:
      # models_loading is false, the slow handler should not flip
      # models_loading_slow on (would render a stale "still loading"
      # message under a populated dropdown).
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # models_loading is false from mount.
      send(view.pid, :model_fetch_slow)
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.models_loading == false
      assert assigns.models_loading_slow == false
    end

    test "retry_model_fetch re-triggers fetch when integration is connected",
         %{conn: conn} do
      # Stage: previous fetch failed, models_error is set, integration
      # is still connected. Clicking Retry should re-fire
      # `:fetch_models_from_integration` and reset the error.
      %{uuid: integration_uuid} =
        seed_openrouter_connection("retry-flow",
          data: %{"api_key" => "sk-retry", "status" => "connected"}
        )

      # Stub HTTP so the re-fetch triggered by retry doesn't hit the
      # network — return a 5xx so the LV ends up at the same error
      # state we started in (proves the re-fetch happened by virtue
      # of `models_error` being repopulated). Required because
      # `start_model_fetch_indicators` clears the error, which would
      # otherwise leave a misleading `nil` if we asserted right after.
      stub_module = PhoenixKitAI.Web.EndpointFormCoverageTest.RetryStub
      Req.Test.stub(stub_module, fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end)

      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, stub_module},
        retry: false
      )

      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      Req.Test.allow(stub_module, self(), view.pid)

      # Force the LV into the "previous fetch failed + integration
      # selected" state. `active_connection` must be a real uuid so
      # the credential lookup in `:fetch_models_from_integration`
      # finds an api_key and proceeds to send `{:fetch_models, _}`.
      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket

        socket = %{
          socket
          | assigns:
              Map.merge(socket.assigns, %{
                models_error: "Connection error: :timeout",
                integration_connected: true,
                active_connection: integration_uuid,
                current_provider: "openrouter",
                models_loading: false,
                models_loading_slow: false
              })
        }

        %{lv_state | socket: socket}
      end)

      # Subscribe to PubSub so we can synchronously wait for the
      # validation Task to complete. The validate-then-fetch flow
      # runs validation in a Task to keep the LV responsive; `record_validation`
      # broadcasts `:integration_validated` once the HTTP call returns.
      # That broadcast is our "Task done" signal — without it, `render(view)`
      # can return before the Task even sends its result message.
      :ok = IntegrationsEvents.subscribe()

      view |> render_hook("retry_model_fetch", %{})

      # Wait for the Task's validation to land.
      assert_receive {:integration_validated, _, _}, 2_000

      # Now drain the LV's mailbox (it should have :validation_done
      # queued from the Task, which sets `models_error`).
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      # After Retry, validation ran against the stub which returned 500.
      # The error pane re-rendered with the upstream-error message —
      # different from the original ":timeout" we seeded, proving the
      # re-fetch actually ran.
      assert is_binary(assigns.models_error)
      refute assigns.models_error =~ ":timeout"
    end

    test "retry_model_fetch is a no-op when integration is no longer connected",
         %{conn: conn} do
      # Defensive: if the operator's integration is gone (deleted /
      # disconnected) by the time they click Retry, the handler
      # short-circuits — same gate as the initial fetch.
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      :sys.replace_state(view.pid, fn lv_state ->
        socket = lv_state.socket

        socket = %{
          socket
          | assigns:
              Map.merge(socket.assigns, %{
                models_error: "Connection error: :timeout",
                integration_connected: false
              })
        }

        %{lv_state | socket: socket}
      end)

      view |> render_hook("retry_model_fetch", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.models_loading == false
      # Error message survives — operator picks a new integration
      # to recover (the picker selection event clears errors via
      # start_model_fetch_indicators).
      assert assigns.models_error != nil
    end

    test "EndpointForm handle_info catch-all logs at :debug for unknown messages",
         %{conn: conn} do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, :unknown_msg_for_endpoint_form)
          send(view.pid, {:something_random, "data"})
          _ = render(view)
        end)

      assert log =~ "[PhoenixKitAI.Web.EndpointForm] unhandled handle_info"
    end

    @tag :destructive
    test "save_endpoint rescue branch fires when the endpoints table is dropped mid-save",
         %{conn: conn} do
      # Pin the `rescue e ->` clause of `save_endpoint/2` (lines
      # 569-575). Reachable via DROP-TABLE-in-sandbox: mount the
      # form, drop the table, then submit save — Repo.insert raises
      # Postgrex.Error :undefined_table, the rescue catches it, logs
      # the stacktrace, and flashes a generic error. The sandbox
      # rolls the DROP back at test exit.
      alias Ecto.Adapters.SQL
      alias PhoenixKitAI.Test.Repo, as: TestRepo

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_endpoints CASCADE")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html =
            render_hook(view, "save", %{
              "endpoint" => %{
                "name" => "Probe-#{System.unique_integer([:positive])}",
                "provider" => "openrouter",
                "model" => "a/b"
              }
            })

          assert html =~ "Something went wrong"
        end)

      assert log =~ "Endpoint save failed"
    end

    test "save with non-numeric params is refused by the changeset, not by a crash",
         %{conn: conn} do
      # Drive the `:error -> original` branches of `parse_float/2` and
      # `parse_integer/2` — when the user submits a non-numeric string,
      # the parser returns the original value untouched so the changeset
      # can emit its own type error.
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      name = "ParseProbe-#{System.unique_integer([:positive])}"

      html =
        render_hook(view, "save", %{
          "endpoint" => %{
            "name" => name,
            "provider" => "openrouter",
            "model" => "a/b",
            "temperature" => "not-a-float",
            "max_tokens" => "not-an-int",
            "top_p" => "abc",
            "top_k" => "xyz"
          }
        })

      # Still on the form, with what was typed, and nothing was created.
      assert html =~ name
      refute html =~ "Something went wrong"
      assert PhoenixKitAI.get_endpoint_by_name(name) == nil
    end

    test "picking a connected integration starts the model fetch", %{conn: conn} do
      seeded =
        seed_openrouter_connection("default",
          data: %{"api_key" => "sk-test", "status" => "connected"}
        )

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html = render_change(view, "select_provider_connection", %{"uuid" => seeded.uuid})

      assert html =~ "Loading models..."
    end
  end

  describe "edit-form save + scope-bound actor_opts" do
    test "saving on the edit form with a scope threads actor_uuid through to activity",
         %{conn: conn} do
      # Pin the scope-bound branches of `actor_opts/1` (`%{uuid: uuid}`
      # match → `[actor_uuid: uuid, actor_role: role]`) and `admin?/1`
      # (`scope -> Scope.can_access_admin_area?(scope)`). Also exercises
      # the EDIT save path through `AI.update_endpoint(...)` (vs the new-endpoint
      # branch covered by the previous test).
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      ep = fixture_endpoint(name: "EditSave-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{ep.uuid}/edit")

      result =
        render_hook(view, "save", %{
          "endpoint" => %{
            "name" => ep.name,
            "provider" => "openrouter",
            "model" => "anthropic/claude-3-opus",
            "temperature" => "0.3",
            "max_tokens" => "200",
            "top_p" => "0.95",
            "top_k" => "50",
            "frequency_penalty" => "0.1",
            "presence_penalty" => "-0.1",
            "repetition_penalty" => "1.2",
            "seed" => "42",
            "dimensions" => "",
            "stop" => "STOP\nDONE",
            "provider_settings" => %{"http_referer" => "", "x_title" => ""}
          }
        })

      # Save success → push_navigate.
      assert match?({:error, {:live_redirect, _}}, result)

      # Activity row carries the threaded actor_uuid (proves scope-bound
      # actor_opts fired) plus db_pending false-state (no error_keys).
      assert_activity_logged(
        "endpoint.updated",
        resource_uuid: ep.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => ep.name,
          "actor_role" => "user"
        }
      )
    end

    test "validate event without a model param keeps current selected_model",
         %{conn: conn} do
      # Drive `case params["model"] do nil -> socket.assigns.selected_model`
      # — covers the `nil` branch of the validate-event model dispatch.
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      html =
        render_change(view, "validate", %{
          "endpoint" => %{
            "name" => "ValidateNoModel-#{System.unique_integer([:positive])}"
          }
        })

      assert html =~ "ValidateNoModel"
    end
  end
end
