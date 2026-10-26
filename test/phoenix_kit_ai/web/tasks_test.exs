defmodule PhoenixKitAI.Web.TasksTest do
  @moduledoc """
  The «AI → Tasks» page: every declared task with its needs, the endpoints
  it uses and their fitness; recomputed when the capability cache
  changes; the refresh button.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeAITasks)
      Application.delete_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints)
      Application.delete_env(:phoenix_kit_ai, :fake_ai_tasks_enabled)
    end)

    :ok
  end

  defp declared_endpoint(name, flags) do
    model = "vendor/#{System.unique_integer([:positive])}"

    fixture_endpoint(
      name: name,
      model: model,
      provider_settings: %{"capabilities" => Map.put(flags, "model", model)}
    )
  end

  test "lists the tasks with their needs and each endpoint's fitness", %{conn: conn} do
    fit = declared_endpoint("Fit EP", %{"vision" => "yes", "json_schema" => "yes"})
    unfit = declared_endpoint("Unfit EP", %{"vision" => "no", "json_schema" => "yes"})
    unknown = fixture_endpoint(name: "Unknown EP")

    Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, [
      fit.uuid,
      unfit.uuid,
      unknown.uuid
    ])

    {:ok, view, html} = live(conn, "/en/admin/ai/tasks")
    assert html =~ "<h1>Tasks</h1>"

    task = "[data-task-key='test.photo']"
    assert has_element?(view, task, "Photo reading")
    assert has_element?(view, task, "Read the items in a shelf photo.")
    assert has_element?(view, "#{task} [data-need=vision]")
    assert has_element?(view, "#{task} [data-need=json_schema]")

    assert has_element?(view, "#{task} [data-endpoint-uuid='#{fit.uuid}'] [data-fitness=fit]")

    assert has_element?(
             view,
             "#{task} [data-endpoint-uuid='#{unfit.uuid}'] [data-fitness=unfit]",
             "images"
           )

    assert has_element?(
             view,
             "#{task} [data-endpoint-uuid='#{unknown.uuid}'] [data-fitness=unknown]"
           )

    # This module's own tasks are listed too.
    assert has_element?(view, "[data-task-key='ai.translation']")
    assert has_element?(view, "[data-task-key='ai.playground']")
  end

  describe "the recommendations block" do
    test "is on every task's card, collapsed, and reads the journal", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for status <- ["success", "success", "error"] do
        TestRepo.insert!(%Request{
          model: "vendor/worked",
          status: status,
          request_type: "chat",
          latency_ms: 700,
          cost: Decimal.new("0.002"),
          metadata: %{"task" => "test.photo"},
          inserted_at: now,
          updated_at: now
        })
      end

      {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

      for key <- ["test.photo", "test.plain", "ai.translation"] do
        assert has_element?(view, "[data-task-key='#{key}'] details[id$='-recommendations']")
      end

      photo = "[data-task-key='test.photo']"
      assert has_element?(view, "#{photo} [data-worked-model='vendor/worked']", "3")
      assert has_element?(view, "#{photo} [data-worked-model='vendor/worked']", "33%")
      assert has_element?(view, "#{photo} [data-recommended-empty]")
      assert has_element?(view, "[data-task-key='test.plain'] [data-worked-empty]")
    end

    test "lists the fit models of the catalogue, with the create link only for a scope holding ai.manage_endpoints",
         %{conn: conn} do
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      fixture_endpoint(name: "Catalogue EP", model: "google/gemini-flash")

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "google/gemini-flash",
              "name" => "Gemini Flash",
              "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
              "architecture" => %{
                "input_modalities" => ["text", "image"],
                "output_modalities" => ["text"]
              },
              "supported_parameters" => ["tools", "structured_outputs"]
            },
            %{
              "id" => "deepseek/flash",
              "name" => "DeepSeek Flash",
              "pricing" => %{"prompt" => "0.00000001", "completion" => "0.00000004"},
              "architecture" => %{
                "input_modalities" => ["text"],
                "output_modalities" => ["text"]
              },
              "supported_parameters" => ["tools", "structured_outputs"]
            }
          ]
        })
      end)

      pid =
        start_supervised!(
          {PhoenixKitAI.Capabilities,
           [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
        )

      Req.Test.allow(stub, self(), pid)
      assert :ok = PhoenixKitAI.Capabilities.refresh()

      scope = fn permissions ->
        %PhoenixKit.Users.Auth.Scope{
          user: %{uuid: Ecto.UUID.generate(), email: "t@example.com"},
          authenticated?: true,
          cached_roles: ["Admin"],
          cached_permissions: MapSet.new(permissions)
        }
      end

      photo = "[data-task-key='test.photo']"

      # The create link's ai.manage_endpoints check resolves through the registry.
      :ok = ModuleRegistry.register(PhoenixKitAI)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)

      with_ai = put_test_scope(conn, scope.(["ai", "ai.manage_endpoints"]))
      {:ok, view, _html} = live(with_ai, "/en/admin/ai/tasks")

      # The vision task takes the model that sees images, not the cheaper one that does not.
      assert has_element?(view, "#{photo} [data-recommended-model='google/gemini-flash']")
      refute has_element?(view, "#{photo} [data-recommended-model='deepseek/flash']")

      assert has_element?(
               view,
               "[data-task-key='test.plain'] [data-recommended-model='deepseek/flash']"
             )

      assert has_element?(
               view,
               "#{photo} [data-recommended-model='google/gemini-flash'] a[data-create-endpoint]"
             )

      without = put_test_scope(conn, scope.(["ai"]))
      {:ok, view, _html} = live(without, "/en/admin/ai/tasks")
      assert has_element?(view, "#{photo} [data-recommended-model='google/gemini-flash']")
      refute has_element?(view, "[data-create-endpoint]")
    end
  end

  test "the only-verified switch says that models without a catalogue need their capabilities marked",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    msgid =
      "Without a catalogue (OpenAI, xAI, Z.ai) the capabilities have to be marked on the endpoint, or the calls are refused."

    assert has_element?(view, "#ai-guard-verified-only-hint", msgid)

    for locale <- ["ru", "et"] do
      translated =
        Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
          Gettext.dgettext(PhoenixKitAI.Gettext, "default", msgid)
        end)

      assert translated != msgid, locale
      assert translated =~ "OpenAI, xAI, Z.ai", locale
    end
  end

  test "keys that differ only in punctuation get distinct card ids", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/ai/tasks")
    doc = LazyHTML.from_document(html)

    ids =
      for key <- ["test.same.id", "test.same-id"] do
        [id] = doc |> LazyHTML.query("[data-task-key='#{key}']") |> LazyHTML.attribute("id")
        id
      end

    assert Enum.uniq(ids) == ids
  end

  test "greys out a task of a switched-off module", %{conn: conn} do
    Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, false)
    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    assert has_element?(view, "[data-task-key='test.photo'] [data-module-off]")
    refute has_element?(view, "[data-task-key='ai.playground'] [data-module-off]")
  end

  test "recomputes the fitness when the capability cache changes", %{conn: conn} do
    ep = fixture_endpoint(name: "Changing EP")
    Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_endpoints, [ep.uuid])

    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")
    assert has_element?(view, "[data-endpoint-uuid='#{ep.uuid}'] [data-fitness=unknown]")

    {:ok, _} =
      PhoenixKitAI.update_endpoint(ep, %{
        provider_settings: %{
          "capabilities" => %{"model" => ep.model, "vision" => "no", "json_schema" => "yes"}
        }
      })

    send(view.pid, {:capabilities_refreshed, ["https://openrouter.ai/api/v1"]})
    assert has_element?(view, "[data-endpoint-uuid='#{ep.uuid}'] [data-fitness=unfit]")
  end

  test "the refresh button asks the capability cache to refresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    view |> element("#ai-tasks-refresh") |> render_click()
    # No cache process runs in this test: the refresh fails and says so.
    assert render_async(view) =~ "could not be read"
  end
end
