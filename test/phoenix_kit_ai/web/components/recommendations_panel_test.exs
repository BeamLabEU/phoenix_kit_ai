defmodule PhoenixKitAI.Web.Components.RecommendationsPanelTest do
  @moduledoc """
  The recommendations block on the AI → Tasks page, live: the filters for
  images, documents and image generation (the task's needs at first), a
  click that regroups the models without the page reloading anything, and
  the groups in their order — worked, verified, possible, experimental
  (collapsed). The catalogue is a stubbed OpenRouter listing.
  """

  use PhoenixKitAI.LiveCase

  @moduletag :capture_log

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @photo "[data-task-key='test.sized']"

  defp model(id, inputs, outputs, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
        "architecture" => %{"input_modalities" => inputs, "output_modalities" => outputs},
        "supported_parameters" => ["tools", "structured_outputs"]
      },
      extra
    )
  end

  setup %{conn: conn} do
    :ok = ModuleRegistry.register(FakeAITasks)
    on_exit(fn -> ModuleRegistry.unregister(FakeAITasks) end)

    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    fixture_endpoint(name: "Catalogue EP", model: "v/sees")

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          model("v/sees", ["text", "image"], ["text"]),
          model("v/reads", ["text", "file"], ["text"]),
          model("v/sees-preview", ["text", "image"], ["text"]),
          # Says nothing about its inputs: neither yes nor no.
          %{
            "id" => "v/mystery",
            "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
            "architecture" => %{"output_modalities" => ["text"]}
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

    {:ok, conn: conn}
  end

  test "starts on the task's needs and shows the groups in order", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    TestRepo.insert!(%Request{
      model: "v/worked",
      status: "success",
      request_type: "chat",
      metadata: %{"task" => "test.sized"},
      inserted_at: now,
      updated_at: now
    })

    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    assert has_element?(view, "#{@photo} [data-filter=vision][aria-pressed=true]")
    assert has_element?(view, "#{@photo} [data-filter=file_input][aria-pressed=false]")
    assert has_element?(view, "#{@photo} [data-filter=image_output][aria-pressed=false]")

    assert has_element?(view, "#{@photo} [data-group=verified] [data-recommended-model='v/sees']")
    refute has_element?(view, "#{@photo} [data-recommended-model='v/reads']")

    assert has_element?(
             view,
             "#{@photo} [data-group=possible] [data-recommended-model='v/mystery'] [data-unverified]",
             "images"
           )

    assert has_element?(
             view,
             "#{@photo} details[data-group=experimental]:not([open]) [data-recommended-model='v/sees-preview']"
           )

    html = view |> element(@photo) |> render()

    positions =
      for marker <- [
            ~s(data-worked-model="v/worked"),
            "data-group=\"verified\"",
            "data-group=\"possible\"",
            "data-group=\"experimental\""
          ] do
        {index, _} = :binary.match(html, marker)
        index
      end

    assert positions == Enum.sort(positions)
  end

  test "a click on a filter regroups the models", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

    view |> element("#{@photo} [data-filter=vision]") |> render_click()
    view |> element("#{@photo} [data-filter=file_input]") |> render_click()

    assert has_element?(view, "#{@photo} [data-filter=file_input][aria-pressed=true]")
    assert has_element?(view, "#{@photo} [data-filter=vision][aria-pressed=false]")

    assert has_element?(
             view,
             "#{@photo} [data-group=verified] [data-recommended-model='v/reads']"
           )

    refute has_element?(view, "#{@photo} [data-group=verified] [data-recommended-model='v/sees']")

    # Another task's panel keeps its own filters.
    assert has_element?(
             view,
             "[data-task-key='test.photo'] [data-filter=vision][aria-pressed=true]"
           )

    # A re-render of the page keeps the person's choice.
    send(view.pid, {:capabilities_refreshed, ["https://openrouter.ai/api/v1"]})
    assert has_element?(view, "#{@photo} [data-filter=file_input][aria-pressed=true]")

    assert has_element?(
             view,
             "#{@photo} [data-group=verified] [data-recommended-model='v/reads']"
           )
  end
end
