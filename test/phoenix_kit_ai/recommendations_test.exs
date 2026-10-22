defmodule PhoenixKitAI.RecommendationsTest do
  @moduledoc """
  The recommendations behind «Подходят и дешевле всего» and «Уже работали в
  этой задаче»: models of the catalogue fit for all the task's hard needs,
  ranked by the estimated price of one call (declared typical tokens, else
  the journal's median, else the input price alone), and the journal's
  per-model aggregate for the task over 30 days without the guard's refusals.
  Catalogue rows are injected or come from a stubbed OpenRouter listing; the
  journal is fixture rows. No network.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Capabilities, Recommendations, Request}
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @openrouter "https://openrouter.ai/api/v1"
  @anthropic "https://api.anthropic.com/v1"

  setup do
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      :persistent_term.erase({PhoenixKitAI.Tasks, :registry})
      ModuleRegistry.unregister(FakeAITasks)
    end)

    :ok
  end

  defp caps(attrs \\ []) do
    struct(
      %Capabilities{
        vision: :yes,
        tools: :yes,
        json_schema: :yes,
        json: :yes,
        text_output: true,
        context_length: 128_000
      },
      attrs
    )
  end

  defp source(models, attrs \\ []) do
    Map.merge(
      %{base_url: @openrouter, kind: :openrouter, integration_uuid: nil, models: models},
      Map.new(attrs)
    )
  end

  # A row of the journal.
  defp request(task, model, attrs \\ []) do
    {inserted_days_ago, attrs} = Keyword.pop(attrs, :days_ago, 1)
    {metadata, attrs} = Keyword.pop(attrs, :metadata, %{})

    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-inserted_days_ago * 86_400)
      |> DateTime.truncate(:second)

    TestRepo.insert!(
      struct(
        %Request{
          model: model,
          status: "success",
          request_type: "chat",
          input_tokens: 1_000,
          output_tokens: 100,
          total_tokens: 1_100,
          latency_ms: 500,
          cost_cents: 10_000,
          metadata: Map.put(metadata, "task", task),
          inserted_at: inserted_at,
          updated_at: inserted_at
        },
        attrs
      )
    )
  end

  describe "cheapest/2 with the task's declared typical tokens" do
    test "a zero row limit returns no models, including unpriced models" do
      catalogue = [
        source([
          {"v/paid", caps(prompt_price: 1.0e-6, completion_price: 1.0e-6)},
          {"v/unpriced", caps()}
        ])
      ]

      assert %{rows: []} = Recommendations.cheapest("test.sized", catalogue: catalogue, limit: 0)
    end

    test "ranks the fit models by the price of one call and leaves out the unfit" do
      # test.sized needs vision and declares {10_000, 1_000}.
      catalogue = [
        source([
          {"v/dear", caps(prompt_price: 3.0e-6, completion_price: 1.5e-5, name: "Dear")},
          {"v/cheap", caps(prompt_price: 1.0e-7, completion_price: 4.0e-7, name: "Cheap")},
          {"v/middle", caps(prompt_price: 5.0e-7, completion_price: 2.0e-6)},
          {"v/blind", caps(vision: :no, prompt_price: 1.0e-9, completion_price: 1.0e-9)},
          {"v/unsure", caps(vision: :unknown, prompt_price: 1.0e-9, completion_price: 1.0e-9)},
          {"v/embedder", caps(prompt_price: 1.0e-9, completion_price: 0.0, text_output: false)}
        ])
      ]

      assert %{estimate: :declared, tokens: {10_000, 1_000}, rows: rows} =
               Recommendations.cheapest("test.sized", catalogue: catalogue)

      assert Enum.map(rows, & &1.model) == ["v/cheap", "v/middle", "v/dear"]

      [cheap, middle, dear] = rows
      assert_in_delta cheap.price_per_call, 10_000 * 1.0e-7 + 1_000 * 4.0e-7, 1.0e-12
      assert_in_delta middle.price_per_call, 10_000 * 5.0e-7 + 1_000 * 2.0e-6, 1.0e-12
      assert_in_delta dear.price_per_call, 10_000 * 3.0e-6 + 1_000 * 1.5e-5, 1.0e-12
      assert dear.name == "Dear"
      assert cheap.provider == :openrouter
      assert cheap.context_length == 128_000
    end

    test "a free-text task takes every text model; a task that is unknown has no needs" do
      catalogue = [source([{"v/blind", caps(vision: :no, prompt_price: 1.0e-7)}])]

      assert %{rows: [%{model: "v/blind"}]} =
               Recommendations.cheapest("test.plain", catalogue: catalogue)

      assert %{rows: [%{model: "v/blind"}]} =
               Recommendations.cheapest("nobody.declares.this", catalogue: catalogue)
    end

    test "gives at most five rows" do
      models =
        for n <- 1..9, do: {"v/m#{n}", caps(prompt_price: n * 1.0e-7, completion_price: 0.0)}

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: [source(models)])
      assert Enum.map(rows, & &1.model) == ["v/m1", "v/m2", "v/m3", "v/m4", "v/m5"]
    end

    test "retired models are left out and deprecated ones are marked" do
      catalogue = [
        source(
          [
            {"claude-old", caps(lifecycle: :retired)},
            {"claude-leaving", caps(lifecycle: :deprecated)},
            {"claude-now", caps(lifecycle: :active)}
          ],
          base_url: @anthropic,
          kind: :anthropic
        )
      ]

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert Enum.sort(Enum.map(rows, & &1.model)) == ["claude-leaving", "claude-now"]
      assert Enum.find(rows, &(&1.model == "claude-leaving")).deprecated?
      refute Enum.find(rows, &(&1.model == "claude-now")).deprecated?
    end
  end

  describe "cheapest/2 for Anthropic" do
    test "has no price, says so, and keeps a place after the priced rows" do
      priced =
        for n <- 1..6, do: {"v/m#{n}", caps(prompt_price: n * 1.0e-7, completion_price: 0.0)}

      catalogue = [
        source(priced),
        source([{"claude-sonnet", caps(json_schema: :no, name: "Claude Sonnet")}],
          base_url: @anthropic,
          kind: :anthropic
        )
      ]

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert length(rows) == 5
      assert Enum.map(Enum.take(rows, 4), & &1.model) == ["v/m1", "v/m2", "v/m3", "v/m4"]

      claude = List.last(rows)
      assert claude.model == "claude-sonnet"
      assert claude.provider == :anthropic
      assert claude.price_per_call == nil
      assert claude.price_known? == false
      assert :cost_not_reported in claude.notes
      assert :json_schema_openrouter_only in claude.notes
    end

    test "is not mapped to an OpenRouter model of the same name" do
      catalogue = [
        source([
          {"anthropic/claude-sonnet", caps(prompt_price: 3.0e-6, completion_price: 1.5e-5)}
        ]),
        source([{"claude-sonnet", caps()}], base_url: @anthropic, kind: :anthropic)
      ]

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert %{price_per_call: nil} = Enum.find(rows, &(&1.model == "claude-sonnet"))
    end

    test "a model whose price the catalogue does not give is unpriced too" do
      catalogue = [source([{"v/free-form", caps(prompt_price: nil)}])]

      assert %{rows: [%{price_known?: false}]} =
               Recommendations.cheapest("test.sized", catalogue: catalogue)
    end
  end

  describe "cheapest/2 ranking details" do
    test "with a known call size, a model without an output price is unpriced and not first" do
      catalogue = [
        source([
          {"v/half", caps(prompt_price: 1.0e-7, completion_price: nil)},
          {"v/full", caps(prompt_price: 5.0e-7, completion_price: 2.0e-6)}
        ])
      ]

      assert %{rows: [first, second]} =
               Recommendations.cheapest("test.sized", catalogue: catalogue)

      assert first.model == "v/full"
      assert second.model == "v/half"
      assert second.price_per_call == nil
    end

    test "without a call size the input price decides, as before" do
      catalogue = [
        source([
          {"v/half", caps(prompt_price: 1.0e-7, completion_price: nil)},
          {"v/full", caps(prompt_price: 5.0e-7, completion_price: 2.0e-6)}
        ])
      ]

      assert %{estimate: :rough, rows: [%{model: "v/half"}, %{model: "v/full"}]} =
               Recommendations.cheapest("test.photo", catalogue: catalogue)
    end

    test "at most one free model, marked, ahead of the paid ones" do
      catalogue = [
        source([
          {"v/a:free", caps(prompt_price: 0.0, completion_price: 0.0)},
          {"v/b:free", caps(prompt_price: 0.0, completion_price: 0.0)},
          {"v/p1", caps(prompt_price: 1.0e-7, completion_price: 1.0e-7)},
          {"v/p2", caps(prompt_price: 2.0e-7, completion_price: 2.0e-7)},
          {"v/p3", caps(prompt_price: 3.0e-7, completion_price: 3.0e-7)}
        ])
      ]

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert Enum.map(rows, & &1.model) == ["v/a:free", "v/p1", "v/p2", "v/p3"]
      assert :free in hd(rows).notes
      refute Enum.any?(tl(rows), &(:free in &1.notes))
    end

    test "a model with a zero input price and an unknown output price is not free" do
      catalogue = [source([{"v/odd", caps(prompt_price: 0.0, completion_price: nil)}])]

      for task <- ["test.sized", "test.photo"] do
        assert %{rows: [row]} = Recommendations.cheapest(task, catalogue: catalogue)
        refute :free in row.notes
      end
    end

    test "the place kept for the unpriced goes to Anthropic before an OpenRouter model without a price" do
      priced =
        for n <- 1..6, do: {"v/m#{n}", caps(prompt_price: n * 1.0e-7, completion_price: 0.0)}

      catalogue = [
        source(priced ++ [{"z/no-price", caps(prompt_price: nil)}]),
        source([{"claude-a", caps()}], base_url: @anthropic, kind: :anthropic)
      ]

      assert %{rows: rows} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert List.last(rows).model == "claude-a"
    end

    test "a row carries the model's capabilities for the badges" do
      catalogue = [source([{"v/m", caps(prompt_price: 1.0e-7, completion_price: 0.0)}])]

      assert %{rows: [%{capabilities: %Capabilities{vision: :yes}}]} =
               Recommendations.cheapest("test.sized", catalogue: catalogue)
    end
  end

  describe "cheapest/2 notes" do
    test "an alias is noted: a tilde prefix or a -latest suffix" do
      catalogue = [
        source([
          {"~google/gemini-flash", caps(prompt_price: 1.0e-7, completion_price: 0.0)},
          {"v/thing-latest", caps(prompt_price: 2.0e-7, completion_price: 0.0)},
          {"v/pinned", caps(prompt_price: 3.0e-7, completion_price: 0.0)}
        ])
      ]

      assert %{rows: [a, b, c]} = Recommendations.cheapest("test.sized", catalogue: catalogue)
      assert :alias in a.notes
      assert :alias in b.notes
      refute :alias in c.notes
    end

    test "carries the integration the create button reuses" do
      catalogue = [
        source([{"v/m", caps(prompt_price: 1.0e-7, completion_price: 0.0)}],
          integration_uuid: "0191-integration",
          endpoint_uuid: "0191-source"
        )
      ]

      assert %{
               rows: [
                 %{
                   integration_uuid: "0191-integration",
                   base_url: @openrouter,
                   source_endpoint_uuid: "0191-source"
                 }
               ]
             } =
               Recommendations.cheapest("test.sized", catalogue: catalogue)
    end
  end

  describe "cheapest/2 without typical tokens: the journal's median" do
    defp models do
      [
        {"v/in-heavy", caps(prompt_price: 1.0e-6, completion_price: 1.0e-7)},
        {"v/out-heavy", caps(prompt_price: 1.0e-7, completion_price: 1.0e-5)}
      ]
    end

    test "uses the median input and output tokens of the task over 30 days" do
      for {i, o} <- [{1_000, 100}, {3_000, 300}, {2_000, 200}] do
        request("test.photo", "v/in-heavy", input_tokens: i, output_tokens: o)
      end

      # Not counted: a refusal (0 tokens), a failure, another task, too old.
      request("test.photo", "v/in-heavy",
        input_tokens: 0,
        output_tokens: 0,
        status: "error",
        metadata: %{"refused" => true}
      )

      request("test.photo", "v/in-heavy", input_tokens: 90_000, status: "error")
      request("test.other", "v/in-heavy", input_tokens: 90_000)
      request("test.photo", "v/in-heavy", input_tokens: 90_000, days_ago: 40)

      assert %{estimate: :journal, tokens: {2_000, 200}, rows: rows} =
               Recommendations.cheapest("test.photo",
                 catalogue: [source(models())]
               )

      [first, second] = rows
      assert first.model == "v/in-heavy"
      assert_in_delta first.price_per_call, 2_000 * 1.0e-6 + 200 * 1.0e-7, 1.0e-12
      assert_in_delta second.price_per_call, 2_000 * 1.0e-7 + 200 * 1.0e-5, 1.0e-12
    end

    test "with no journal either, ranks by the input price and marks the estimate rough" do
      assert %{estimate: :rough, tokens: nil, rows: [first, second]} =
               Recommendations.cheapest("test.photo", catalogue: [source(models())])

      assert first.model == "v/out-heavy"
      assert second.model == "v/in-heavy"
      assert first.price_per_call == nil
      assert_in_delta first.input_price_per_million, 0.1, 1.0e-9
    end
  end

  describe "cheapest/2 from the capability cache" do
    setup do
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
      {:ok, stub: stub}
    end

    test "reads the catalogue of the base URLs the endpoints use, with prices", %{stub: stub} do
      {:ok, _endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Recs EP",
          provider: "openrouter",
          model: "google/gemini-flash",
          api_key: "sk-or-v1-test-key"
        })

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "google/gemini-flash",
              "name" => "Gemini Flash",
              "context_length" => 1_000_000,
              "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
              "architecture" => %{
                "input_modalities" => ["text", "image"],
                "output_modalities" => ["text"]
              },
              "supported_parameters" => ["tools", "structured_outputs"]
            },
            %{
              "id" => "deepseek/flash",
              "name" => "DeepSeek Flash",
              "pricing" => %{"prompt" => "0.00000005", "completion" => "0.0000002"},
              "architecture" => %{
                "input_modalities" => ["text"],
                "output_modalities" => ["text"]
              },
              "supported_parameters" => ["tools", "structured_outputs"]
            },
            %{
              "id" => "openai/embed",
              "pricing" => %{"prompt" => "0.00000001", "completion" => "0"},
              "architecture" => %{
                "input_modalities" => ["text"],
                "output_modalities" => ["embeddings"]
              },
              "supported_parameters" => []
            }
          ]
        })
      end)

      pid =
        start_supervised!(
          {Capabilities,
           [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
        )

      Req.Test.allow(stub, self(), pid)
      assert :ok = Capabilities.refresh()

      assert %{rows: [row]} = Recommendations.cheapest("test.sized")
      assert row.model == "google/gemini-flash"
      assert row.name == "Gemini Flash"
      assert row.provider == :openrouter
      assert row.context_length == 1_000_000
      assert_in_delta row.price_per_call, 10_000 * 1.0e-7 + 1_000 * 4.0e-7, 1.0e-12
    end

    test "is empty when no cache runs and no endpoint has a catalogue" do
      assert %{rows: []} = Recommendations.cheapest("test.sized")
    end
  end

  describe "worked/2" do
    test "aggregates the task's journal by model: calls, average cost, error share, latency" do
      request("test.photo", "v/a", cost_cents: 20_000, latency_ms: 400)
      request("test.photo", "v/a", cost_cents: 40_000, latency_ms: 600)
      request("test.photo", "v/a", cost_cents: nil, latency_ms: 800, status: "error")
      request("test.photo", "v/a", cost_cents: 30_000, latency_ms: 200, status: "timeout")
      request("test.photo", "v/b", cost_cents: 5_000, latency_ms: 100)

      assert [a, b] = Recommendations.worked("test.photo")

      assert %{model: "v/a", calls: 4, error_share: 0.5, cost_reported?: true} = a
      assert_in_delta a.avg_cost, 30_000.0, 0.001
      assert_in_delta a.avg_latency_ms, 500.0, 0.001

      assert %{model: "v/b", calls: 1, error_share: +0.0} = b
    end

    test "leaves refusals out of the call count and the error share" do
      request("test.photo", "v/a")
      request("test.photo", "v/a")

      for _ <- 1..5 do
        request("test.photo", "v/a",
          status: "error",
          cost_cents: nil,
          latency_ms: nil,
          input_tokens: 0,
          output_tokens: 0,
          metadata: %{"refused" => true}
        )
      end

      # A model that was only ever refused does not appear at all.
      request("test.photo", "v/refused-only", status: "error", metadata: %{"refused" => true})

      assert [%{model: "v/a", calls: 2, error_share: +0.0}] = Recommendations.worked("test.photo")
    end

    test "counts only the task, only 30 days, and says when no cost was reported" do
      request("test.photo", "v/a", cost_cents: nil)
      request("test.other", "v/a")
      request("test.photo", "v/a", days_ago: 31)
      request("test.photo", "v/a", days_ago: 29, cost_cents: nil)

      assert [%{calls: 2, avg_cost: nil, cost_reported?: false}] =
               Recommendations.worked("test.photo")
    end

    test "orders by calls, then model; an alias is noted" do
      request("test.photo", "v/few")
      for _ <- 1..3, do: request("test.photo", "~v/many-latest")

      assert [%{model: "~v/many-latest", notes: notes}, %{model: "v/few"}] =
               Recommendations.worked("test.photo")

      assert :alias in notes
    end

    test "cache hits are not calls: they do not count and do not pull the averages down" do
      request("test.photo", "v/a", cost_cents: 40_000, latency_ms: 800)

      for _ <- 1..4 do
        request("test.photo", "v/a",
          cost_cents: 0,
          latency_ms: 0,
          metadata: %{"cached" => true}
        )
      end

      assert [%{calls: 1, error_share: +0.0} = row] = Recommendations.worked("test.photo")
      assert_in_delta row.avg_cost, 40_000.0, 0.001
      assert_in_delta row.avg_latency_ms, 800.0, 0.001
    end

    test "a model through two operators is two rows, each with its operator" do
      {:ok, or_ep} =
        PhoenixKitAI.create_endpoint(%{
          name: "OR",
          provider: "openrouter",
          model: "v/a",
          api_key: "k"
        })

      {:ok, mi_ep} =
        PhoenixKitAI.create_endpoint(%{
          name: "MI",
          provider: "mistral",
          model: "v/a",
          api_key: "k"
        })

      request("test.photo", "v/a", endpoint_uuid: or_ep.uuid)
      request("test.photo", "v/a", endpoint_uuid: or_ep.uuid)
      request("test.photo", "v/a", endpoint_uuid: mi_ep.uuid)

      assert [%{calls: 2, provider: "openrouter"}, %{calls: 1, provider: "mistral"}] =
               Recommendations.worked("test.photo")
    end

    test "endpoints of one provider key under a named connection are one row" do
      {:ok, plain} =
        PhoenixKitAI.create_endpoint(%{
          name: "P1",
          provider: "openrouter",
          model: "v/a",
          api_key: "k"
        })

      {:ok, named} =
        PhoenixKitAI.create_endpoint(%{
          name: "P2",
          provider: "openrouter",
          model: "v/a",
          api_key: "k"
        })

      TestRepo.update_all(
        from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^named.uuid),
        set: [provider: "openrouter:work"]
      )

      request("test.photo", "v/a", endpoint_uuid: plain.uuid)
      request("test.photo", "v/a", endpoint_uuid: named.uuid)

      assert [%{calls: 2, provider: "openrouter"}] = Recommendations.worked("test.photo")
    end

    test "is empty for a task with no rows" do
      assert [] = Recommendations.worked("test.photo")
    end
  end

  describe "for_tasks/2" do
    test "gives each task what for_task gives, from two journal queries in all" do
      request("test.sized", "v/a")
      request("test.photo", "v/b", input_tokens: 2_000, output_tokens: 200)
      catalogue = [source([{"v/m", caps(prompt_price: 1.0e-7, completion_price: 1.0e-7)}])]
      keys = ["test.sized", "test.photo", "test.plain"]

      queries = :counters.new(1, [])
      handler = "recs-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix_kit_ai, :test, :repo, :query],
        fn _, _, _, _ -> :counters.add(queries, 1, 1) end,
        nil
      )

      result = Recommendations.for_tasks(keys, catalogue: catalogue)
      :telemetry.detach(handler)

      assert :counters.get(queries, 1) == 2
      assert Map.keys(result) |> Enum.sort() == Enum.sort(keys)

      for key <- keys do
        assert result[key] == Recommendations.for_task(key, catalogue: catalogue)
      end
    end
  end

  describe "for_task/2" do
    test "gathers both lists and takes the task by key or spec" do
      request("test.sized", "v/a")
      catalogue = [source([{"v/m", caps(prompt_price: 1.0e-7, completion_price: 0.0)}])]

      by_key = Recommendations.for_task("test.sized", catalogue: catalogue)

      by_spec =
        Recommendations.for_task(PhoenixKitAI.Tasks.get("test.sized"), catalogue: catalogue)

      assert by_key == by_spec

      assert %{verified: [%{model: "v/m"}], worked: [%{model: "v/a"}], estimate: :declared} =
               by_key
    end
  end
end
