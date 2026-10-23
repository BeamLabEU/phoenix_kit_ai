defmodule PhoenixKitAI.CallCostTest do
  @moduledoc """
  The cost of a call (`PhoenixKitAI.CallCost`), in micro-dollars — the
  unit of `cost_cents` — from the first source that has a price, in this
  order: the provider's `usage.cost`, the operator's catalogue price, the
  endpoint's manual price, Anthropic's built-in rate table. The model is
  the one the answer names; a model no source prices falls back to the
  endpoint's. `PhoenixKitAI.reports_cost?/1` says whether any source prices
  the endpoint's model. Catalogues and calls are `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{CallCost, Capabilities, Request, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @anthropic "https://api.anthropic.com/v1"
  # $1 and $1 per 1M tokens.
  @manual %{"input" => 1_000_000, "output" => 1_000_000}

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :anthropic_prices)
    end)

    # Setting a manual price needs ai.manage: the first user registered is
    # the Owner, whose scope the helpers pass.
    Process.put(
      :owner_scope,
      Scope.for_user(Fixtures.user_fixture())
    )

    :ok
  end

  defp endpoint(attrs) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Cost #{System.unique_integer([:positive])}",
            provider: "anthropic",
            base_url: @anthropic,
            model: "claude-sonnet-5-5",
            api_key: "sk-ant-test"
          },
          Map.new(attrs)
        ),
        scope: Process.get(:owner_scope)
      )

    endpoint
  end

  # The capability cache, read once from a stubbed OpenRouter `/models` with
  # one priced model: $0.10 and $0.40 per 1M tokens.
  defp openrouter_cache do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "vendor/priced",
            "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
            "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]}
          }
        ]
      })
    end)

    endpoint =
      endpoint(
        provider: "openrouter",
        base_url: nil,
        model: "vendor/priced",
        api_key: "sk-or-test",
        provider_settings: %{"pricing" => @manual}
      )

    pid =
      start_supervised!(
        {Capabilities, [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    assert :ok = Capabilities.refresh()
    endpoint
  end

  describe "for_call/5, the order of the sources" do
    test "the provider's reported cost comes first" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      assert CallCost.for_call(ep, "claude-sonnet-5-5", 12_345, 1_000, 500) ==
               {12_345, %{cost_source: "provider"}}
    end

    test "then the operator's catalogue price, over a manual price" do
      ep = openrouter_cache()

      # 10 000 × 100 000 + 1 000 × 400 000 µ$ per 1M = 1 400 µ$ ($0.0014).
      assert CallCost.for_call(ep, "vendor/priced", nil, 10_000, 1_000) ==
               {1_400, %{cost_source: "catalogue"}}
    end

    test "then the manual price, over the built-in table" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      # 1 000 × 1 000 000 + 500 × 1 000 000 µ$ per 1M = 1 500 µ$.
      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, 1_000, 500) ==
               {1_500, %{cost_source: "manual"}}
    end

    test "then Anthropic's table, in micro-dollars" do
      ep = endpoint(%{})

      # $2 and $10 per 1M: 1 000 in, 500 out = $0.007 = 7 000 µ$.
      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, 1_000, 500) ==
               {7_000, %{cost_source: "table"}}
    end

    test "nothing for a call without tokens, unless the provider reported a cost" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, 0, 0) == {nil, %{}}
      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, nil, nil) == {nil, %{}}

      assert CallCost.for_call(ep, "claude-sonnet-5-5", 0, 0, 0) ==
               {0, %{cost_source: "provider"}}
    end

    test "nothing when no source prices the model" do
      ep = endpoint(provider: "zai", base_url: "https://api.z.ai/api/paas/v4", model: "glm-4.6")
      assert CallCost.for_call(ep, "glm-4.6", nil, 1_000, 500) == {nil, %{}}
    end
  end

  describe "for_call/5, the model" do
    test "is the one the answer names when a source prices it" do
      ep = endpoint(%{})

      # Claude Opus 4.6: $5 and $25 per 1M.
      assert CallCost.for_call(ep, "claude-opus-4-6", nil, 1_000, 500) ==
               {17_500, %{cost_source: "table"}}
    end

    test "falls back to the endpoint's when no source prices the answer's" do
      ep = endpoint(%{})

      assert CallCost.for_call(ep, "claude-unpriced-9", nil, 1_000, 500) ==
               {7_000, %{cost_source: "table"}}

      assert CallCost.for_call(ep, nil, nil, 1_000, 500) == {7_000, %{cost_source: "table"}}
    end
  end

  describe "reports_cost?/1" do
    test "is true where some source prices the endpoint's model" do
      assert PhoenixKitAI.reports_cost?(
               endpoint(provider: "openrouter", base_url: nil, model: "v/m")
             )

      assert PhoenixKitAI.reports_cost?(endpoint(%{}))

      zai = [provider: "zai", base_url: "https://api.z.ai/api/paas/v4", model: "glm-4.6"]
      refute PhoenixKitAI.reports_cost?(endpoint(zai))

      assert PhoenixKitAI.reports_cost?(
               endpoint(zai ++ [provider_settings: %{"pricing" => @manual}])
             )

      refute PhoenixKitAI.reports_cost?(endpoint(model: "claude-unpriced-9"))
    end

    test "is what the task limits count money by" do
      zai = endpoint(provider: "zai", base_url: "https://api.z.ai/api/paas/v4", model: "glm-4.6")
      assert TaskLimits.money_counted?(zai) == PhoenixKitAI.reports_cost?(zai)
      assert TaskLimits.money_counted?(endpoint(%{}))
    end
  end

  describe "a call's usage row" do
    defp stub_answer(model, usage) do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "model" => model,
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
          "usage" => usage
        })
      end)
    end

    defp row(ep) do
      TestRepo.one!(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
    end

    test "an Anthropic answer is priced from the table and says so" do
      ep = endpoint(%{})
      stub_answer("claude-sonnet-5-5", %{"prompt_tokens" => 1_000, "completion_tokens" => 500})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert %Request{cost_cents: 7_000, metadata: %{"cost_source" => "table"}} = row(ep)
    end

    test "an answer naming a model without a price is priced by the endpoint's model" do
      ep = endpoint(%{})
      stub_answer("claude-unpriced-9", %{"prompt_tokens" => 1_000, "completion_tokens" => 500})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert %Request{cost_cents: 7_000, metadata: %{"cost_source" => "table"}} = row(ep)
    end

    test "an answer without usage, or with an empty one, has no cost, not a priced $0" do
      for usage <- [nil, %{}],
          ep <- [endpoint(%{}), endpoint(provider_settings: %{"pricing" => @manual})] do
        Req.Test.stub(__MODULE__, fn conn ->
          Req.Test.json(
            conn,
            Map.merge(
              %{
                "model" => "claude-sonnet-5-5",
                "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
              },
              if(usage, do: %{"usage" => usage}, else: %{})
            )
          )
        end)

        assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

        assert %Request{cost_cents: nil, metadata: metadata} = row(ep)
        refute Map.has_key?(metadata, "cost_source")
      end
    end

    test "a reported cost is the provider's" do
      ep = endpoint(%{})

      stub_answer("claude-sonnet-5-5", %{
        "prompt_tokens" => 1_000,
        "completion_tokens" => 500,
        "cost" => 0.01
      })

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert %Request{cost_cents: 10_000, metadata: %{"cost_source" => "provider"}} = row(ep)
    end
  end
end
