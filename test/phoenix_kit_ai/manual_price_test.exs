defmodule PhoenixKitAI.ManualPriceTest do
  @moduledoc """
  A price entered by hand on an endpoint whose provider gives none:
  `provider_settings["pricing"]`, US dollars per 1M input and output tokens
  as decimal strings. A call whose provider reports no `usage.cost` gets its
  `cost` from it, marked `cost_source: "manual"`; a
  reported cost wins; no price leaves the cost unknown as before. A change
  of the price is in the Activity log. Provider calls are `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{ManualPrice, Money, Request, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  # $0.60 per 1M input tokens, $2.20 per 1M output tokens.
  @pricing %{"input" => "0.60", "output" => "2.20"}

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

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  defp price(input, output), do: %{"input" => Decimal.new(input), "output" => Decimal.new(output)}

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
    test "is dollars: tokens times dollars per 1M, over a million, not rounded" do
      pricing = price("0.60", "2.20")
      # 1000 × 0.60 $/1M + 500 × 2.20 $/1M = $0.0006 + $0.0011 = $0.0017.
      assert dollars?(ManualPrice.cost(pricing, 1_000, 500), "0.0017")
      # One token of each is not $0.
      assert dollars?(ManualPrice.cost(pricing, 1, 1), "0.0000028")
      # 3 tokens at $0.0003 per 1M: $0.0000000009, kept to the last digit here
      # (a call's total is rounded once, by CallCost).
      assert dollars?(ManualPrice.cost(price("0.0003", "0"), 3, 0), "0.0000000009")
      assert dollars?(ManualPrice.cost(pricing, 0, 0), "0")
    end

    test "is nil without a price" do
      assert ManualPrice.cost(nil, 1_000, 500) == nil
    end
  end

  describe "Money.parse_dollars/1" do
    test "reads dollars, refusing NaN, infinity and negatives" do
      assert {:ok, d} = Money.parse_dollars("0.60")
      assert dollars?(d, "0.6")
      assert {:ok, d} = Money.parse_dollars("2.2")
      assert dollars?(d, "2.2")
      assert {:ok, d} = Money.parse_dollars("0")
      assert dollars?(d, "0")
      # a price below a millionth is a price now, not 0
      assert {:ok, d} = Money.parse_dollars("0.0000004")
      assert dollars?(d, "0.0000004")

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
      assert dollars?(row.cost, "0.0017")
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
      assert dollars?(row.cost, "0.01")
      assert row.metadata["cost_source"] == "provider"
    end

    test "stays unknown without a price, as before" do
      endpoint = endpoint(%{})
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "q")

      row = last_row(endpoint)
      assert row.cost == nil
      refute Map.has_key?(row.metadata, "cost_source")
    end

    test "counts for the money limits once a price is set" do
      refute TaskLimits.money_counted?(endpoint(%{}))
      assert TaskLimits.money_counted?(endpoint(%{"pricing" => @pricing}))
    end
  end

  describe "the stored price" do
    test "must be two non-negative dollar strings" do
      # A number (a float would read back as one; an integer is the released
      # millionths) is refused, as is a negative, half a price, or garbage.
      for bad <- [
            %{"input" => 0.6, "output" => "2.2"},
            %{"input" => 600_000, "output" => 2_200_000},
            %{"input" => "-1", "output" => "2.2"},
            %{"input" => "x", "output" => "2.2"},
            %{"output" => "2.2"},
            "cheap"
          ] do
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
          %{provider_settings: %{"pricing" => %{"input" => "0.7", "output" => "2.20"}}},
          scope: owner()
        )

      assert_activity_logged("endpoint.pricing_changed",
        resource_uuid: endpoint.uuid,
        metadata_has: %{
          "input_before" => "0.60",
          "input_after" => "0.70",
          "output_before" => "2.20",
          "output_after" => "2.20"
        }
      )
    end

    test "an update that leaves the price as it is logs no price change" do
      endpoint = endpoint(%{"pricing" => @pricing})
      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.uuid}"})

      # The creation's entry has no price before; an update's would.
      refute_activity_logged("endpoint.pricing_changed",
        resource_uuid: endpoint.uuid,
        metadata_has: %{"input_before" => "0.60"}
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
      assert last_row(endpoint).cost == nil
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
      for half <- [%{"input" => "0.60"}, %{"output" => "2.20"}] do
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
        provider_settings: %{"pricing" => %{"model" => "glm-4.6", "input" => "0.60"}}
      }

      assert ManualPrice.get(half) == nil
      refute PhoenixKitAI.CallCost.reports_cost?(half)
    end
  end

  describe "the upper bound" do
    test "is $10 000 per 1M tokens" do
      ok = %{"input" => "10000", "output" => "10000.00"}

      assert %{"input" => "10000"} = endpoint(%{"pricing" => ok}).provider_settings["pricing"]

      assert {:error, changeset} =
               PhoenixKitAI.create_endpoint(
                 %{
                   name: "Dear #{System.unique_integer([:positive])}",
                   provider: "zai",
                   model: "glm-4.6",
                   provider_settings: %{"pricing" => %{ok | "input" => "10000.000001"}}
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
      # 1 000 × $0.60 per 1M = $0.0006.
      assert dollars?(row.cost, "0.0006")
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
            select: {r.cost, fragment("?->>'cached'", r.metadata)}
          )
        )

      assert Enum.any?(costs, fn {cost, cached} -> cached == nil and dollars?(cost, "0.0017") end)
      assert Enum.any?(costs, fn {cost, cached} -> cached == "true" and dollars?(cost, "0") end)
    end

    test "the daily budget counts it" do
      endpoint = endpoint(%{"pricing" => @pricing})
      # $0.001: the first call ($0.0017) reaches it
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:endpoint, "0.001")
      on_exit(fn -> PhoenixKitAI.Budget.set_limit(:endpoint, 0) end)
      stub_chat(%{"prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500})

      assert {:ok, _} = PhoenixKitAI.ask(endpoint.uuid, "first")
      assert {:error, {:budget_exceeded, :endpoint}} = PhoenixKitAI.ask(endpoint.uuid, "second")
    end
  end

  describe "a database whose costs are not in dollars yet" do
    # A legacy cost column beside `cost` (a schema repair on a database stamped
    # by an unreleased V223 would leave one) means past costs are not in
    # `cost`: no call may run until they are. Added inside the test's
    # transaction, so the database is left as it was.
    test "refuses every call before the provider while a legacy cost column is left" do
      endpoint = endpoint(%{})
      :persistent_term.erase({Money, :ready})
      TestRepo.query!("ALTER TABLE phoenix_kit_ai_requests ADD COLUMN cost_nanodollars bigint")
      on_exit(fn -> :persistent_term.erase({Money, :ready}) end)

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :provider_called)
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "x"}}]})
      end)

      refute Money.ready?()
      assert {:error, :money_migration_required} = PhoenixKitAI.ask(endpoint.uuid, "q")
      refute_received :provider_called

      TestRepo.query!("ALTER TABLE phoenix_kit_ai_requests DROP COLUMN cost_nanodollars")
      assert Money.ready?()
    end
  end

  describe "a price still in the released millionths" do
    test "refuses the endpoint's calls before the provider, and is no price" do
      endpoint = endpoint(%{"pricing" => @pricing})

      # As the released versions stored it (whole micro-dollars per 1M); the
      # changeset refuses that shape, so it is written straight to the table.
      legacy = %{"model" => "glm-4.6", "input" => 600_000, "output" => 2_200_000}

      {1, _} =
        TestRepo.update_all(
          from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^endpoint.uuid),
          set: [provider_settings: %{"pricing" => legacy}]
        )

      PhoenixKitAI.Cache.clear()
      stale = PhoenixKitAI.get_endpoint(endpoint.uuid)
      assert ManualPrice.legacy?(stale)
      assert ManualPrice.get(stale) == nil

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :provider_called)
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "x"}}]})
      end)

      assert {:error, :money_migration_required} = PhoenixKitAI.ask(endpoint.uuid, "q")
      refute_received :provider_called
      assert PhoenixKitAI.Errors.message(:money_migration_required) =~ "update"
    end
  end

  describe "money_counted?/2 for a task's needs" do
    test "a manual price counts for chat and for reading images, not for making them" do
      priced = endpoint(%{"pricing" => @pricing})

      assert TaskLimits.money_counted?(priced, [])
      assert TaskLimits.money_counted?(priced, [:json_schema])
      assert TaskLimits.money_counted?(priced, [:vision])
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
