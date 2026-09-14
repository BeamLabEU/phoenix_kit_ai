defmodule PhoenixKitAI.BudgetCacheTest do
  @moduledoc "Spend caps and the request cache, through the public verbs."

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Budget, Request, RequestCache}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.BudgetCacheTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    RequestCache.clear()
    for scope <- [:global, :endpoint, :user], do: {:ok, _} = Budget.set_limit(scope, 0)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      RequestCache.clear()
      for scope <- [:global, :endpoint, :user], do: Budget.set_limit(scope, 0)
    end)

    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Cap-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    {:ok, endpoint: ep}
  end

  defp stub_chat(test_pid, cost \\ 0.5) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => cost}
      })
    end)
  end

  describe "Budget" do
    test "a spent global cap refuses before the provider is called; a fresh day would not", %{
      endpoint: ep
    } do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, 600_000)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert_received :provider_called
      # 0.5 USD = 500_000 nanodollars spent; one more call is still allowed …
      assert [%{scope: :global, spent: 500_000, remaining: 100_000}] = Budget.status(ep, [])
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert_received :provider_called
      # … and now the cap is crossed.
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "q3")
      refute_received :provider_called

      assert 2 =
               TestRepo.aggregate(from(r in Request, where: r.endpoint_uuid == ^ep.uuid), :count)
    end

    test "per-user and per-endpoint caps scope correctly", %{endpoint: ep} do
      stub_chat(self())
      user = Fixtures.confirmed_user_fixture().uuid
      other = Fixtures.confirmed_user_fixture().uuid
      {:ok, _} = Budget.set_limit(:user, 400_000)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: user)
      assert {:error, {:budget_exceeded, :user}} = PhoenixKitAI.ask(ep.uuid, "b", user_uuid: user)
      # Another user, and an anonymous caller, are not affected by that user's cap.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "c", user_uuid: other)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "d")

      {:ok, _} = Budget.set_limit(:user, 0)
      {:ok, _} = Budget.set_limit(:endpoint, 1_000_000)
      assert {:error, {:budget_exceeded, :endpoint}} = PhoenixKitAI.ask(ep.uuid, "e")
      assert PhoenixKitAI.Errors.message({:budget_exceeded, :endpoint}) =~ "endpoint"
    end

    test "the warning fires once when a scope passes the warn percent", %{endpoint: ep} do
      :telemetry.attach(
        "budget-test-#{System.unique_integer([:positive])}",
        [:phoenix_kit_ai, :budget, :warning],
        fn _e, m, meta, pid -> send(pid, {:budget_warning, m, meta}) end,
        self()
      )

      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, 1_200_000)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "1")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "2")
      # 1_000_000 of 1_200_000 = 83% → one warning, not one per call.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "3")
      assert_received {:budget_warning, %{spent: 1_000_000, limit: 1_200_000}, %{scope: :global}}
      refute_received {:budget_warning, _, _}
    end
  end

  describe "RequestCache" do
    test "cache: true answers the second identical call from memory with no provider call and a zero-cost row",
         %{endpoint: ep} do
      :telemetry.attach(
        "cache-test-#{System.unique_integer([:positive])}",
        [:phoenix_kit_ai, :cache, :hit],
        fn _e, _m, meta, pid -> send(pid, {:cache_hit, meta}) end,
        self()
      )

      stub_chat(self())

      assert {:ok, first} = PhoenixKitAI.ask(ep.uuid, "same question", cache: true, source: "A")
      assert_received :provider_called
      assert {:ok, second} = PhoenixKitAI.ask(ep.uuid, "same question", cache: true, source: "B")
      refute_received :provider_called
      assert first == second
      assert_received {:cache_hit, %{verb: :complete}}

      assert [
               %{cost_cents: 500_000},
               %{cost_cents: 0, metadata: %{"cached" => true, "source" => "B"}}
             ] =
               TestRepo.all(
                 from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.inserted_at)
               )

      # A different prompt, a different option, or :refresh all call the provider.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "other question", cache: true)
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same question", cache: true, temperature: 0.1)
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same question", cache: :refresh)
      assert_received :provider_called
      # Without cache: nothing is read or written.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same question")
      assert_received :provider_called
    end

    test "entries expire by their own ttl", %{endpoint: ep} do
      stub_chat(self())
      key = RequestCache.key(:complete, ep, ep.model, :material)
      RequestCache.put(key, %{"cached" => true}, 1)
      assert {:ok, %{"cached" => true}} = RequestCache.get(key)
      Process.sleep(1100)
      assert :miss = RequestCache.get(key)
      assert is_integer(RequestCache.size())
    end

    test "errors are not cached", %{endpoint: ep} do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :provider_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, "{}")
      end)

      assert {:error, :rate_limited} = PhoenixKitAI.ask(ep.uuid, "x", cache: true)
      assert {:error, :rate_limited} = PhoenixKitAI.ask(ep.uuid, "x", cache: true)
      assert_received :provider_called
      assert_received :provider_called
    end
  end

  describe "cache hits, keys and telemetry" do
    test "a hit writes a zero-cost row marked cached and fires the request event", %{endpoint: ep} do
      :telemetry.attach(
        "req-test-#{System.unique_integer([:positive])}",
        [:phoenix_kit_ai, :request],
        fn _e, m, meta, pid -> send(pid, {:request_event, m, meta}) end,
        self()
      )

      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "cached?", cache: true)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "cached?", cache: true, user_uuid: nil)

      rows =
        TestRepo.all(
          from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.inserted_at)
        )

      assert [
               %{cost_cents: 500_000, metadata: first},
               %{cost_cents: 0, metadata: %{"cached" => true}}
             ] = rows

      refute Map.has_key?(first, "cached")

      assert_received {:request_event, %{cost_cents: 500_000},
                       %{cached: false, request_type: "chat"}}

      assert_received {:request_event, %{cost_cents: 0}, %{cached: true}}
    end

    test "a caller key hits across different prompts; :infinity never expires", %{endpoint: ep} do
      stub_chat(self())

      assert {:ok, a} =
               PhoenixKitAI.ask(ep.uuid, "first wording",
                 cache: [key: "product:1", ttl: :infinity]
               )

      assert_received :provider_called
      assert {:ok, b} = PhoenixKitAI.ask(ep.uuid, "second wording", cache: [key: "product:1"])
      refute_received :provider_called
      assert a == b
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "second wording", cache: [key: "product:2"])
      assert_received :provider_called
    end

    test "saved-prompt calls record which version of the prompt ran", %{endpoint: ep} do
      stub_chat(self())

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Snap #{System.unique_integer([:positive])}",
          content: "Say {{Thing}}."
        })

      assert {:ok, _} = PhoenixKitAI.ask_with_prompt(ep.uuid, prompt.uuid, %{"Thing" => "hi"})

      assert [%{metadata: %{"prompt_snapshot" => %{"hash" => hash, "updated_at" => _}}}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))

      assert String.length(hash) == 16
    end
  end
end
