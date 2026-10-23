defmodule PhoenixKitAI.DeliveryTest do
  @moduledoc """
  How a provider call is made: retries with backoff, per-call timeout, per-call
  model and OpenRouter fallbacks, usage accounting, and the model recorded on the row.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.{Completion, Request}
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
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :retry)
      Application.delete_env(:phoenix_kit_ai, :timeout)
    end)

    {:ok, endpoint: endpoint_fixture("openrouter"), counter: :counters.new(1, [])}
  end

  defp endpoint_fixture(provider) do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Delivery-EP-#{System.unique_integer([:positive])}",
        provider: provider,
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    ep
  end

  @answer %{
    "model" => "google/gemini-2.5-flash",
    "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
    "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.25}
  }

  # answers `statuses` in order (then 200s), counting calls and forwarding each request body
  defp stub_sequence(counter, statuses, answer \\ @answer, retry_after \\ nil) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(test_pid, {:body, Jason.decode!(raw)})

      respond(conn, Enum.at(statuses, n), answer, retry_after)
    end)
  end

  defp respond(conn, nil, answer, _retry_after), do: Req.Test.json(conn, answer)

  defp respond(conn, :timeout, _answer, _retry_after),
    do: Req.Test.transport_error(conn, :timeout)

  defp respond(conn, status, _answer, retry_after) do
    conn =
      if retry_after,
        do: Plug.Conn.put_resp_header(conn, "retry-after", retry_after),
        else: conn

    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(%{"error" => %{"message" => "slow down", "code" => status}})
  end

  defp calls(counter), do: :counters.get(counter, 1)
  defp msgs, do: [%{role: "user", content: "hi"}]

  describe "retries" do
    test "off by default: a 429 is returned after one call", %{endpoint: ep, counter: c} do
      stub_sequence(c, [429])
      assert {:error, :rate_limited} = PhoenixKitAI.complete(ep.uuid, msgs())
      assert calls(c) == 1
    end

    test "retry: true recovers from 429s and 503s", %{endpoint: ep, counter: c} do
      stub_sequence(c, [429, 503])

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(), retry: [base_delay: 1, max_delay: 5])

      assert calls(c) == 3
    end

    test "max_attempts bounds the tries", %{endpoint: ep, counter: c} do
      stub_sequence(c, [500, 500, 500, 500])

      assert {:error, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(), retry: [max_attempts: 2, base_delay: 1])

      assert calls(c) == 2
    end

    test "a 400 is not retried", %{endpoint: ep, counter: c} do
      stub_sequence(c, [400])
      assert {:error, _} = PhoenixKitAI.complete(ep.uuid, msgs(), retry: [base_delay: 1])
      assert calls(c) == 1
    end

    test "the app env turns retries on for every call", %{endpoint: ep, counter: c} do
      Application.put_env(:phoenix_kit_ai, :retry, base_delay: 1, max_delay: 5)
      stub_sequence(c, [502])
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs())
      assert calls(c) == 2
    end

    test "a timeout is retried only with retry_timeouts: true", %{endpoint: ep, counter: c} do
      stub_sequence(c, [:timeout])

      assert {:error, :request_timeout} =
               PhoenixKitAI.complete(ep.uuid, msgs(), retry: [base_delay: 1])

      assert calls(c) == 1

      c2 = :counters.new(1, [])
      stub_sequence(c2, [:timeout])

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(),
                 retry: [base_delay: 1, retry_timeouts: true],
                 cache: false
               )

      assert calls(c2) == 2
    end

    test "each retry emits telemetry", %{endpoint: ep, counter: c} do
      ref = "retry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        ref,
        [:phoenix_kit_ai, :request, :retry],
        fn _e, m, meta, _ -> send(test_pid, {:retry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      stub_sequence(c, [429])
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), retry: [base_delay: 1])
      assert_receive {:retry, %{attempt: 1}, %{status: "HTTP 429"}}
    end

    test "retry_delay/3: exponential with jitter, Retry-After honoured, capped" do
      policy = [base_delay: 1_000, max_delay: 30_000]
      assert Completion.retry_delay(policy, 1, nil) in 800..1_200
      assert Completion.retry_delay(policy, 3, nil) in 3_200..4_800
      assert Completion.retry_delay(policy, 1, 7) == 7_000
      assert Completion.retry_delay(policy, 1, 600) == 30_000
    end
  end

  describe "model choice" do
    test "model: overrides the endpoint's model for one call", %{endpoint: ep, counter: c} do
      stub_sequence(c, [], Map.put(@answer, "model", "openai/gpt-4o-mini"))
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), model: "openai/gpt-4o-mini")
      assert_receive {:body, %{"model" => "openai/gpt-4o-mini"}}
    end

    test "models: is sent to OpenRouter as fallbacks, the call's model first", %{
      endpoint: ep,
      counter: c
    } do
      stub_sequence(c, [])

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(),
                 models: ["openai/gpt-4o-mini", "google/gemini-2.5-flash"]
               )

      assert_receive {:body, body}
      assert body["models"] == ["google/gemini-2.5-flash", "openai/gpt-4o-mini"]
    end

    test "the row keeps the model asked for and records a fallback that answered",
         %{endpoint: ep, counter: c} do
      stub_sequence(c, [], Map.put(@answer, "model", "openai/gpt-4o-mini"))
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), models: ["openai/gpt-4o-mini"])

      [row] = TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
      assert row.model == ep.model
      assert row.metadata["answered_model"] == "openai/gpt-4o-mini"
    end

    test "different models are cached apart", %{endpoint: ep, counter: c} do
      stub_sequence(c, [])
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), cache: true)

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(), cache: true, model: "openai/gpt-4o-mini")

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, msgs(), cache: true, retry: true, timeout: 5_000)

      # the third differs only in delivery options → served from the cache
      assert calls(c) == 2
    end
  end

  describe "usage accounting" do
    test "OpenRouter chat calls ask for usage (cost)", %{endpoint: ep, counter: c} do
      stub_sequence(c, [])
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs())
      assert_receive {:body, %{"usage" => %{"include" => true}}}

      [row] = TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
      assert row.cost_nanodollars == 250_000_000
    end

    test "other providers get neither usage nor models", %{counter: c} do
      ep = endpoint_fixture("mistral")
      stub_sequence(c, [])
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, msgs(), models: ["x/y"])
      assert_receive {:body, body}
      refute Map.has_key?(body, "usage")
      refute Map.has_key?(body, "models")
    end
  end

  describe "embeddings" do
    test "model: and retries apply to embed/3 too", %{endpoint: ep, counter: c} do
      emb = %{
        "model" => "openai/text-embedding-3-small",
        "data" => [%{"embedding" => [0.1, 0.2]}],
        "usage" => %{"prompt_tokens" => 2}
      }

      stub_sequence(c, [429], emb)

      assert {:ok, %{"data" => [_]}} =
               PhoenixKitAI.embed(ep.uuid, "hello",
                 model: "openai/text-embedding-3-small",
                 retry: [base_delay: 1]
               )

      assert calls(c) == 2
      assert_receive {:body, %{"model" => "openai/text-embedding-3-small"}}
    end
  end
end
