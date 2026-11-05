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

  # A cached sum that was scanned `age_ms` ago. The default TTL is 30 s, so
  # an age over that is an expired entry.
  defp put_sum(sum, age_ms) do
    scanned_at = System.monotonic_time(:millisecond) - age_ms
    :ets.insert(flags(), {key(:month_spent, @since), {Decimal.new(sum), scanned_at}})
  end

  @expired 31_000
  @minute 60_000

  defp put_until(kind, ms_from_now) do
    :ets.insert(flags(), {key(kind, @since), System.monotonic_time(:millisecond) + ms_from_now})
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
      put_sum("7.5", @expired)

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
      put_sum("7.5", @expired)
      other_month = ~U[2026-11-01 00:00:00Z]

      capture_log(fn ->
        assert dollars?(Budget.month_sum(other_month, @limit, failing_scan()), "0")
      end)
    end

    test "calls do not scan again for a few seconds, then do" do
      put_sum("3", @expired)
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
      put_sum("1", 0)

      assert dollars?(Budget.month_sum(@since, @limit, scan("9")), "1")
      refute_received :scanned
      assert :ets.member(flags(), key(:read_failed, :global_month))

      put_sum("1", @expired)
      assert dollars?(Budget.month_sum(@since, @limit, scan("2")), "2")
      refute :ets.member(flags(), key(:read_failed, :global_month))
    end
  end

  describe "near the cap" do
    # Limit $10: from $9 (90%) to just under $10 a sum is reused for 2 seconds
    # at most, whatever the warn percent is.
    test "far below the cap the cached sum is used for the whole TTL" do
      for sum <- ["1", "8", "8.99"] do
        put_sum(sum, 29_000)
        assert dollars?(Budget.month_sum(@since, @limit, scan("2")), sum)
        refute_received :scanned
      end
    end

    test "from 90% of the cap a sum older than 2 seconds is scanned again" do
      for cached <- ["9", "9.99"] do
        put_sum(cached, 2_500)
        assert dollars?(Budget.month_sum(@since, @limit, scan("9.5")), "9.5")
        assert_received :scanned
      end
    end

    test "from 90% of the cap a sum younger than 2 seconds is still reused" do
      put_sum("9.5", 1_000)
      assert dollars?(Budget.month_sum(@since, @limit, scan("9.9")), "9.5")
      refute_received :scanned
    end

    test "at the cap the cached sum is used for the whole TTL: nothing more is spent" do
      put_sum("10", 29_000)
      assert dollars?(Budget.month_sum(@since, @limit, scan("11")), "10")
      refute_received :scanned
    end

    test "a short TTL is not stretched to 2 seconds" do
      Application.put_env(:phoenix_kit_ai, :budget_month_cache_ttl, 500)
      put_sum("9.5", 700)
      assert dollars?(Budget.month_sum(@since, @limit, scan("9.6")), "9.6")
      assert_received :scanned
    end
  end

  describe "a scan with an earlier sum to serve" do
    test "leaves a lease while it runs and removes it when it is done" do
      put_sum("3", @expired)
      pid = self()

      fun = fn ->
        send(pid, {:lease, :ets.member(flags(), key(:month_scanning, @since))})
        Decimal.new(4)
      end

      assert dollars?(Budget.month_sum(@since, @limit, fun), "4")
      assert_received {:lease, true}
      refute :ets.member(flags(), key(:month_scanning, @since))
    end

    test "callers arriving during the lease serve the earlier sum and do not scan" do
      put_sum("3", @expired)
      put_until(:month_scanning, 5_000)

      for _ <- 1..3, do: assert(dollars?(Budget.month_sum(@since, @limit, scan("99")), "3"))
      refute_received :scanned
    end

    test "a lease that has lapsed (a scanner that died) lets the next caller scan" do
      put_sum("3", @expired)
      put_until(:month_scanning, -1)

      assert dollars?(Budget.month_sum(@since, @limit, scan("5")), "5")
      assert_received :scanned
    end

    test "with no earlier sum every caller scans: there is nothing to serve" do
      put_until(:month_scanning, 5_000)

      assert dollars?(Budget.month_sum(@since, @limit, scan("5")), "5")
      assert_received :scanned
    end

    test "a failed scan replaces the lease with the backoff" do
      put_sum("3", @expired)
      capture_log(fn -> Budget.month_sum(@since, @limit, failing_scan()) end)

      refute :ets.member(flags(), key(:month_scanning, @since))
      assert :ets.member(flags(), key(:month_failed, @since))
    end
  end

  describe "a sum that keeps getting older" do
    test "is reported again once it is 10 minutes old, then not every call" do
      put_sum("3", 11 * @minute)

      log =
        capture_log(fn ->
          Budget.month_sum(@since, @limit, failing_scan())
          # Backoff ends; the scan fails again, and the reminder is not repeated.
          :ets.delete(flags(), key(:month_failed, @since))
          Budget.month_sum(@since, @limit, failing_scan())
          Budget.month_sum(@since, @limit, scan("9"))
        end)

      assert [_] = Regex.scan(~r/is still using a monthly sum that is 11 minutes old/, log)
    end

    test "is reported again after the interval" do
      put_sum("3", 11 * @minute)
      capture_log(fn -> Budget.month_sum(@since, @limit, failing_scan()) end)

      long_ago = System.monotonic_time(:millisecond) - 11 * @minute
      :ets.insert(flags(), {key(:stale_notice, :global_month), long_ago})
      :ets.delete(flags(), key(:month_failed, @since))

      log = capture_log(fn -> Budget.month_sum(@since, @limit, failing_scan()) end)
      assert log =~ "monthly sum that is"
    end

    test "a sum under 10 minutes old is not reported" do
      put_sum("3", 9 * @minute)
      log = capture_log(fn -> Budget.month_sum(@since, @limit, failing_scan()) end)

      refute log =~ "monthly sum that is"
      assert log =~ "global_month spend cap could not read"
    end

    test "the backoff serves the old sum and reports it too" do
      put_sum("3", 11 * @minute)
      put_until(:month_failed, 5_000)

      log =
        capture_log(fn -> assert dollars?(Budget.month_sum(@since, @limit, scan("9")), "3") end)

      refute_received :scanned
      assert log =~ "monthly sum that is"
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
