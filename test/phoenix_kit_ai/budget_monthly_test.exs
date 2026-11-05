defmodule PhoenixKitAI.BudgetMonthlyTest do
  @moduledoc "The site-wide monthly spend cap (`ai_monthly_cap`), through the public verbs."

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Budget, Errors, GuardEvent, Request, RequestCache, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  # Far east of UTC, so the local month starts hours before the UTC one.
  @zone "Pacific/Auckland"

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.BudgetMonthlyTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", @zone)
    reset()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      reset()
    end)

    {:ok, endpoint: endpoint_fixture()}
  end

  defp reset do
    RequestCache.clear()
    Budget.reset_warnings()

    for scope <- [:global, :global_month, :endpoint, :user, :user_calls],
        do: {:ok, _} = Budget.set_limit(scope, 0)

    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "80", "ai")
  end

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Month-EP-#{System.unique_integer([:positive])}",
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

  defp month_start, do: TaskLimits.windows().month |> elem(0)

  # A usage row written at `at`, `cost` dollars.
  defp usage_row(endpoint, at, cost, status \\ "success") do
    at = DateTime.truncate(at, :second)

    %Request{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: status,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cost: Decimal.new(cost),
      latency_ms: 1,
      metadata: %{},
      inserted_at: at,
      updated_at: at
    }
    |> TestRepo.insert!()
  end

  defp month_status(ep) do
    Enum.find(Budget.status(ep, []), &(&1.scope == :global_month))
  end

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  defp attach(event) do
    id = "#{inspect(event)}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      event,
      fn e, m, meta, pid -> send(pid, {:event, e, m, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "the setting" do
    test "ai_monthly_cap holds dollars, like the daily caps" do
      assert Budget.setting(:global_month) == "ai_monthly_cap"

      assert {:ok, _} = Budget.set_limit(:global_month, "100")
      assert PhoenixKit.Settings.get_setting("ai_monthly_cap") == "100.00"
      assert dollars?(Budget.limit(:global_month), "100")

      assert {:error, :ambiguous_amount} = Budget.set_limit(:global_month, 5_000_000)
      assert {:error, :invalid_amount} = Budget.set_limit(:global_month, "-1")
      assert {:error, :invalid_amount} = Budget.set_limit(:global_month, "lots")
      assert dollars?(Budget.limit(:global_month), "100")
    end

    test "0 and blank mean no cap, and garbage is read as no cap", %{endpoint: ep} do
      for value <- ["0", "0.00", "", "  ", "lots"] do
        {:ok, _} = PhoenixKit.Settings.update_setting_with_module("ai_monthly_cap", value, "ai")
        assert dollars?(Budget.limit(:global_month), "0")
        assert month_status(ep) == nil
      end

      stub_chat(self())
      usage_row(ep, DateTime.utc_now(), "1000.00")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end
  end

  describe "the check" do
    test "a cap reached this month refuses before the provider, cached answers too", %{
      endpoint: ep
    } do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "1.00")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert_received :provider_called

      assert %{spent: spent, remaining: remaining} = month_status(ep)
      assert dollars?(spent, "1") and dollars?(remaining, "0")

      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q3")
      refute_received :provider_called

      assert {:error, {:budget_exceeded, :global_month}} =
               PhoenixKitAI.ask(ep.uuid, "q1", cache: true)

      refute_received :provider_called
    end

    test "under the cap the call goes through", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "100")
      usage_row(ep, DateTime.utc_now(), "99.00")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
      assert_received :provider_called
    end

    test "spend from before the local month start does not count, the first instant does", %{
      endpoint: ep
    } do
      from = month_start()
      {:ok, _} = Budget.set_limit(:global_month, "1.00")

      usage_row(ep, DateTime.add(from, -1, :second), "5.00")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0")

      usage_row(ep, from, "0.40")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0.4")

      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end

    test "a month is longer than the rolling day the other caps look at", %{endpoint: ep} do
      # A row from a few days ago, inside this month, counts for the monthly
      # cap only. On the first days of a month there is no such row: then a
      # row at the month's first instant must count instead.
      from = month_start()
      now = DateTime.utc_now()
      {:ok, _} = Budget.set_limit(:global, "1.00")
      {:ok, _} = Budget.set_limit(:global_month, "1.00")

      if DateTime.diff(now, from) > 25 * 3600 do
        usage_row(ep, DateTime.add(from, 60, :second), "2.00")

        assert [%{scope: :global, spent: day}, %{scope: :global_month, spent: month}] =
                 Budget.status(ep, [])

        assert dollars?(day, "0") and dollars?(month, "2")
        stub_chat(self())

        assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q")
        refute_received :provider_called
      else
        usage_row(ep, from, "2.00")
        assert %{spent: month} = month_status(ep)
        assert dollars?(month, "2")
      end
    end

    test "failed calls do not count", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      usage_row(ep, DateTime.utc_now(), "5.00", "error")

      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0")

      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end

    test "the daily cap still decides on its own", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, "0.50")
      {:ok, _} = Budget.set_limit(:global_month, "100")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert [%{scope: :global}, %{scope: :global_month}] = Budget.status(ep, [])
    end

    test "the refusal is a guard event, once per month, and tells the owner", %{endpoint: ep} do
      owner = Fixtures.user_fixture()
      PhoenixKit.Notifications.enable_system()
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "0.50")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")

      for _ <- 1..2 do
        assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q2")
      end

      month = TaskLimits.period_keys(DateTime.utc_now()).month

      # Once per month, not per day: the refusal lasts until the month turns.
      assert [%GuardEvent{ref: %{"scope" => "budget:global_month"}, dedupe_key: key}] =
               TestRepo.all(from(e in GuardEvent, where: e.kind == "limit_reached"))

      assert key == "limit_reached:budget:global_month:-:#{month}"

      assert [%Notification{metadata: %{"notification_text" => text}}] =
               TestRepo.all(from(n in Notification, where: n.recipient_uuid == ^owner.uuid))

      assert text =~ "month"
    end

    test "the warning fires once per crossing, with the scope in its metadata", %{endpoint: ep} do
      attach([:phoenix_kit_ai, :budget, :warning])
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "1.20")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "1")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "2")
      refute_received {:event, _, _, _}
      # $1.00 of $1.20 = 83%: one warning on the next check, then none.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "3")
      assert_received {:event, _, %{spent: 1.0, limit: 1.2}, %{scope: :global_month}}
      refute_received {:event, _, _, _}
      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "4")
      refute_received {:event, _, _, _}
    end
  end

  describe "the monthly sum is cached for a short while" do
    setup do
      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 30_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 0) end)
    end

    test "within the TTL the sum is served from the cache", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "100")
      usage_row(ep, DateTime.utc_now(), "1.00")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "1")

      usage_row(ep, DateTime.utc_now(), "2.00")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "1"), "the second read should have come from the cache"

      # Dropping the flags (tests) drops the cached sum too.
      Budget.reset_warnings()
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "3")
    end

    test "another month start does not reuse the cached sum", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "100")
      usage_row(ep, DateTime.utc_now(), "1.00")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "1")

      usage_row(ep, DateTime.utc_now(), "2.00")
      # A zone whose month starts at another instant is another cache key.
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "Pacific/Honolulu")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "3")
    end

    test "an expired entry is read afresh", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "100")
      usage_row(ep, DateTime.utc_now(), "1.00")

      expired = {Decimal.new(99), System.monotonic_time(:millisecond) - 1}
      :ets.insert(RequestCache.flags_table(), {{Budget, :month_spent, month_start()}, expired})

      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "1")
    end

    test "a TTL that is not a positive integer means no cache, not no cap", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      usage_row(ep, DateTime.utc_now(), "0.40")

      for ttl <- [nil, "30000", 0, -5, 1.5] do
        Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, ttl)
        Budget.reset_warnings()
        row = usage_row(ep, DateTime.utc_now(), "0.30")

        assert %{spent: spent} = month_status(ep)
        assert dollars?(spent, "0.7"), "ttl #{inspect(ttl)}: #{inspect(spent)}"
        TestRepo.delete!(row)
      end

      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, nil)
      usage_row(ep, DateTime.utc_now(), "0.60")
      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q")
    end

    test "a failed read is not cached", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "100")
      table = Request.__schema__(:source)
      TestRepo.query!(~s(ALTER TABLE "#{table}" RENAME TO "#{table}_away"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert %{spent: spent} = month_status(ep)
        assert dollars?(spent, "0")
      end)

      flags = RequestCache.flags_table()
      assert :ets.match(flags, {{Budget, :month_spent, :_}, :_}) == []
    end
  end

  describe "a failing read" do
    test "a successful read clears the flag, so a later outage is logged again", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      flags = RequestCache.flags_table()
      :ets.insert(flags, {{Budget, :read_failed, :all}, true})

      assert %{spent: _} = month_status(ep)
      assert :ets.lookup(flags, {Budget, :read_failed, :all}) == []
    end

    test "a successful call-count read clears the flag", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:user_calls, 5)
      flags = RequestCache.flags_table()
      :ets.insert(flags, {{Budget, :read_failed, :all}, true})

      user = Fixtures.user_fixture()
      assert [%{scope: :user_calls}] = Budget.status(ep, user_uuid: user.uuid)
      assert :ets.lookup(flags, {Budget, :read_failed, :all}) == []
    end

    test "a successful money read clears the flag", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global, "1.00")
      flags = RequestCache.flags_table()
      :ets.insert(flags, {{Budget, :read_failed, :all}, true})

      assert [%{scope: :global}] = Budget.status(ep, [])
      assert :ets.lookup(flags, {Budget, :read_failed, :all}) == []
    end

    test "a month sum served from the cache leaves the flag set", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 30_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 0) end)
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      flags = RequestCache.flags_table()
      key = {Budget, :read_failed, :all}

      assert %{spent: _} = month_status(ep)
      :ets.insert(flags, {key, true})

      assert %{spent: _} = month_status(ep)
      assert :ets.lookup(flags, key) == [{key, true}]

      [{cache_key, _}] = :ets.match_object(flags, {{Budget, :month_spent, :_}, :_})
      :ets.delete(flags, cache_key)

      assert %{spent: _} = month_status(ep)
      assert :ets.lookup(flags, key) == []
    end

    test "a new cache entry drops the entries of other month starts", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 30_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 0) end)
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      flags = RequestCache.flags_table()
      stale = {Budget, :month_spent, ~U[2001-01-01 00:00:00Z]}
      :ets.insert(flags, {stale, {Decimal.new(0), System.monotonic_time(:millisecond) + 60_000}})

      # The read-failure flag is not here: the real read that fills the cache
      # clears it, by design.
      others = [
        {Budget, :global_month, :all},
        {Budget, :unmigrated, :global}
      ]

      for key <- others, do: :ets.insert(flags, {key, true})

      assert %{spent: _} = month_status(ep)

      for key <- others, do: assert(:ets.lookup(flags, key) == [{key, true}])

      assert [{{Budget, :month_spent, since}, _}] =
               :ets.match_object(flags, {{Budget, :month_spent, :_}, :_})

      refute since == ~U[2001-01-01 00:00:00Z]
    end

    test "fails open and is logged once per outage per node", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      {:ok, _} = Budget.set_limit(:global, "1.00")
      table = Request.__schema__(:source)
      TestRepo.query!(~s(ALTER TABLE "#{table}" RENAME TO "#{table}_away"))

      log = ExUnit.CaptureLog.capture_log(fn -> assert [_, _] = Budget.status(ep, []) end)
      assert log =~ "spend cap"
      assert log =~ "Postgrex.Error"
      assert log =~ "not enforced"

      again = ExUnit.CaptureLog.capture_log(fn -> Budget.status(ep, []) end)
      refute again =~ "spend cap"
    end
  end

  describe "the refusal text" do
    test "names the month and is translated" do
      assert Errors.message({:budget_exceeded, :global_month}) ==
               "The AI budget for this month has been used up"

      for locale <- ["et", "ru"] do
        Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
          refute Errors.message({:budget_exceeded, :global_month}) =~ "this month",
                 "#{locale} fell back to English"
        end)
      end
    end
  end
end
