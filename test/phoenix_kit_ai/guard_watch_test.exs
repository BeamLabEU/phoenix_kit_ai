defmodule PhoenixKitAI.GuardWatchTest do
  @moduledoc """
  `model_unfit` events (`PhoenixKitAI.GuardWatch`): a task's endpoint whose
  model stops fitting — after a catalogue refresh, or after the endpoint is
  saved with another model — is one event a day per task and endpoint, and
  the watchers are told once. The catalogue is a `Req.Test` stub.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Capabilities, GuardEvent, GuardWatch}
  alias PhoenixKitAI.Test.FakeLimitTasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defp model(id, inputs) do
    %{
      "id" => id,
      "architecture" => %{"input_modalities" => inputs, "output_modalities" => ["text"]},
      "supported_parameters" => ["max_tokens"]
    }
  end

  setup do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    catalogue = start_supervised!({Agent, fn -> [model("vendor/eye", ["text", "image"])] end})

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{"data" => Agent.get(catalogue, & &1)})
    end)

    PhoenixKit.Notifications.enable_system()
    :ok = ModuleRegistry.register(FakeLimitTasks)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeLimitTasks)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :fake_limit_endpoints)
    end)

    owner = Fixtures.user_fixture()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Watched EP #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "vendor/eye",
        api_key: "sk-test-key"
      })

    Application.put_env(:phoenix_kit_ai, :fake_limit_endpoints, [endpoint.uuid])

    caps =
      start_supervised!(
        {Capabilities, [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
      )

    Req.Test.allow(stub, self(), caps)
    assert :ok = Capabilities.refresh()
    Capabilities.subscribe()

    # Each look of the watch is awaited by its telemetry event, never by
    # timing: the broadcast reaches the watch and the test independently.
    test_pid = self()
    handler = "guard-watch-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_ai, :guard_watch, :look],
      fn _event, _measurements, %{trigger: trigger}, _config ->
        send(test_pid, {:guard_watch_looked, trigger})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    watch = start_supervised!(GuardWatch)
    # The first look at the fitness is taken before any change.
    assert_receive {:guard_watch_looked, :first_look}

    {:ok, owner: owner, endpoint: endpoint, catalogue: catalogue, watch: watch}
  end

  defp unfit_events, do: TestRepo.all(from(e in GuardEvent, where: e.kind == "model_unfit"))

  defp refresh_with(catalogue, models, _watch) do
    Agent.update(catalogue, fn _ -> models end)
    assert :ok = Capabilities.refresh()
    assert_receive {:capabilities_refreshed, _}
    assert_receive {:guard_watch_looked, :capabilities}
  end

  test "a refresh that takes the images away is one event, and the watchers are told once",
       %{owner: owner, endpoint: ep, catalogue: catalogue, watch: watch} do
    assert unfit_events() == []

    refresh_with(catalogue, [model("vendor/eye", ["text"])], watch)

    assert [
             %GuardEvent{
               task_key: "test.vision",
               endpoint_uuid: endpoint_uuid,
               ref: %{"missing" => ["vision"]},
               dedupe_key: key
             } = event
           ] = unfit_events()

    assert endpoint_uuid == ep.uuid
    assert key =~ ~r/^model_unfit:test\.vision:#{ep.uuid}:\d{4}-\d{2}-\d{2}$/

    assert [%Notification{}] =
             TestRepo.all(from(n in Notification, where: n.recipient_uuid == ^owner.uuid))

    assert_activity_logged("guard.model_unfit", resource_uuid: event.uuid)

    # Fit again and unfit again the same day: still the one event.
    refresh_with(catalogue, [model("vendor/eye", ["text", "image"])], watch)
    refresh_with(catalogue, [model("vendor/eye", ["text"])], watch)
    assert [_] = unfit_events()
  end

  test "a refresh that changes nothing for the task is no event",
       %{catalogue: catalogue, watch: watch} do
    refresh_with(
      catalogue,
      [model("vendor/eye", ["text", "image"]), model("vendor/other", ["text"])],
      watch
    )

    assert unfit_events() == []
  end

  test "an endpoint already unfit when the watch starts is no event",
       %{catalogue: catalogue} do
    :ok = stop_supervised(GuardWatch)
    Agent.update(catalogue, fn _ -> [model("vendor/eye", ["text"])] end)
    assert :ok = Capabilities.refresh()
    assert_receive {:capabilities_refreshed, _}

    watch = start_supervised!(GuardWatch)
    assert_receive {:guard_watch_looked, :first_look}

    refresh_with(
      catalogue,
      [model("vendor/eye", ["text"]), model("vendor/other", ["text"])],
      watch
    )

    assert unfit_events() == []
  end

  test "saving the endpoint with a model that cannot see images is an event",
       %{endpoint: ep, catalogue: catalogue, watch: watch} do
    refresh_with(
      catalogue,
      [model("vendor/eye", ["text", "image"]), model("vendor/blind", ["text"])],
      watch
    )

    {:ok, _} = PhoenixKitAI.update_endpoint(ep, %{model: "vendor/blind"})
    assert_receive {:guard_watch_looked, :endpoint}

    assert [%GuardEvent{endpoint_uuid: endpoint_uuid}] = unfit_events()
    assert endpoint_uuid == ep.uuid
  end
end
