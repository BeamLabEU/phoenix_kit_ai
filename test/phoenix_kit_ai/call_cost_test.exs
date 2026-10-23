defmodule PhoenixKitAI.CallCostTest do
  @moduledoc """
  The cost of a call (`PhoenixKitAI.CallCost`), in US dollars — the unit of
  `Request.cost` — from the first source that has a price, in this
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
  @manual %{"input" => "1", "output" => "1.00"}

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

  # `{cost, metadata}` with the cost equal to `dollars` (a string), or nil.
  defp costs?({%Decimal{} = cost, meta}, dollars, meta_expected),
    do: Decimal.equal?(cost, Decimal.new(dollars)) and meta == meta_expected

  defp costs?(_result, _dollars, _meta), do: false

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  describe "for_call/5, the order of the sources" do
    test "the provider's reported cost comes first" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      reported = Decimal.new("0.000012345")

      assert ep
             |> CallCost.for_call("claude-sonnet-5-5", reported, 1_000, 500)
             |> costs?("0.000012345", %{cost_source: "provider"})
    end

    test "then the operator's catalogue price, over a manual price" do
      ep = openrouter_cache()

      # The catalogue's price is per TOKEN: 10 000 × $0.0000001 + 1 000 × $0.0000004
      # = $0.0014 (read as per 1M it would be a million times less).
      assert ep
             |> CallCost.for_call("vendor/priced", nil, 10_000, 1_000)
             |> costs?("0.0014", %{cost_source: "catalogue"})
    end

    test "then the manual price, over the built-in table" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      # The manual price is per 1M tokens: 1 500 × $1 / 1M = $0.0015.
      assert ep
             |> CallCost.for_call("claude-sonnet-5-5", nil, 1_000, 500)
             |> costs?("0.0015", %{cost_source: "manual"})
    end

    test "then Anthropic's table, per 1M tokens" do
      ep = endpoint(%{})

      # $2 and $10 per 1M: 1 000 in, 500 out = $0.007.
      assert ep
             |> CallCost.for_call("claude-sonnet-5-5", nil, 1_000, 500)
             |> costs?("0.007", %{cost_source: "table"})
    end

    test "nothing for a call without tokens, unless the provider reported a cost" do
      ep = endpoint(provider_settings: %{"pricing" => @manual})

      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, 0, 0) == {nil, %{}}
      assert CallCost.for_call(ep, "claude-sonnet-5-5", nil, nil, nil) == {nil, %{}}

      assert ep
             |> CallCost.for_call("claude-sonnet-5-5", Decimal.new(0), 0, 0)
             |> costs?("0", %{cost_source: "provider"})
    end

    test "nothing when no source prices the model" do
      ep = endpoint(provider: "zai", base_url: "https://api.z.ai/api/paas/v4", model: "glm-4.6")
      assert CallCost.for_call(ep, "glm-4.6", nil, 1_000, 500) == {nil, %{}}
    end
  end

  describe "for_call/5, the two price bases" do
    test "the same call is priced per token by the catalogue, per 1M by the others" do
      # 1 000 in, 500 out everywhere; a factor of a million lost on either
      # base would give a different answer than the one below.
      catalogue = openrouter_cache()

      assert catalogue
             |> CallCost.for_call("vendor/priced", nil, 1_000, 500)
             |> costs?("0.0003", %{cost_source: "catalogue"})

      assert endpoint(provider_settings: %{"pricing" => %{"input" => "0.1", "output" => "0.4"}})
             |> CallCost.for_call("claude-sonnet-5-5", nil, 1_000, 500)
             |> costs?("0.0003", %{cost_source: "manual"})

      assert endpoint(%{})
             |> CallCost.for_call("claude-sonnet-5-5", nil, 1_000, 500)
             |> costs?("0.007", %{cost_source: "table"})
    end
  end

  describe "for_call/5, the model" do
    test "is the one the answer names when a source prices it" do
      ep = endpoint(%{})

      # Claude Opus 4.6: $5 and $25 per 1M.
      assert ep
             |> CallCost.for_call("claude-opus-4-6", nil, 1_000, 500)
             |> costs?("0.0175", %{cost_source: "table"})
    end

    test "falls back to the endpoint's when no source prices the answer's" do
      ep = endpoint(%{})

      assert ep
             |> CallCost.for_call("claude-unpriced-9", nil, 1_000, 500)
             |> costs?("0.007", %{cost_source: "table"})

      assert ep
             |> CallCost.for_call(nil, nil, 1_000, 500)
             |> costs?("0.007", %{cost_source: "table"})
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

      assert %Request{cost: cost, metadata: %{"cost_source" => "table"}} = row(ep)
      assert dollars?(cost, "0.007")
    end

    test "an answer naming a model without a price is priced by the endpoint's model" do
      ep = endpoint(%{})
      stub_answer("claude-unpriced-9", %{"prompt_tokens" => 1_000, "completion_tokens" => 500})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert %Request{cost: cost, metadata: %{"cost_source" => "table"}} = row(ep)
      assert dollars?(cost, "0.007")
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

        assert %Request{cost: nil, metadata: metadata} = row(ep)
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

      assert %Request{cost: cost, metadata: %{"cost_source" => "provider"}} = row(ep)
      assert dollars?(cost, "0.01")
    end

    test "a reported float cost is stored as the decimal the provider wrote" do
      for {float, dollars} <- [{3.0e-5, "0.00003"}, {4.0e-8, "0.00000004"}, {0.1, "0.1"}] do
        ep = endpoint(%{})

        stub_answer("claude-sonnet-5-5", %{
          "prompt_tokens" => 1,
          "completion_tokens" => 1,
          "cost" => float
        })

        assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi #{float}")
        # exactly, not 0 (as millionths would make 4.0e-8) and not a binary tail
        assert %Request{cost: cost} = row(ep)
        assert Decimal.equal?(cost, Decimal.new(dollars)), "#{float} → #{inspect(cost)}"
      end
    end

    test "a provider's cost past the column's 10 places is rounded once, half up" do
      ep = endpoint(%{})

      stub_answer("claude-sonnet-5-5", %{
        "prompt_tokens" => 1,
        "completion_tokens" => 1,
        "cost" => 1.5e-10
      })

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      assert %Request{cost: cost} = row(ep)
      assert dollars?(cost, "0.0000000002")
    end
  end
end
