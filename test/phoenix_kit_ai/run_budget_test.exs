defmodule PhoenixKitAI.RunBudgetTest do
  @moduledoc """
  A run's own ceiling (`run_budget:` with `run:`, `PhoenixKitAI.Runs`): once the
  run's rows have cost that much, calls are refused with
  `{:run_budget_reached, run}` — a graceful end, not a failure.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias PhoenixKitAI.{Budget, Request, RequestCache, Runs}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    RequestCache.clear()
    Budget.reset_warnings()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      RequestCache.clear()
    end)

    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Run-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    {:ok, endpoint: ep}
  end

  defp stub(cost, content \\ "42") do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :provider_called)

      Req.Test.json(conn, %{
        "model" => "google/gemini-2.5-flash",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => cost}
      })
    end)
  end

  defp rows(ep), do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))

  test "the call that would pass the ceiling is refused, gracefully", %{endpoint: ep} do
    stub(0.5)
    opts = [run: "crawl-1", run_budget: "0.90"]

    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", opts)
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "b", opts)
    assert_received :provider_called
    assert_received :provider_called

    assert {:error, {:run_budget_reached, "crawl-1"} = reason} =
             PhoenixKitAI.ask(ep.uuid, "c", opts)

    refute_received :provider_called
    assert Runs.ceiling_reached?(reason)
    assert Runs.ceiling_reached?({:error, reason})
    refute Runs.ceiling_reached?({:budget_exceeded, :global})
    assert PhoenixKitAI.Errors.message(reason) =~ "budget"

    # The refusal is a row of the run, which costs nothing.
    assert [refused] = Enum.filter(rows(ep), &Request.refused?/1)
    assert refused.metadata["run"] == "crawl-1"

    assert {:ok, %{spent: spent, reached?: true, remaining: remaining}} =
             PhoenixKitAI.run_ceiling("crawl-1", "0.90")

    assert Decimal.equal?(spent, Decimal.new("1.0"))
    assert Decimal.equal?(remaining, 0)

    # Another run, and a call without a ceiling, go on.
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "d", run: "crawl-2", run_budget: "0.90")
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "e", run: "crawl-1")
  end

  test "run_since: counts only the run's rows from then on", %{endpoint: ep} do
    stub(0.5)
    assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", run: "nightly")

    later = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:ok, %{spent: spent, reached?: false}} =
             Runs.ceiling("nightly", "0.40", since: later)

    assert Decimal.equal?(spent, 0)

    assert {:ok, _} =
             PhoenixKitAI.ask(ep.uuid, "b", run: "nightly", run_budget: "0.40", run_since: later)

    assert {:error, {:run_budget_reached, "nightly"}} =
             PhoenixKitAI.ask(ep.uuid, "c", run: "nightly", run_budget: "0.40")
  end

  test "a cached answer is refused too, and the ceiling is not part of the cache key",
       %{endpoint: ep} do
    stub(0.5)

    assert {:ok, _} =
             PhoenixKitAI.ask(ep.uuid, "same", run: "r", run_budget: "10.00", cache: true)

    assert_received :provider_called

    assert {:ok, _} =
             PhoenixKitAI.ask(ep.uuid, "same", run: "r", run_budget: "20.00", cache: true)

    refute_received :provider_called

    assert {:error, {:run_budget_reached, "r"}} =
             PhoenixKitAI.ask(ep.uuid, "same", run: "r", run_budget: "0.10", cache: true)
  end

  test "a ceiling without a run, or not an amount, is the caller's mistake: no row",
       %{endpoint: ep} do
    stub(0.5)

    assert {:error, :run_budget_without_run} = PhoenixKitAI.ask(ep.uuid, "a", run_budget: "1.00")

    assert {:error, {:invalid_run_budget, :ambiguous_amount}} =
             PhoenixKitAI.ask(ep.uuid, "a", run: "x", run_budget: 1)

    assert {:error, {:invalid_run_budget, :not_an_amount}} =
             PhoenixKitAI.ask(ep.uuid, "a", run: "x", run_budget: "lots")

    assert rows(ep) == []
    refute_received :provider_called

    assert {:error, :invalid_run} = Runs.ceiling(nil, "1.00")
    assert :ok = Runs.validate_ceiling(run: "x")
  end

  test "vision_batch stops on the run's ceiling with stopped: :run_budget", %{endpoint: ep} do
    stub(0.5, Jason.encode!(%{"ok" => true}))
    items = for i <- 1..5, do: %{id: i, images: @jpeg <> <<i>>}

    assert {:ok, %{stopped: :run_budget, counts: counts, items: items}} =
             PhoenixKitAI.vision_batch(ep.uuid, items,
               json: true,
               concurrency: 1,
               cache: false,
               run: "batch-run",
               run_budget: "1.00"
             )

    assert counts == %{ok: 2, error: 0, unparsed: 0, skipped: 3}
    assert %{status: :skipped, error: {:run_budget_reached, "batch-run"}} = Enum.at(items, 2)

    assert {:error, {:invalid_run_budget, _}} =
             PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], json: true, run_budget: "nope")
  end
end
