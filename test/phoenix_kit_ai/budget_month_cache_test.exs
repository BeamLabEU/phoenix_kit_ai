defmodule PhoenixKitAI.BudgetMonthCacheTest do
  @moduledoc """
  The month sum's cache and the read-failure flags of `PhoenixKitAI.Budget`,
  with the database read replaced by a function. No database: the flags table
  is the module's own ETS table, started by the test helper.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.{Budget, RequestCache}

  @since ~U[2026-10-01 00:00:00Z]
  @limit Decimal.new(10)

  setup do
    previous = Application.get_env(:phoenix_kit_ai, :budget_month_cache_ttl)
    Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 30_000)
    Budget.reset_warnings()

    on_exit(fn ->
      Budget.reset_warnings()

      if previous,
        do: Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, previous),
        else: Application.delete_env(:phoenix_kit_ai, :budget_month_cache_ttl)
    end)
  end

  defp flags, do: RequestCache.flags_table()
  defp key(kind, id), do: {Budget, kind, id}

  defp put_sum(sum, ms_from_now) do
    expires = System.monotonic_time(:millisecond) + ms_from_now
    :ets.insert(flags(), {key(:month_spent, @since), {Decimal.new(sum), expires}})
  end

  # A scan that tells the test it ran.
  defp scan(sum) do
    pid = self()

    fn ->
      send(pid, :scanned)
      Decimal.new(sum)
    end
  end

  defp failing_scan do
    pid = self()

    fn ->
      send(pid, :scanned)
      raise "usage table is gone"
    end
  end

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))

  describe "the read-failure flag is per scope" do
    test "a healthy scope does not re-arm the log of a failing month" do
      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 0)

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            # The daily read succeeds on every call, as it does in production
            # while only the heavy month scan times out.
            assert dollars?(Budget.read(:global, fn -> Decimal.new(1) end), "1")

            assert dollars?(
                     Budget.read(:global_month, fn ->
                       Budget.month_sum(@since, @limit, fn -> raise "timeout" end)
                     end),
                     "0"
                   )
          end
        end)

      assert [_one] = Regex.scan(~r/global_month spend cap could not read/, log)
      assert :ets.member(flags(), key(:read_failed, :global_month))
      refute :ets.member(flags(), key(:read_failed, :global))
    end

    test "a failing scope is logged on its own, and each clears on its own read" do
      log =
        capture_log(fn ->
          Budget.read(:global, fn -> raise "a" end)
          Budget.read(:endpoint, fn -> raise "b" end)
          Budget.read(:global, fn -> raise "a again" end)
        end)

      assert [_] = Regex.scan(~r/global spend cap could not read/, log)
      assert [_] = Regex.scan(~r/endpoint spend cap could not read/, log)

      Budget.read(:global, fn -> Decimal.new(0) end)
      refute :ets.member(flags(), key(:read_failed, :global))
      assert :ets.member(flags(), key(:read_failed, :endpoint))

      again = capture_log(fn -> Budget.read(:global, fn -> raise "later outage" end) end)
      assert again =~ "global spend cap could not read"
    end

    test "the log names the exception class and nothing of its message" do
      log = capture_log(fn -> Budget.read(:global, fn -> raise "secret detail" end) end)

      assert log =~ "RuntimeError"
      refute log =~ "secret detail"
    end
  end

  describe "a failed month scan" do
    test "serves the last good sum of the month, even an expired one, and is not cached" do
      put_sum("7.5", -1)

      log =
        capture_log(fn ->
          assert dollars?(Budget.month_sum(@since, @limit, failing_scan()), "7.5")
        end)

      assert_received :scanned
      assert log =~ "global_month spend cap could not read"

      # The stale entry is still the one stored: a failure is never a sum.
      assert [{_, {sum, _}}] = :ets.lookup(flags(), key(:month_spent, @since))
      assert dollars?(sum, "7.5")
    end

    test "reads as zero when there is no earlier sum for that month" do
      put_sum("7.5", -1)
      other_month = ~U[2026-11-01 00:00:00Z]

      capture_log(fn ->
        assert dollars?(Budget.month_sum(other_month, @limit, failing_scan()), "0")
      end)
    end

    test "calls do not scan again for a few seconds, then do" do
      put_sum("3", -1)
      capture_log(fn -> Budget.month_sum(@since, @limit, failing_scan()) end)
      assert_received :scanned

      for _ <- 1..5 do
        assert dollars?(Budget.month_sum(@since, @limit, scan("99")), "3")
      end

      refute_received :scanned

      # The backoff ends: the next call scans, and a good scan replaces the sum.
      :ets.insert(flags(), {key(:month_failed, @since), System.monotonic_time(:millisecond) - 1})
      assert dollars?(Budget.month_sum(@since, @limit, scan("4")), "4")
      assert_received :scanned
      refute :ets.member(flags(), key(:month_failed, @since))
    end

    test "a good scan clears the month's flag, a cache hit does not" do
      :ets.insert(flags(), {key(:read_failed, :global_month), true})
      put_sum("1", 30_000)

      assert dollars?(Budget.month_sum(@since, @limit, scan("9")), "1")
      refute_received :scanned
      assert :ets.member(flags(), key(:read_failed, :global_month))

      put_sum("1", -1)
      assert dollars?(Budget.month_sum(@since, @limit, scan("2")), "2")
      refute :ets.member(flags(), key(:read_failed, :global_month))
    end
  end

  describe "near the cap" do
    # Limit $10, warn percent 80 (the default): the stretch from $8 to just
    # under $10 is read afresh on every check.
    test "far below the warn percent the cached sum is used" do
      put_sum("1", 30_000)
      assert dollars?(Budget.month_sum(@since, @limit, scan("2")), "1")
      refute_received :scanned
    end

    test "from the warn percent up to the cap every check scans" do
      for cached <- ["8", "9.99"] do
        put_sum(cached, 30_000)
        assert dollars?(Budget.month_sum(@since, @limit, scan("9.5")), "9.5")
        assert_received :scanned
      end
    end

    test "at the cap the cached sum is used: nothing more is spent" do
      put_sum("10", 30_000)
      assert dollars?(Budget.month_sum(@since, @limit, scan("11")), "10")
      refute_received :scanned
    end
  end

  describe "the cache is off" do
    test "a TTL that is not a positive integer scans every time and keeps nothing" do
      for ttl <- [0, -1, nil, "30000", 1.5] do
        Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, ttl)
        assert dollars?(Budget.month_sum(@since, @limit, scan("2")), "2")
        assert_received :scanned
        assert dollars?(Budget.month_sum(@since, @limit, scan("3")), "3")
        assert_received :scanned
        assert :ets.lookup(flags(), key(:month_spent, @since)) == []
      end
    end
  end
end
