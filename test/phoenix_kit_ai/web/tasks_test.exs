defmodule PhoenixKitAI.Web.TasksTest do
  @moduledoc """
  The «AI → Tasks» page: every declared task with its needs, the endpoints
  it uses and their fitness; recomputed when the capability cache
  changes; the refresh button.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.Test.FakeAITasks

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

    task = "#ai-task-test-photo"
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
    assert has_element?(view, "#ai-task-ai-translation")
    assert has_element?(view, "#ai-task-ai-playground")
  end

  test "greys out a task of a switched-off module", %{conn: conn} do
    Application.put_env(:phoenix_kit_ai, :fake_ai_tasks_enabled, false)
    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    assert has_element?(view, "#ai-task-test-photo [data-module-off]")
    refute has_element?(view, "#ai-task-ai-playground [data-module-off]")
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
