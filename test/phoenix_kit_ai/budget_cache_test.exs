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

    reset()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :request_cache)
      reset()
    end)

    {:ok, endpoint: endpoint_fixture()}
  end

  defp reset do
    RequestCache.clear()
    Budget.reset_warnings()
    for scope <- [:global, :endpoint, :user], do: {:ok, _} = Budget.set_limit(scope, 0)

    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "80", "ai")
  end

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Cap-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    ep
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

  defp rows(ep) do
    TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.uuid))
  end

  defp attach(event) do
    :telemetry.attach(
      "#{inspect(event)}-#{System.unique_integer([:positive])}",
      event,
      fn e, m, meta, pid -> send(pid, {:event, e, m, meta}) end,
      self()
    )
  end

  describe "Budget" do
    test "a reached global cap refuses before the provider is called", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, 1_000_000)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert_received :provider_called
      # 0.5 USD = 500_000 nanodollars spent; one more call is still allowed …
      assert [%{scope: :global, spent: 500_000, remaining: 500_000}] = Budget.status(ep, [])
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert_received :provider_called
      # … and now the cap is reached (remaining 0 is not room).
      assert [%{remaining: 0}] = Budget.status(ep.uuid, [])
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "q3")
      refute_received :provider_called
      # A cached answer is refused too: a cap is a stop switch.
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "q1", cache: true)

      assert 2 =
               TestRepo.aggregate(from(r in Request, where: r.endpoint_uuid == ^ep.uuid), :count)
    end

    test "only success rows inside the trailing 24 hours count", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, 600_000)
      old = DateTime.add(DateTime.utc_now(), -25 * 60 * 60, :second) |> DateTime.truncate(:second)

      for {status, inserted_at} <- [
            {"success", old},
            {"error", DateTime.utc_now() |> DateTime.truncate(:second)}
          ] do
        TestRepo.insert!(%Request{
          endpoint_uuid: ep.uuid,
          endpoint_name: ep.name,
          model: ep.model,
          request_type: "chat",
          cost_cents: 5_000_000,
          status: status,
          inserted_at: inserted_at,
          updated_at: inserted_at
        })
      end

      assert [%{spent: 0}] = Budget.status(ep, [])
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "still allowed")
      assert_received :provider_called
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

      # The endpoint cap sees only its own endpoint's spend.
      {:ok, _} = Budget.set_limit(:user, 0)
      {:ok, _} = Budget.set_limit(:endpoint, 1_000_000)
      other_ep = endpoint_fixture()
      assert [%{scope: :endpoint, spent: 0}] = Budget.status(other_ep, [])
      assert {:ok, _} = PhoenixKitAI.ask(other_ep.uuid, "fresh endpoint")
      assert {:error, {:budget_exceeded, :endpoint}} = PhoenixKitAI.ask(ep.uuid, "e")
    end

    test "an unknown user_uuid loses the row loudly, never silently", %{endpoint: ep} do
      stub_chat(self())
      ghost = Ecto.UUID.generate()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "who?", user_uuid: ghost)
        end)

      assert log =~ "usage row not written"
      assert rows(ep) == []
    end

    test "the warning fires once per crossing and status/2 stays side-effect free", %{
      endpoint: ep
    } do
      attach([:phoenix_kit_ai, :budget, :warning])
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, 1_200_000)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "1")
      refute_received {:event, _, _, _}
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "2")
      # 1_000_000 of 1_200_000 = 83% → one warning on the next check, not one
      # per call or per status read.
      assert [%{spent: 1_000_000}] = Budget.status(ep, [])
      refute_received {:event, _, _, _}
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "3")
      assert_received {:event, _, %{spent: 1_000_000, limit: 1_200_000}, %{scope: :global}}
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "4")
      refute_received {:event, _, _, _}
    end

    test "garbage settings fail open, and the warn percent falls back to 80" do
      {:ok, _} = PhoenixKit.Settings.update_setting_with_module("ai_daily_budget", "lots", "ai")

      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "x", "ai")

      assert Budget.limit(:global) == 0
      assert Budget.warn_percent() == 80

      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "0", "ai")

      assert Budget.warn_percent() == 80

      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "50", "ai")

      assert Budget.warn_percent() == 50
    end
  end

  describe "RequestCache" do
    test "cache: true answers the second identical call from memory with a zero-cost row",
         %{endpoint: ep} do
      attach([:phoenix_kit_ai, :cache, :hit])
      attach([:phoenix_kit_ai, :request])
      stub_chat(self())

      assert {:ok, first} = PhoenixKitAI.ask(ep.uuid, "same question", cache: true, source: "A")
      assert_received :provider_called
      assert {:ok, second} = PhoenixKitAI.ask(ep.uuid, "same question", cache: true, source: "B")
      refute_received :provider_called
      assert first == second

      # Telemetry metadata is tags only — the hit callback is not in it.
      assert_received {:event, [:phoenix_kit_ai, :cache, :hit], _, meta}
      assert meta == %{verb: :complete, endpoint_uuid: ep.uuid}

      assert [
               %{cost_cents: 500_000, metadata: fresh},
               %{cost_cents: 0, metadata: %{"cached" => true, "source" => "B"}}
             ] = rows(ep)

      refute Map.has_key?(fresh, "cached")

      assert_received {:event, [:phoenix_kit_ai, :request], %{cost_cents: 500_000},
                       %{cached: false, request_type: "chat"}}

      assert_received {:event, [:phoenix_kit_ai, :request], %{cost_cents: 0}, %{cached: true}}

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

    test ":refresh overwrites the stored answer; default: true opts everyone in", %{endpoint: ep} do
      stub_chat(self())
      assert {:ok, a} = PhoenixKitAI.ask(ep.uuid, "q", cache: true)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "43"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      assert {:ok, b} = PhoenixKitAI.ask(ep.uuid, "q", cache: [refresh: true])
      assert b != a
      assert {:ok, ^b} = PhoenixKitAI.ask(ep.uuid, "q", cache: true)

      Application.put_env(:phoenix_kit_ai, :request_cache, default: true)
      assert {:ok, ^b} = PhoenixKitAI.ask(ep.uuid, "q")
      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q", cache: false)
      assert_received :provider_called
    end

    test "entries expire by their own ttl; the sweep leaves :infinity alone", %{endpoint: ep} do
      key = RequestCache.key(:complete, ep, ep.model, :material)
      forever = RequestCache.key(:complete, ep, ep.model, :forever)
      before = RequestCache.size()

      assert :ok = RequestCache.put(key, %{"cached" => true}, 60)
      assert :ok = RequestCache.put(forever, :kept, :infinity)
      assert RequestCache.size() == before + 2
      assert {:ok, %{"cached" => true}} = RequestCache.get(key)

      # Expire it by hand instead of sleeping: the table is public.
      :ets.insert(
        :phoenix_kit_ai_request_cache,
        {key, System.monotonic_time(:millisecond) - 1, :old}
      )

      assert :miss = RequestCache.get(key)

      send(RequestCache, :sweep)
      _ = :sys.get_state(RequestCache)
      assert RequestCache.size() == before + 1
      assert {:ok, :kept} = RequestCache.get(forever)

      RequestCache.clear()
      assert RequestCache.size() == 0
    end

    test "a bad ttl falls back to the default; full and oversized are refused", %{endpoint: ep} do
      assert {:use, ttl} = RequestCache.mode(cache: [ttl: "3600"])
      assert ttl == RequestCache.default_ttl()
      assert {:use, :infinity} = RequestCache.mode(cache: [ttl: :infinity])

      Application.put_env(:phoenix_kit_ai, :request_cache, max_entries: 1, max_value_bytes: 100)
      k1 = RequestCache.key(:complete, ep, ep.model, 1)
      k2 = RequestCache.key(:complete, ep, ep.model, 2)
      assert :ok = RequestCache.put(k1, :small, 60)
      assert {:error, :full} = RequestCache.put(k2, :small, 60)
      assert :ok = RequestCache.put(k1, :replaced, 60)
      assert {:error, :too_large} = RequestCache.put(k1, String.duplicate("x", 200), 60)
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

  describe "cache keys and cached rows" do
    test "a caller key hits across prompts but not across JSON shapes; :infinity never expires",
         %{endpoint: ep} do
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

      # Same key, but a JSON answer asked for: not the cached prose.
      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid(), :provider_called)

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => ~s({"n": 1})}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      assert {:ok, %{"json" => %{"n" => 1}}} =
               PhoenixKitAI.ask(ep.uuid, "x", cache: [key: "product:1"], json: true)

      assert_received :provider_called
    end

    test "an endpoint edit invalidates its entries", %{endpoint: ep} do
      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q", cache: true)
      assert_received :provider_called
      Process.sleep(1000)
      {:ok, _} = PhoenixKitAI.update_endpoint(ep, %{temperature: 0.3})
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q", cache: true)
      assert_received :provider_called
    end

    test "a hit's row is attributed to the hitter and keeps the prompt link and attribution",
         %{endpoint: ep} do
      stub_chat(self())
      user_a = Fixtures.confirmed_user_fixture().uuid
      user_b = Fixtures.confirmed_user_fixture().uuid

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Snap #{System.unique_integer([:positive])}",
          content: "Say {{Thing}}."
        })

      opts = [cache: true, attribution: %{project: "p1"}]

      assert {:ok, _} =
               PhoenixKitAI.ask_with_prompt(
                 ep.uuid,
                 prompt.uuid,
                 %{"Thing" => "hi"},
                 [user_uuid: user_a] ++ opts
               )

      assert_received :provider_called
      # Usage increments touched the prompt row; the cache must not care.
      assert {:ok, _} =
               PhoenixKitAI.ask_with_prompt(
                 ep.uuid,
                 prompt.uuid,
                 %{"Thing" => "hi"},
                 [user_uuid: user_b] ++ opts
               )

      refute_received :provider_called

      assert [
               %{
                 user_uuid: ^user_a,
                 prompt_uuid: puuid,
                 metadata: %{"prompt_snapshot" => %{"hash" => hash}}
               },
               %{
                 user_uuid: ^user_b,
                 prompt_uuid: puuid,
                 cost_cents: 0,
                 metadata: %{
                   "cached" => true,
                   "prompt_snapshot" => %{"hash" => hash},
                   "attribution" => %{"project" => "p1"}
                 }
               }
             ] = rows(ep)

      assert puuid == prompt.uuid
      assert String.length(hash) == 16

      # Editing the prompt changes the snapshot.
      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{content: "Shout {{Thing}}!"})
      assert {:ok, _} = PhoenixKitAI.ask_with_prompt(ep.uuid, prompt.uuid, %{"Thing" => "hi"})
      assert [_, _, %{metadata: %{"prompt_snapshot" => %{"hash" => other}}}] = rows(ep)
      assert other != hash
    end

    test "get_usage_stats/1 reads back a user's spend in a window", %{endpoint: ep} do
      stub_chat(self())
      user = Fixtures.confirmed_user_fixture().uuid
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q", user_uuid: user)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")

      assert %{total_requests: 1, total_cost_cents: 500_000} =
               PhoenixKitAI.get_usage_stats(user_uuid: user, endpoint_uuid: ep.uuid)

      assert %{total_requests: 0} =
               PhoenixKitAI.get_usage_stats(
                 endpoint_uuid: ep.uuid,
                 until: DateTime.add(DateTime.utc_now(), -60, :second)
               )
    end
  end

  defp test_pid, do: self()
end
