defmodule PhoenixKitAI.LimiterTest do
  @moduledoc "Concurrency limits per provider / endpoint key (no database)."

  use ExUnit.Case, async: false

  alias PhoenixKitAI.Limiter

  @ep %{uuid: "ep-uuid-1", name: "Label reader", provider: "openrouter"}

  setup do
    start_supervised!(Limiter)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :concurrency)
      Application.delete_env(:phoenix_kit_ai, :concurrency_defaults)
    end)

    :ok
  end

  defp worker(parent, id, hold_ms, opts \\ []) do
    spawn(fn ->
      result =
        Limiter.run(@ep, opts, fn ->
          started = System.monotonic_time(:millisecond)
          send(parent, {:started, id, started})
          Process.sleep(hold_ms)
          {:ok, id, started, System.monotonic_time(:millisecond)}
        end)

      send(parent, {:done, id, result})
    end)
  end

  defp collect(n, acc \\ %{}, started \\ []) do
    if map_size(acc) == n do
      {acc, Enum.reverse(started)}
    else
      receive do
        {:started, id, t} -> collect(n, acc, [{id, t} | started])
        {:done, id, r} -> collect(n, Map.put(acc, id, r), started)
      after
        10_000 -> flunk("workers did not finish (#{map_size(acc)}/#{n})")
      end
    end
  end

  describe "limit_for/2" do
    test "nothing configured → not limited" do
      assert Limiter.limit_for(@ep, []) == nil
    end

    test "provider key from the configuration" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 8})
      assert {"provider:openrouter", 8, _} = Limiter.limit_for(@ep, [])
    end

    test "an endpoint on a named connection shares its base provider's key" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 3})

      assert {"provider:openrouter", 3, _} =
               Limiter.limit_for(%{@ep | provider: "openrouter:work"}, [])
    end

    test "an endpoint key (name) wins over the provider key" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{
        "provider:openrouter" => 8,
        "endpoint:Label reader" => 2
      })

      assert {"endpoint:Label reader", 2, _} = Limiter.limit_for(@ep, [])
    end

    test "per call: own limit, own key, or off" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 8})
      assert {"provider:openrouter", 3, _} = Limiter.limit_for(@ep, concurrency: [limit: 3])
      assert {"batch", 2, _} = Limiter.limit_for(@ep, concurrency: [key: "batch", limit: 2])
      assert Limiter.limit_for(@ep, concurrency: false) == nil
    end
  end

  describe "run/3" do
    test "without a limit the function runs directly" do
      assert Limiter.run(@ep, [], fn -> :direct end) == :direct
    end

    test "never more than `limit` at once, admitted in arrival order" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 2})

      for id <- 1..6,
          do:
            (
              worker(self(), id, 120)
              Process.sleep(10)
            )

      {results, started} = collect(6)

      windows = for {_, {:ok, _, a, b}} <- results, do: {a, b}

      max_conc =
        windows
        |> Enum.map(fn {a, _} -> Enum.count(windows, fn {x, y} -> x <= a and a < y end) end)
        |> Enum.max()

      assert map_size(results) == 6
      assert max_conc <= 2
      assert Enum.map(started, &elem(&1, 0)) == Enum.to_list(1..6)
      assert Limiter.stats("provider:openrouter") == %{running: 0, waiting: 0}
    end

    test "a waiting call reports its position when asked" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      worker(self(), :holder, 300)
      Process.sleep(20)
      worker(self(), :second, 10)
      Process.sleep(20)
      worker(self(), :third, 10, concurrency: [notify: self()])
      assert_receive {:phoenix_kit_ai_queue, "provider:openrouter", 2}, 1_000
      assert_receive {:phoenix_kit_ai_queue, "provider:openrouter", 1}, 1_000
      collect(3)
    end

    test "gives up after `wait` with :concurrency_limit_timeout" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      worker(self(), :holder, 500)
      Process.sleep(20)
      t = System.monotonic_time(:millisecond)

      assert {:error, :concurrency_limit_timeout} =
               Limiter.run(@ep, [concurrency: [wait: 100]], fn -> :never end)

      assert (System.monotonic_time(:millisecond) - t) in 90..400
      collect(1)
      Process.sleep(20)
      assert Limiter.stats("provider:openrouter") == %{running: 0, waiting: 0}
    end

    test "a go that races the timeout frees its slot and leaves nothing in the caller's mailbox" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      parent = self()
      holder = spawn(fn -> Limiter.run(@ep, [], fn -> receive(do: (:release -> :ok)) end) end)
      Process.sleep(20)

      waiter =
        spawn(fn ->
          result = Limiter.run(@ep, [concurrency: [wait: 100]], fn -> :ran end)
          # looked at only once the limiter has run again, so a go it sent late is in
          receive(do: (:check -> :ok))
          {:messages, messages} = Process.info(self(), :messages)
          send(parent, {:waiter, result, messages})
        end)

      Process.sleep(20)
      # The holder lets go while the limiter is paused, so the waiter's timeout
      # and the go it is then handed meet in the limiter's mailbox.
      :sys.suspend(Limiter)
      send(holder, :release)
      Process.sleep(150)
      :sys.resume(Limiter)
      Process.sleep(50)
      send(waiter, :check)

      assert_receive {:waiter, {:error, :concurrency_limit_timeout}, []}, 1_000
      refute Process.alive?(waiter)
      assert Limiter.stats("provider:openrouter") == %{running: 0, waiting: 0}
      assert Limiter.run(@ep, [], fn -> :free end) == :free
    end

    test "a raised limit lets the calls already waiting in first" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      worker(self(), :holder, 400)
      Process.sleep(20)
      worker(self(), :queued, 10)
      Process.sleep(20)
      assert %{running: 1, waiting: 1} = Limiter.stats("provider:openrouter")

      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 3})
      t = System.monotonic_time(:millisecond)
      assert Limiter.run(@ep, [], fn -> :newcomer end) == :newcomer
      # neither waits for the holder's 400 ms: the waiting call is let in first
      assert System.monotonic_time(:millisecond) - t < 150
      assert_received {:started, :queued, _}
      collect(2)
    end

    test "refuses with :concurrency_queue_full when `max_waiting` are already waiting" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      Application.put_env(:phoenix_kit_ai, :concurrency_defaults, max_waiting: 1)
      worker(self(), :holder, 300)
      Process.sleep(20)
      worker(self(), :waiter, 10)
      Process.sleep(20)
      assert {:error, :concurrency_queue_full} = Limiter.run(@ep, [], fn -> :never end)
      collect(2)
    end

    test "a caller that dies gives back its slot and its place" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      holder = spawn(fn -> Limiter.run(@ep, [], fn -> Process.sleep(10_000) end) end)
      Process.sleep(20)
      waiter = spawn(fn -> Limiter.run(@ep, [], fn -> :ok end) end)
      Process.sleep(20)
      assert %{running: 1, waiting: 1} = Limiter.stats("provider:openrouter")

      Process.exit(waiter, :kill)
      Process.sleep(20)
      assert %{running: 1, waiting: 0} = Limiter.stats("provider:openrouter")

      Process.exit(holder, :kill)
      Process.sleep(20)
      assert Limiter.run(@ep, [], fn -> :free end) == :free
    end

    # A limiter too busy to answer within GenServer.call's 5 s runs the call
    # unlimited; the acquire it answers late must not keep a slot for a
    # caller that never learns of it (a LiveView or a job lives on).
    @tag timeout: 20_000
    test "an acquire answered too late keeps no slot for the caller" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      :sys.suspend(Limiter)
      # run here, in the test process, so the caller outlives the call
      assert Limiter.run(@ep, [], fn -> :unlimited_run end) == :unlimited_run
      :sys.resume(Limiter)
      assert %{running: 0, waiting: 0} = Limiter.stats("provider:openrouter")
      assert Limiter.run(@ep, [concurrency: [wait: 100]], fn -> :free end) == :free
    end

    test "the slot is released when the function raises" do
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      assert_raise RuntimeError, fn -> Limiter.run(@ep, [], fn -> raise "boom" end) end
      assert Limiter.run(@ep, [], fn -> :after end) == :after
    end
  end
end
