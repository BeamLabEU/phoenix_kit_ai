defmodule PhoenixKitAI.CapabilitiesServerTest do
  @moduledoc """
  The capability cache as a process: the snapshot it starts from, a refresh
  from the catalogues of the endpoints' providers (OpenRouter, Anthropic), a
  failed refresh that keeps what it had and tries again, one fetch for many
  concurrent misses, the refresh a saved endpoint asks for, and the broadcast
  after each refresh. HTTP goes to `Req.Test` stubs only.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.ModelCapability
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @openrouter "https://openrouter.ai/api/v1"
  @anthropic "https://api.anthropic.com/v1"

  @openrouter_models [
    %{
      "id" => "~google/gemini-flash-latest",
      "name" => "Gemini Flash",
      "context_length" => 1_048_576,
      "architecture" => %{
        "input_modalities" => ["text", "image", "video", "file", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["tools", "response_format", "structured_outputs"]
    },
    %{
      "id" => "~deepseek/deepseek-v4-flash-latest",
      "name" => "DeepSeek V4 Flash",
      "context_length" => 163_840,
      "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
      "supported_parameters" => ["tools", "response_format"]
    },
    %{
      "id" => "openai/gpt-image-1",
      "name" => "GPT Image",
      "architecture" => %{"modality" => "text+image->text+image"},
      "supported_parameters" => []
    }
  ]

  setup do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    {:ok, stub: stub}
  end

  # The process under test, with the timers the test wants. Endpoints are
  # created before it starts, so their saves do not ask it for a refresh.
  defp start_cache(stub, opts \\ []) do
    opts =
      Keyword.merge(
        [initial_refresh: :never, refresh_interval: :infinity, retry_interval: :infinity],
        opts
      )

    pid = start_supervised!({Capabilities, opts})
    Req.Test.allow(stub, self(), pid)
    # The snapshot is loaded right after init; wait for it.
    _ = :sys.get_state(pid)
    pid
  end

  defp openrouter_endpoint(model, attrs \\ %{}) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Caps #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: model,
            api_key: "sk-or-v1-test-key"
          },
          attrs
        )
      )

    endpoint
  end

  defp openrouter_ok(conn, test_pid) do
    send(test_pid, {:models_requested, conn.host})
    Req.Test.json(conn, %{"data" => @openrouter_models})
  end

  defp snapshot_rows do
    TestRepo.all(from(c in ModelCapability, order_by: [c.base_url, c.model]))
  end

  defp seed_snapshot(base_url, model, flags) do
    TestRepo.insert!(
      struct(
        %ModelCapability{
          base_url: base_url,
          model: model,
          vision: "unknown",
          tools: "unknown",
          json_schema: "unknown",
          json: "unknown",
          fetched_at: ~U[2026-10-01 00:00:00Z]
        },
        flags
      )
    )
  end

  describe "a refresh from OpenRouter" do
    test "puts the whole catalogue in the cache and snapshots the endpoints' models", %{
      stub: stub
    } do
      openrouter_endpoint("~google/gemini-flash-latest")
      openrouter_endpoint("~deepseek/deepseek-v4-flash-latest")
      test_pid = self()
      Req.Test.stub(stub, &openrouter_ok(&1, test_pid))
      start_cache(stub)

      assert :ok = Capabilities.refresh()

      assert %Capabilities{
               vision: :yes,
               tools: :yes,
               json_schema: :yes,
               context_length: 1_048_576
             } =
               Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")

      assert %Capabilities{vision: :no, json_schema: :no, json: :yes} =
               Capabilities.lookup(@openrouter, "~deepseek/deepseek-v4-flash-latest")

      # In the cache though no endpoint uses it — the form's badges read it.
      assert %Capabilities{} = Capabilities.lookup(@openrouter, "openai/gpt-image-1")

      assert [
               %ModelCapability{model: "~deepseek/deepseek-v4-flash-latest", vision: "no"},
               %ModelCapability{
                 base_url: @openrouter,
                 model: "~google/gemini-flash-latest",
                 vision: "yes",
                 tools: "yes",
                 json_schema: "yes",
                 json: "yes",
                 context_length: 1_048_576,
                 fetched_at: %DateTime{}
               }
             ] = snapshot_rows()
    end

    test "an endpoint with an empty base URL is keyed by the provider's default", %{stub: stub} do
      endpoint = openrouter_endpoint("~google/gemini-flash-latest")

      TestRepo.update_all(from(e in Endpoint, where: e.uuid == ^endpoint.uuid),
        set: [base_url: nil]
      )

      test_pid = self()
      Req.Test.stub(stub, &openrouter_ok(&1, test_pid))
      start_cache(stub)

      assert :ok = Capabilities.refresh()
      assert [%ModelCapability{base_url: @openrouter}] = snapshot_rows()

      endpoint = TestRepo.get!(Endpoint, endpoint.uuid)
      assert endpoint.base_url == nil
      assert %Capabilities{vision: :yes} = Capabilities.for_endpoint(endpoint)
    end

    test "a provider without a catalogue is not asked and stays unknown unless declared", %{
      stub: stub
    } do
      {:ok, plain} =
        PhoenixKitAI.create_endpoint(%{
          name: "Mistral #{System.unique_integer([:positive])}",
          provider: "mistral",
          base_url: "https://api.mistral.ai/v1",
          model: "pixtral-large-latest",
          api_key: "mistral-test-key"
        })

      {:ok, declared} =
        PhoenixKitAI.create_endpoint(%{
          name: "Mistral declared #{System.unique_integer([:positive])}",
          provider: "mistral",
          base_url: "https://api.mistral.ai/v1",
          model: "pixtral-large-latest",
          api_key: "mistral-test-key",
          provider_settings: %{
            "capabilities" => %{"model" => "pixtral-large-latest", "vision" => "yes"}
          }
        })

      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:models_requested, conn.host})
        Plug.Conn.send_resp(conn, 500, "")
      end)

      start_cache(stub)

      assert :ok = Capabilities.refresh()
      refute_received {:models_requested, _}

      assert Capabilities.for_endpoint(plain) == :unknown

      assert %Capabilities{vision: :yes, tools: :unknown, source: :declared} =
               Capabilities.for_endpoint(declared)

      assert snapshot_rows() == []
    end

    test "is broadcast with the base URLs it refreshed", %{stub: stub} do
      openrouter_endpoint("~google/gemini-flash-latest")
      test_pid = self()
      Req.Test.stub(stub, &openrouter_ok(&1, test_pid))
      start_cache(stub)
      Capabilities.subscribe()

      assert :ok = Capabilities.refresh()
      assert_receive {:capabilities_refreshed, [@openrouter]}
    end
  end

  describe "the snapshot" do
    test "fills the cache at start, before any network", %{stub: stub} do
      seed_snapshot(@openrouter, "~google/gemini-flash-latest", vision: "yes", json_schema: "no")
      start_cache(stub)

      assert %Capabilities{vision: :yes, json_schema: :no, tools: :unknown, source: :catalogue} =
               Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")
    end

    test "is kept when the catalogue cannot be fetched, and the fetch is tried again", %{
      stub: stub
    } do
      openrouter_endpoint("~google/gemini-flash-latest")
      seed_snapshot(@openrouter, "~google/gemini-flash-latest", vision: "yes")
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:models_requested, conn.host})
        Plug.Conn.send_resp(conn, 503, "")
      end)

      start_cache(stub, retry_interval: 50)

      assert {:error, _reason} = Capabilities.refresh()
      assert_received {:models_requested, "openrouter.ai"}

      assert %Capabilities{vision: :yes} =
               Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")

      assert [%ModelCapability{vision: "yes"}] = snapshot_rows()

      # The retry, a minute later in production.
      assert_receive {:models_requested, "openrouter.ai"}, 1_000
    end

    test "a later refresh succeeds where the first one failed", %{stub: stub} do
      openrouter_endpoint("~google/gemini-flash-latest")
      test_pid = self()
      counter = :counters.new(1, [])

      Req.Test.stub(stub, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          Plug.Conn.send_resp(conn, 503, "")
        else
          openrouter_ok(conn, test_pid)
        end
      end)

      start_cache(stub)

      assert {:error, _} = Capabilities.refresh()
      assert Capabilities.lookup(@openrouter, "~google/gemini-flash-latest") == :unknown

      assert :ok = Capabilities.refresh()

      assert %Capabilities{vision: :yes} =
               Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")
    end
  end

  describe "single flight" do
    # A stub that reports each request and holds it until released, so the
    # test can pile callers onto one fetch in flight.
    defp blocking_stub(stub) do
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        send(test_pid, {:models_requested, self()})

        receive do
          :release -> Req.Test.json(conn, %{"data" => @openrouter_models})
        after
          5_000 -> Plug.Conn.send_resp(conn, 504, "")
        end
      end)
    end

    test "many concurrent misses make one fetch, and each miss answers unknown at once", %{
      stub: stub
    } do
      openrouter_endpoint("~google/gemini-flash-latest")
      blocking_stub(stub)
      start_cache(stub)
      Capabilities.subscribe()

      answers =
        1..20
        |> Task.async_stream(fn _ ->
          Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")
        end)
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.uniq(answers) == [:unknown]

      assert_receive {:models_requested, fetcher}, 1_000
      refute_receive {:models_requested, _}, 200

      send(fetcher, :release)
      assert_receive {:capabilities_refreshed, [@openrouter]}, 1_000

      assert %Capabilities{vision: :yes} =
               Capabilities.lookup(@openrouter, "~google/gemini-flash-latest")

      # A model the catalogue does not have does not start another fetch
      # right after one finished.
      assert Capabilities.lookup(@openrouter, "no/such-model") == :unknown
      refute_receive {:models_requested, _}, 200
    end

    test "concurrent refresh calls share one fetch and all get its answer", %{stub: stub} do
      openrouter_endpoint("~google/gemini-flash-latest")
      blocking_stub(stub)
      start_cache(stub)

      callers = for _ <- 1..5, do: Task.async(fn -> Capabilities.refresh() end)

      assert_receive {:models_requested, fetcher}, 1_000
      refute_receive {:models_requested, _}, 200
      send(fetcher, :release)

      assert Enum.map(callers, &Task.await/1) == List.duplicate(:ok, 5)
    end
  end

  describe "a saved endpoint" do
    test "has its model's capabilities fetched and snapshotted right away", %{stub: stub} do
      test_pid = self()
      Req.Test.stub(stub, &openrouter_ok(&1, test_pid))
      start_cache(stub)
      Capabilities.subscribe()

      openrouter_endpoint("~google/gemini-flash-latest")

      assert_receive {:models_requested, "openrouter.ai"}, 1_000
      assert_receive {:capabilities_refreshed, [@openrouter]}, 1_000

      assert [%ModelCapability{model: "~google/gemini-flash-latest", vision: "yes"}] =
               snapshot_rows()
    end

    test "a model change asks again; a rename does not", %{stub: stub} do
      endpoint = openrouter_endpoint("~deepseek/deepseek-v4-flash-latest")
      test_pid = self()
      Req.Test.stub(stub, &openrouter_ok(&1, test_pid))
      start_cache(stub)
      Capabilities.subscribe()

      {:ok, endpoint} =
        PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.name}"})

      refute_receive {:models_requested, _}, 200

      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{model: "~google/gemini-flash-latest"})
      assert_receive {:capabilities_refreshed, [@openrouter]}, 1_000
      assert [%ModelCapability{model: "~google/gemini-flash-latest"}] = snapshot_rows()
    end
  end

  describe "a refresh from Anthropic" do
    defp claude(id, overrides) do
      Map.merge(
        %{
          "id" => id,
          "type" => "model",
          "display_name" => id,
          "max_input_tokens" => 200_000,
          "max_tokens" => 64_000,
          "lifecycle" => "active",
          "capabilities" => %{"image_input" => %{"supported" => true}}
        },
        overrides
      )
    end

    test "reads every page, keeps null capabilities unknown and the lifecycle", %{stub: stub} do
      {:ok, _} =
        PhoenixKitAI.create_endpoint(%{
          name: "Claude #{System.unique_integer([:positive])}",
          provider: "anthropic",
          model: "claude-3-haiku-20240307",
          api_key: "sk-ant-test-key"
        })

      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:anthropic_page, conn.host, conn.query_params})

        case conn.query_params["after_id"] do
          nil ->
            Req.Test.json(conn, %{
              "data" => [
                claude("claude-opus-5-5", %{}),
                claude("claude-mystery", %{"capabilities" => nil})
              ],
              "has_more" => true,
              "last_id" => "claude-mystery"
            })

          "claude-mystery" ->
            Req.Test.json(conn, %{
              "data" => [claude("claude-3-haiku-20240307", %{"lifecycle" => "retired"})],
              "has_more" => false,
              "last_id" => "claude-3-haiku-20240307"
            })
        end
      end)

      start_cache(stub)

      assert :ok = Capabilities.refresh()
      assert_received {:anthropic_page, "api.anthropic.com", %{"limit" => "1000"} = first}
      refute Map.has_key?(first, "after_id")
      assert_received {:anthropic_page, "api.anthropic.com", %{"after_id" => "claude-mystery"}}

      assert %Capabilities{vision: :yes, tools: :yes, json_schema: :no, json: :yes} =
               Capabilities.lookup(@anthropic, "claude-opus-5-5")

      assert %Capabilities{vision: :unknown} = Capabilities.lookup(@anthropic, "claude-mystery")

      assert %Capabilities{lifecycle: :retired, context_length: 200_000} =
               Capabilities.lookup(@anthropic, "claude-3-haiku-20240307")

      assert [
               %ModelCapability{
                 base_url: @anthropic,
                 model: "claude-3-haiku-20240307",
                 lifecycle: "retired",
                 json_schema: "no"
               }
             ] = snapshot_rows()
    end
  end
end
