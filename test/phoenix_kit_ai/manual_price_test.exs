defmodule PhoenixKitAI.ManualPriceTest do
  @moduledoc """
  A price entered by hand on an endpoint whose provider gives none:
  `provider_settings["pricing"]`, whole micro-dollars per 1M input and
  output tokens. A call whose provider reports no `usage.cost` gets its
  `cost_cents` (micro-dollars) from it, marked `cost_source: "manual"`; a
  reported cost wins; no price leaves the cost unknown as before. A change
  of the price is in the Activity log. Provider calls are `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{ManualPrice, Money, Request, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  # $0.60 per 1M input tokens, $2.20 per 1M output tokens.
  @pricing %{"input" => 600_000, "output" => 2_200_000}

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    # Setting a manual price needs ai.manage: the first user registered is
    # the Owner, whose scope the helpers pass.
    Process.put(
      :owner_scope,
      Scope.for_user(Fixtures.user_fixture())
    )

    :ok
  end

  defp owner, do: Process.get(:owner_scope)

  defp endpoint(provider_settings) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        %{
          name: "Priced #{System.unique_integer([:positive])}",
          provider: "zai",
          base_url: "https://api.z.ai/api/paas/v4",
          model: "glm-4.6",
          api_key: "zai-test-key",
          provider_settings: provider_settings
        },
        scope: owner()
      )

    endpoint
  end

  defp stub_chat(usage) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => usage
      })
    end)
  end

  defp last_row(endpoint) do
    TestRepo.one!(
      from(r in Request,
        where: r.endpoint_uuid == ^endpoint.uuid,
        order_by: [desc: r.inserted_at],
        limit: 1
      )
    )
  end

  describe "cost/3" do
    test "is micro-dollars: tokens times micro-dollars per 1M, over a million, rounded" do
      # 1000 × 0.60 $/1M + 500 × 2.20 $/1M = $0.0006 + $0.0011 = $0.0017.
      assert ManualPrice.cost(@pricing, 1_000, 500) == 1_700
      # (600 000 + 2 200 000) / 1 000 000 = 2.8 → 3.
      assert ManualPrice.cost(@pricing, 1, 1) == 3
      assert ManualPrice.cost(@pricing, 0, 0) == 0
    end

    test "is nil without a price" do
      assert ManualPrice.cost(nil, 1_000, 500) == nil
    end
  end

  describe "Money.parse_dollars/1" do
    test "reads dollars into micro-dollars, refusing NaN, infinity and negatives" do
      assert Money.parse_dollars("0.60") == {:ok, 600_000}
      assert Money.parse_dollars("2.2") == {:ok, 2_200_000}
      assert Money.parse_dollars("0") == {:ok, 0}

      for bad <- ["NaN", "nan", "inf", "Infinity", "-1", "abc", "1e400x"] do
        assert Money.parse_dollars(bad) == :error, bad
      end
    end
  end

  describe "a call's cost" do
    test "comes from the manual price when the provider reports none" do
      endpoint = endpoint(%{"pricing" => @pricing})
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "q")

      row = last_row(endpoint)
      assert row.cost_cents == 1_700
      assert row.metadata["cost_source"] == "manual"
    end

    test "is the provider's usage.cost when it reports one" do
      endpoint = endpoint(%{"pricing" => @pricing})

      stub_chat(%{
        "prompt_tokens" => 1_000,
        "completion_tokens" => 500,
        "total_tokens" => 1_500,
        "cost" => 0.01
      })

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "q")

      row = last_row(endpoint)
      assert row.cost_cents == 10_000
      assert row.metadata["cost_source"] == "provider"
    end

    test "stays unknown without a price, as before" do
      endpoint = endpoint(%{})
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "q")

      row = last_row(endpoint)
      assert row.cost_cents == nil
      refute Map.has_key?(row.metadata, "cost_source")
    end

    test "counts for the money limits once a price is set" do
      refute TaskLimits.money_counted?(endpoint(%{}))
      assert TaskLimits.money_counted?(endpoint(%{"pricing" => @pricing}))
    end
  end

  describe "the stored price" do
    test "must be whole non-negative micro-dollars" do
      for bad <- [%{"input" => 0.6}, %{"input" => -1}, %{"output" => "2.2"}, "cheap"] do
        assert {:error, changeset} =
                 PhoenixKitAI.create_endpoint(
                   %{
                     name: "Bad #{System.unique_integer([:positive])}",
                     provider: "zai",
                     model: "glm-4.6",
                     provider_settings: %{"pricing" => bad}
                   },
                   scope: owner()
                 )

        assert {message, _} = changeset.errors[:provider_settings], inspect(bad)
        refute message =~ "ai.manage"
      end
    end

    test "a change is in the Activity log with the price before and after" do
      endpoint = endpoint(%{"pricing" => @pricing})

      {:ok, _} =
        PhoenixKitAI.update_endpoint(
          endpoint,
          %{provider_settings: %{"pricing" => %{"input" => 700_000, "output" => 2_200_000}}},
          scope: owner()
        )

      assert_activity_logged("endpoint.pricing_changed",
        resource_uuid: endpoint.uuid,
        metadata_has: %{
          "input_before" => 600_000,
          "input_after" => 700_000,
          "output_before" => 2_200_000,
          "output_after" => 2_200_000
        }
      )
    end

    test "an update that leaves the price as it is logs no price change" do
      endpoint = endpoint(%{"pricing" => @pricing})
      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.uuid}"})

      # The creation's entry has no price before; an update's would.
      refute_activity_logged("endpoint.pricing_changed",
        resource_uuid: endpoint.uuid,
        metadata_has: %{"input_before" => 600_000}
      )
    end
  end

  describe "the price belongs to a model" do
    test "a stored price names the endpoint's model" do
      endpoint = endpoint(%{"pricing" => @pricing})

      assert endpoint.provider_settings["pricing"] ==
               Map.put(@pricing, "model", "glm-4.6")
    end

    test "a model change drops it, and the new model's calls are not priced by it" do
      endpoint = endpoint(%{"pricing" => @pricing})
      {:ok, endpoint} = PhoenixKitAI.update_endpoint(endpoint, %{model: "glm-4.5"})

      refute Map.has_key?(endpoint.provider_settings, "pricing")

      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})
      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "q")
      assert last_row(endpoint).cost_cents == nil
    end

    test "a price naming another model is dropped" do
      endpoint = endpoint(%{"pricing" => Map.put(@pricing, "model", "glm-other")})
      refute Map.has_key?(endpoint.provider_settings, "pricing")
    end

    test "a price read for another model than the endpoint's is no price" do
      stale = %{
        model: "glm-4.5",
        provider: "zai",
        base_url: nil,
        provider_settings: %{"pricing" => Map.put(@pricing, "model", "glm-4.6")}
      }

      assert ManualPrice.get(stale) == nil
      refute PhoenixKitAI.CallCost.reports_cost?(stale)
    end
  end

  describe "both halves of the price" do
    test "are required: half a price is refused" do
      for half <- [%{"input" => 600_000}, %{"output" => 2_200_000}] do
        assert {:error, changeset} =
                 PhoenixKitAI.create_endpoint(
                   %{
                     name: "Half #{System.unique_integer([:positive])}",
                     provider: "zai",
                     model: "glm-4.6",
                     provider_settings: %{"pricing" => half}
                   },
                   scope: owner()
                 )

        assert {message, _} = changeset.errors[:provider_settings], inspect(half)
        refute message =~ "ai.manage"
      end
    end

    test "half a price read from storage is no price and counts no money" do
      half = %{
        model: "glm-4.6",
        provider: "zai",
        base_url: nil,
        provider_settings: %{"pricing" => %{"model" => "glm-4.6", "input" => 600_000}}
      }

      assert ManualPrice.get(half) == nil
      refute PhoenixKitAI.CallCost.reports_cost?(half)
    end
  end

  describe "the upper bound" do
    test "is $10 000 per 1M tokens" do
      ok = %{"input" => 10_000_000_000, "output" => 10_000_000_000}

      assert %{"input" => 10_000_000_000} =
               endpoint(%{"pricing" => ok}).provider_settings["pricing"]

      assert {:error, changeset} =
               PhoenixKitAI.create_endpoint(
                 %{
                   name: "Dear #{System.unique_integer([:positive])}",
                   provider: "zai",
                   model: "glm-4.6",
                   provider_settings: %{"pricing" => %{ok | "input" => 10_000_000_001}}
                 },
                 scope: owner()
               )

      assert changeset.errors[:provider_settings]
    end
  end

  describe "where the manual cost goes" do
    test "an embedding is priced by its input tokens, marked manual" do
      endpoint = endpoint(%{"pricing" => @pricing})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1]}],
          "usage" => %{"prompt_tokens" => 1_000, "total_tokens" => 1_000}
        })
      end)

      assert {:ok, _} = PhoenixKitAI.embed(endpoint.uuid, "text")

      row = last_row(endpoint)
      # 1 000 × 600 000 µ$ per 1M = 600 µ$.
      assert row.cost_cents == 600
      assert row.metadata["cost_source"] == "manual"
    end

    test "a cached answer stays free" do
      endpoint = endpoint(%{"pricing" => @pricing})
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "same", cache: true)
      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "same", cache: true)

      costs =
        TestRepo.all(
          from(r in Request,
            where: r.endpoint_uuid == ^endpoint.uuid,
            order_by: r.inserted_at,
            select: {r.cost_cents, fragment("?->>'cached'", r.metadata)}
          )
        )

      assert {1_700, nil} in costs
      assert {0, "true"} in costs
    end

    test "the daily budget counts it" do
      endpoint = endpoint(%{"pricing" => @pricing})
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:endpoint, 1_000)
      on_exit(fn -> PhoenixKitAI.Budget.set_limit(:endpoint, 0) end)
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "first")
      assert {:error, {:budget_exceeded, :endpoint}} = PhoenixKitAI.ask(endpoint.uuid, "second")
    end
  end

  describe "money_counted?/2 for a task's needs" do
    test "a manual price counts for chat, not for a task that reads or makes images" do
      priced = endpoint(%{"pricing" => @pricing})

      assert TaskLimits.money_counted?(priced, [])
      assert TaskLimits.money_counted?(priced, [:json_schema])
      refute TaskLimits.money_counted?(priced, [:vision])
      refute TaskLimits.money_counted?(priced, [:image_output])
    end

    test "a provider that reports a call's cost counts for every task" do
      {:ok, openrouter} =
        PhoenixKitAI.create_endpoint(%{
          name: "OR #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "vendor/model",
          api_key: "sk-or-test"
        })

      assert TaskLimits.money_counted?(openrouter, [:vision])
    end
  end
end
