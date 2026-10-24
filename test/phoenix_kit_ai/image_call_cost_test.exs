defmodule PhoenixKitAI.ImageCallCostTest do
  @moduledoc """
  The cost of the image verbs. The vision verbs (`describe_image/3`,
  `extract_text/3`, `compare_images/4`) are chat calls with images and are
  priced like chat (`PhoenixKitAI.CallCost`): the provider's `usage.cost`,
  else a catalogue, the endpoint's manual or Anthropic's built-in price, for
  the model the answer names, else the model sent (the call's `model:`, else
  the endpoint's). Making images is priced per image or per call, so
  `generate_image/3` keeps only the provider's own cost. Calls are
  `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Request, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @anthropic "https://api.anthropic.com/v1"
  # $0.60 per 1M input tokens, $2.20 per 1M output tokens.
  @manual %{"input" => "0.60", "output" => "2.20"}
  @tokens %{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500}

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    # Setting a manual price needs ai.manage: the first user registered is
    # the Owner, whose scope the helpers pass.
    Process.put(:owner_scope, Scope.for_user(Fixtures.user_fixture()))
    :ok
  end

  defp endpoint(attrs) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Image cost #{System.unique_integer([:positive])}",
            provider: "zai",
            base_url: "https://api.z.ai/api/paas/v4",
            model: "glm-4.6",
            api_key: "zai-test-key"
          },
          Map.new(attrs)
        ),
        scope: Process.get(:owner_scope)
      )

    endpoint
  end

  defp manual_endpoint, do: endpoint(provider_settings: %{"pricing" => @manual})

  defp anthropic_endpoint,
    do: endpoint(provider: "anthropic", base_url: @anthropic, model: "claude-sonnet-5-5")

  defp stub_answer(content, extra) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(
        conn,
        Map.merge(
          %{"choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]},
          extra
        )
      )
    end)
  end

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  defp row(endpoint) do
    TestRepo.one!(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))
  end

  describe "the vision verbs are priced like chat" do
    test "describe_image on a manual price, the provider reporting no cost" do
      ep = manual_endpoint()
      stub_answer("A chair.", %{"usage" => @tokens})

      assert {:ok, %{text: "A chair."}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      # 1 000 × $0.60 + 500 × $2.20 per 1M = $0.0017.
      assert %Request{
               request_type: "vision",
               cost: cost,
               metadata: %{"cost_source" => "manual"}
             } = row(ep)

      assert dollars?(cost, "0.0017")
    end

    test "describe_image on Anthropic, from the built-in table" do
      ep = anthropic_endpoint()
      stub_answer("A chair.", %{"model" => "claude-sonnet-5-5", "usage" => @tokens})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      # $2 and $10 per 1M: 1 000 in, 500 out = $0.007.
      assert %Request{cost: cost, metadata: %{"cost_source" => "table"}} = row(ep)
      assert dollars?(cost, "0.007")
    end

    test "the provider's reported cost wins over a manual price" do
      ep = manual_endpoint()
      stub_answer("A chair.", %{"usage" => Map.put(@tokens, "cost", 0.0005)})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      assert %Request{cost: cost, metadata: %{"cost_source" => "provider"}} = row(ep)
      assert dollars?(cost, "0.0005")
    end

    test "an answer without usage, or without tokens, has no cost" do
      for usage <- [nil, %{}, %{"prompt_tokens" => 0, "completion_tokens" => 0}],
          ep <- [manual_endpoint(), anthropic_endpoint()] do
        stub_answer("A chair.", if(usage, do: %{"usage" => usage}, else: %{}))

        assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

        assert %Request{cost: nil, metadata: metadata} = row(ep)
        refute Map.has_key?(metadata, "cost_source")
      end
    end

    test "extract_text and compare_images are priced too" do
      ep = manual_endpoint()

      stub_answer(
        ~s({"text": "ok", "same_subject": true, "text_and_logos_preserved": true,
        "unwanted_changes": [], "summary": "same"}),
        %{"usage" => @tokens}
      )

      assert {:ok, _} = PhoenixKitAI.extract_text(ep.uuid, @jpeg)
      assert {:ok, _} = PhoenixKitAI.compare_images(ep.uuid, @jpeg, @jpeg)

      assert [{a, "manual"}, {b, "manual"}] =
               TestRepo.all(
                 from(r in Request,
                   where: r.endpoint_uuid == ^ep.uuid,
                   select: {r.cost, fragment("?->>'cost_source'", r.metadata)}
                 )
               )

      assert dollars?(a, "0.0017") and dollars?(b, "0.0017")
    end

    test "a prose answer to a JSON request is priced too" do
      ep = manual_endpoint()
      stub_answer("A chair.", %{"usage" => @tokens})

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, json: true)

      assert %Request{status: "success", cost: cost} = row(ep)
      assert dollars?(cost, "0.0017")
    end
  end

  describe "the model priced" do
    test "is the one the answer names when a source prices it" do
      ep = anthropic_endpoint()
      stub_answer("A chair.", %{"model" => "claude-opus-4-6", "usage" => @tokens})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      # Claude Opus 4.6: $5 and $25 per 1M.
      assert %Request{cost: cost, metadata: %{"cost_source" => "table"}} = row(ep)
      assert dollars?(cost, "0.0175")
    end

    test "else the call's model: override, not the endpoint's" do
      ep = anthropic_endpoint()
      stub_answer("A chair.", %{"usage" => @tokens})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, model: "claude-opus-4-6")

      assert %Request{cost: cost, metadata: %{"cost_source" => "table"}} = row(ep)
      assert dollars?(cost, "0.0175")
    end

    test "a manual price is its model's: a call sent to another model is not priced by it" do
      ep = manual_endpoint()
      stub_answer("A chair.", %{"usage" => @tokens})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, model: "glm-4.5v")

      assert %Request{cost: nil} = row(ep)
    end
  end

  describe "making images" do
    test "generate_image keeps the provider's own cost only" do
      ep =
        endpoint(
          provider: "openai",
          base_url: "https://api.openai.com/v1",
          model: "gpt-image-1",
          api_key: "sk-test",
          provider_settings: %{"pricing" => @manual}
        )

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"b64_json" => Base.encode64(@png)}],
          "usage" => %{"prompt_tokens" => 1_000, "completion_tokens" => 500}
        })
      end)

      assert {:ok, %{images: [_]}} = PhoenixKitAI.generate_image(ep.uuid, "a chair")

      assert %Request{request_type: "image", cost: nil, metadata: metadata} = row(ep)
      refute Map.has_key?(metadata, "cost_source")
    end
  end

  describe "money_counted?/2" do
    test "a task reading images counts like chat; one making images, the provider's cost only" do
      priced = manual_endpoint()
      table = anthropic_endpoint()
      unpriced = endpoint(%{})

      assert TaskLimits.money_counted?(priced, [:vision])
      assert TaskLimits.money_counted?(table, [:vision, :json_schema])
      refute TaskLimits.money_counted?(unpriced, [:vision])

      refute TaskLimits.money_counted?(priced, [:image_output])
      refute TaskLimits.money_counted?(priced, [:vision, :image_output])
      refute TaskLimits.money_counted?(table, [:image_output])
    end
  end

  describe "the daily budget" do
    test "counts a priced description" do
      ep = manual_endpoint()
      # $0.001: the first description ($0.0017) reaches it
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:endpoint, "0.001")
      on_exit(fn -> PhoenixKitAI.Budget.set_limit(:endpoint, 0) end)
      stub_answer("A chair.", %{"usage" => @tokens})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      assert {:error, {:budget_exceeded, :endpoint}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, prompt: "Again.")
    end
  end
end
