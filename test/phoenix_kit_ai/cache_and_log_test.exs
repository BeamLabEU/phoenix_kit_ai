defmodule PhoenixKitAI.CacheAndLogTest do
  @moduledoc "The endpoint/credential lookup cache and the asynchronous usage log."

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias PhoenixKitAI.{Cache, Request, RequestLog}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    PhoenixKitAI.RequestCache.clear()

    on_exit(fn ->
      for key <- [:req_options, :request_log_mode, :log_cache_hits, :request_cache],
          do: Application.delete_env(:phoenix_kit_ai, key)

      # config/test.exs turns the lookup caches off; restore that
      Application.put_env(:phoenix_kit_ai, :endpoint_cache_ttl, 0)
      Application.put_env(:phoenix_kit_ai, :credential_cache_ttl, 0)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "model" => "google/gemini-2.5-flash",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.25}
      })
    end)

    {:ok, endpoint: endpoint_fixture()}
  end

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Cache-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    ep
  end

  defp rows(ep), do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
  defp msgs, do: [%{role: "user", content: "hi"}]

  describe "endpoint cache" do
    setup do
      start_supervised!(Cache)
      Application.put_env(:phoenix_kit_ai, :endpoint_cache_ttl, 300)
      :ok
    end

    test "resolve_endpoint/1 serves a cached row until update_endpoint/3 drops it", %{
      endpoint: ep
    } do
      assert {:ok, %{temperature: t0}} = PhoenixKitAI.resolve_endpoint(ep.uuid)

      # a change behind the API's back is not seen while cached…
      TestRepo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^ep.uuid),
        set: [temperature: 1.5]
      )

      assert {:ok, %{temperature: ^t0}} = PhoenixKitAI.resolve_endpoint(ep.uuid)

      # …a change through the API drops the entry at once
      {:ok, _} = PhoenixKitAI.update_endpoint(ep, %{temperature: 0.3})
      assert {:ok, %{temperature: 0.3}} = PhoenixKitAI.resolve_endpoint(ep.uuid)
    end

    test "a disabled endpoint is refused on the very next call", %{endpoint: ep} do
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs())
      {:ok, _} = PhoenixKitAI.update_endpoint(ep, %{enabled: false})
      assert {:error, :endpoint_disabled} = PhoenixKitAI.complete(ep.uuid, msgs())
    end

    test "the endpoints broadcast drops the entry (other nodes)", %{endpoint: ep} do
      assert {:ok, _} = PhoenixKitAI.resolve_endpoint(ep.uuid)

      TestRepo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^ep.uuid),
        set: [temperature: 1.5]
      )

      send(Process.whereis(Cache), {:endpoint_updated, ep.uuid})
      :sys.get_state(Cache)
      assert {:ok, %{temperature: 1.5}} = PhoenixKitAI.resolve_endpoint(ep.uuid)
    end

    test "a missing endpoint is not cached" do
      uuid = UUIDv7.generate()
      assert {:error, :endpoint_not_found} = PhoenixKitAI.resolve_endpoint(uuid)
      assert :ets.lookup(:phoenix_kit_ai_lookup_cache, {:endpoint, uuid}) == []
    end

    test "TTL 0 turns the cache off", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :endpoint_cache_ttl, 0)
      assert {:ok, _} = PhoenixKitAI.resolve_endpoint(ep.uuid)

      TestRepo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^ep.uuid),
        set: [temperature: 1.5]
      )

      assert {:ok, %{temperature: 1.5}} = PhoenixKitAI.resolve_endpoint(ep.uuid)
    end
  end

  describe "credential cache" do
    setup do
      start_supervised!(Cache)
      Application.put_env(:phoenix_kit_ai, :credential_cache_ttl, 300)
      :ok
    end

    test "cached until an integration change is announced" do
      # a stand-in for PhoenixKit.Integrations.get_credentials/1, so the test is about the cache
      {:ok, source} = Agent.start_link(fn -> "sk-test-key" end)

      read = fn ->
        Cache.credentials("openrouter", fn -> {:ok, %{"api_key" => Agent.get(source, & &1)}} end)
      end

      assert {:ok, %{"api_key" => "sk-test-key"}} = read.()

      # the key changes at the source: still the cached one…
      Agent.update(source, fn _ -> "sk-rotated" end)
      assert {:ok, %{"api_key" => "sk-test-key"}} = read.()

      # …until core announces an integration change
      send(Process.whereis(Cache), {:integration_setup_saved, "openrouter", %{}})
      :sys.get_state(Cache)
      assert {:ok, %{"api_key" => "sk-rotated"}} = read.()
    end

    test "a 2-tuple integration event clears credentials, not an endpoint" do
      assert {:ok, _} = Cache.credentials("k", fn -> {:ok, %{"api_key" => "a"}} end)
      send(Process.whereis(Cache), {:integration_disconnected, "openrouter"})
      :sys.get_state(Cache)

      assert {:ok, %{"api_key" => "b"}} =
               Cache.credentials("k", fn -> {:ok, %{"api_key" => "b"}} end)
    end

    test "a value looked up while an invalidation came is not kept" do
      assert {:ok, :old} =
               Cache.credentials("k3", fn ->
                 # the change lands while the old value is being read
                 Cache.invalidate_credentials()
                 {:ok, :old}
               end)

      assert {:ok, :new} = Cache.credentials("k3", fn -> {:ok, :new} end)

      Application.put_env(:phoenix_kit_ai, :endpoint_cache_ttl, 300)
      on_exit(fn -> Application.put_env(:phoenix_kit_ai, :endpoint_cache_ttl, 0) end)

      assert {:ok, :old_ep} =
               Cache.endpoint("ep-race", fn ->
                 Cache.invalidate_endpoint("ep-race")
                 {:ok, :old_ep}
               end)

      assert {:ok, :new_ep} = Cache.endpoint("ep-race", fn -> {:ok, :new_ep} end)
    end

    test "errors are not cached" do
      assert {:error, :nope} = Cache.credentials("k2", fn -> {:error, :nope} end)
      assert {:ok, %{}} = Cache.credentials("k2", fn -> {:ok, %{}} end)
    end
  end

  describe "asynchronous usage log" do
    setup do
      start_supervised!(RequestLog)
      Sandbox.allow(PhoenixKitAI.Test.Repo, self(), Process.whereis(RequestLog))
      Application.put_env(:phoenix_kit_ai, :request_log_mode, :async)
      :ok
    end

    test "the row is written by the log process, with telemetry", %{endpoint: ep} do
      ref = "req-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        ref,
        [:phoenix_kit_ai, :request],
        fn _e, _m, meta, _ -> send(test_pid, {:row, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs())
      RequestLog.flush()

      assert [%{request_type: "chat", cost_nanodollars: 250_000_000}] = rows(ep)
      assert_receive {:row, _}
    end

    test "the answer's request_uuid names the row written later", %{endpoint: ep} do
      assert {:ok, %{"request_uuid" => uuid}} = PhoenixKitAI.complete(ep.uuid, msgs())
      assert is_binary(uuid)
      RequestLog.flush()
      assert [%Request{uuid: ^uuid}] = rows(ep)
    end

    test "a row that would not insert is not queued: it fails now and names no row",
         %{endpoint: ep} do
      attrs = %{endpoint_uuid: ep.uuid, model: "m", request_type: "chat", input_tokens: -1}
      assert {:error, %Ecto.Changeset{}} = PhoenixKitAI.log_usage(attrs)

      assert {:ok, %Request{uuid: uuid}} =
               PhoenixKitAI.log_usage(%{attrs | input_tokens: 1})

      RequestLog.flush()
      assert [%Request{uuid: ^uuid}] = rows(ep)
    end

    test "create_request/1 itself stays synchronous", %{endpoint: ep} do
      # the describe's mode is :async; the row must be there with no flush
      assert {:ok, %Request{uuid: uuid}} =
               PhoenixKitAI.create_request(%{
                 endpoint_uuid: ep.uuid,
                 model: "m",
                 request_type: "chat",
                 status: "success"
               })

      assert [%Request{uuid: ^uuid}] = rows(ep)
    end

    test ":sync (the default) writes before the call returns", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :request_log_mode, :sync)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs())
      assert [_] = rows(ep)
    end
  end

  describe "cache hits" do
    test "a hit writes a zero-cost row by default", %{endpoint: ep} do
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)
      assert length(rows(ep)) == 2
    end

    test "log_cache_hit: false writes none for the hit, and the answer names no row",
         %{endpoint: ep} do
      assert {:ok, %{"request_uuid" => fresh}} =
               PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)

      assert is_binary(fresh)

      assert {:ok, %{"request_uuid" => nil}} =
               PhoenixKitAI.complete(ep.uuid, msgs(), cache: true, log_cache_hit: false)

      assert length(rows(ep)) == 1
    end

    test "config log_cache_hits: false does the same for every call", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :log_cache_hits, false)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)
      assert length(rows(ep)) == 1
    end
  end
end
