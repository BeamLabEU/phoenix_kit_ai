defmodule PhoenixKitAI.PlainCatalogueTest do
  @moduledoc """
  Direct operators without a capability catalogue (OpenAI, xAI, Z.ai): the
  capability cache keeps the plain list of model ids their `/models`
  returns, every capability unknown and no price, and the recommendations
  list those models as «may be able to», marked that the operator does not
  report capabilities — never as verified, never hidden by a capability
  filter, after the models anything is known about. Z.ai's `/models` is
  stubbed in its own shape. No network.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Capabilities, ModelCapability, Recommendations, Tasks}
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.Web.Components.RecommendationsPanel

  @zai "https://api.z.ai/api/paas/v4"
  @openrouter "https://openrouter.ai/api/v1"

  @glm ~w(glm-4.5 glm-4.5-air glm-4.5-x glm-4.5-airx glm-4.5-flash glm-4.5v
          glm-4.6 glm-4.6v glm-4-32b-0414-128k glm-z1-air glm-z1-flash)

  setup do
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      :persistent_term.erase({PhoenixKitAI.Tasks, :registry})
      ModuleRegistry.unregister(FakeAITasks)
    end)

    :ok
  end

  # The cache, refreshed once from a stubbed Z.ai `/models` behind one
  # endpoint (optionally with a declaration).
  defp zai_cache(provider_settings \\ %{}) do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:fetched, conn.host, conn.request_path})

      Req.Test.json(conn, %{
        "object" => "list",
        "data" =>
          Enum.map(
            @glm,
            &%{"id" => &1, "object" => "model", "created" => 1, "owned_by" => "z-ai"}
          )
      })
    end)

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Z EP #{System.unique_integer([:positive])}",
        provider: "zai",
        base_url: @zai,
        model: "glm-4.5v",
        api_key: "zai-test-key",
        provider_settings: provider_settings
      })

    pid =
      start_supervised!(
        {Capabilities, [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
      )

    Req.Test.allow(stub, self(), pid)
    assert :ok = Capabilities.refresh()

    endpoint
  end

  describe "source_kind/2" do
    test "is :plain for the direct operators, by provider key or by host" do
      assert Capabilities.source_kind("zai", @zai) == :plain
      assert Capabilities.source_kind(nil, @zai) == :plain
      assert Capabilities.source_kind("openai", "https://api.openai.com/v1") == :plain
      assert Capabilities.source_kind("xai", "https://api.x.ai/v1") == :plain
    end

    test "is the catalogue kind for the operators with a catalogue, unchanged" do
      assert Capabilities.source_kind("openrouter", @openrouter) == :openrouter
      assert Capabilities.source_kind("mistral", "https://api.mistral.ai/v1") == :mistral
      assert Capabilities.source_kind("anthropic", "https://api.anthropic.com/v1") == :anthropic
      assert Capabilities.source_kind("deepseek", "https://api.deepseek.com") == :deepseek
      assert Capabilities.catalogue_kind("zai", @zai) == nil
    end
  end

  describe "the capability cache" do
    test "keeps Z.ai's plain list: every id, nothing known, no price" do
      zai_cache()

      assert_received {:fetched, "api.z.ai", "/api/paas/v4/models"}

      catalogue = Capabilities.catalogue(@zai)
      assert catalogue |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(@glm)

      for {_id, caps} <- catalogue do
        assert %Capabilities{prompt_price: nil, completion_price: nil, context_length: nil} = caps

        for flag <- Capabilities.declarable() do
          assert Map.fetch!(caps, flag) == :unknown
        end
      end
    end

    test "snapshots the endpoint's model as it does for a catalogue" do
      zai_cache()

      assert %ModelCapability{vision: "unknown"} =
               TestRepo.get_by(ModelCapability, base_url: @zai, model: "glm-4.5v")
    end

    test "an endpoint's declaration still counts for its model" do
      endpoint =
        zai_cache(%{"capabilities" => %{"model" => "glm-4.5v", "vision" => "yes"}})

      assert Tasks.assess(Capabilities.for_endpoint(endpoint), [:vision]) == :fit
      assert Tasks.assess(Capabilities.for_endpoint(endpoint), [:tools]) == {:unknown, [:tools]}
    end
  end

  describe "the recommendations" do
    test "list the plain models as possible, marked, never verified" do
      zai_cache()

      for key <- ["test.sized", "test.plain"] do
        recs = Recommendations.for_task(key, limit: 20)

        refute Enum.any?(recs.verified, &(&1.base_url == @zai)), key
        plain = Enum.filter(recs.possible, &(&1.base_url == @zai))
        assert length(plain) == length(@glm) or length(plain) == 20, key

        for row <- plain do
          assert :capabilities_not_reported in row.notes
          assert row.provider == "zai"
          assert row.price_per_call == nil
        end
      end
    end

    test "a capability filter does not hide them: «?» is not «no»" do
      zai_cache()

      recs = Recommendations.for_task("test.sized", filters: [:vision, :file_input], limit: 20)
      assert Enum.any?(recs.possible, &(&1.base_url == @zai))
    end

    test "come after the models anything is known about" do
      known = %Capabilities{vision: :unknown, tools: :yes, text_output: true}
      plain = %Capabilities{}

      catalogue = [
        %{
          base_url: @zai,
          kind: :plain,
          integration_uuid: nil,
          provider: "zai",
          models: [{"glm-a", plain}]
        },
        %{
          base_url: @openrouter,
          kind: :openrouter,
          integration_uuid: nil,
          models: [{"v/priced", %{known | prompt_price: 1.0e-7, completion_price: 1.0e-7}}]
        },
        # Mistral lists no prices: unpriced, but its catalogue says something.
        %{
          base_url: "https://api.mistral.ai/v1",
          kind: :mistral,
          integration_uuid: nil,
          models: [{"mistral-unpriced", known}]
        }
      ]

      recs = Recommendations.ranked("test.sized", catalogue: catalogue, limit: 10)

      assert Enum.map(recs.possible, & &1.model) == ["v/priced", "mistral-unpriced", "glm-a"]
    end

    test "leave out a plain list's models that do not chat, image models unless images are made" do
      ids =
        ~w(gpt-4o text-embedding-3-small tts-1 gpt-4o-mini-tts whisper-1 omni-moderation-latest
           dall-e-3 gpt-image-1)

      catalogue = [
        %{
          base_url: "https://api.openai.com/v1",
          kind: :plain,
          integration_uuid: nil,
          provider: "openai",
          models: Enum.map(ids, &{&1, %Capabilities{}})
        }
      ]

      listed = fn key ->
        Recommendations.ranked(key, catalogue: catalogue, limit: 20).possible
        |> Enum.map(& &1.model)
        |> Enum.sort()
      end

      assert listed.("test.plain") == ["gpt-4o"]
      assert listed.("test.drawing") == ~w(dall-e-3 gpt-4o gpt-image-1)
    end

    test "for_tasks/2 still asks the journal twice in all" do
      catalogue = [
        %{
          base_url: @zai,
          kind: :plain,
          integration_uuid: nil,
          provider: "zai",
          models: [{"glm-a", %Capabilities{}}]
        }
      ]

      queries = :counters.new(1, [])
      handler = "plain-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix_kit_ai, :test, :repo, :query],
        fn _, _, _, _ -> :counters.add(queries, 1, 1) end,
        nil
      )

      Recommendations.for_tasks(["test.sized", "test.plain"], catalogue: catalogue)
      :telemetry.detach(handler)

      assert :counters.get(queries, 1) == 2
    end

    test "the block marks a plain model's row in words" do
      catalogue = [
        %{
          base_url: @zai,
          kind: :plain,
          integration_uuid: nil,
          provider: "openai",
          models: [{"glm-a", %Capabilities{}}]
        }
      ]

      recs = Recommendations.for_task("test.plain", catalogue: catalogue)

      html =
        render_component(RecommendationsPanel, id: "recs", recommendations: recs, scope: nil)

      assert html =~ ~s(data-note="capabilities_not_reported")
      assert html =~ "the operator does not report capabilities"
      assert html =~ "OpenAI"
    end
  end
end
