defmodule PhoenixKitAI.CallPathHardeningTest do
  @moduledoc """
  What the shared call path does with answers and failures a provider or the
  client should not produce, but do: an HTTP client error that carries the
  request's headers, a 200 body that does not parse or is not an answer, a
  value the database refuses, retry and limiter options that are not numbers.
  None of them may leak a credential or an answer, raise into the caller after
  a paid call, or lose the call's usage row.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKitAI.{Limiter, OpenRouterClient, Request}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @secret "sk-or-v1-THE-SECRET-KEY"

  # A Req adapter whose request never leaves: the client refuses the header
  # value — a key saved with a stray character — and says so with the whole
  # header, bearer token included.
  defmodule HeaderRefused do
    @moduledoc false
    def run(request) do
      {request,
       %Req.HTTPError{
         protocol: :http1,
         reason: {:invalid_header_value, "authorization", "Bearer sk-or-v1-THE-SECRET-KEY\x01"}
       }}
    end
  end

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :retry)
      Application.delete_env(:phoenix_kit_ai, :concurrency)
    end)

    {:ok, endpoint: endpoint()}
  end

  defp endpoint(attrs \\ %{}) do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Hardening #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "anthropic/claude-3-haiku",
            api_key: "sk-test-key"
          },
          attrs
        )
      )

    ep
  end

  defp answer(content, extra \\ %{}) do
    Map.merge(
      %{
        "model" => "anthropic/claude-3-haiku",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      },
      extra
    )
  end

  defp counting_stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :posted)
      fun.(conn)
    end)
  end

  defp raw(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp rows(endpoint),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))

  defp posts(n \\ 0) do
    receive do
      :posted -> posts(n + 1)
    after
      0 -> n
    end
  end

  describe "a client error that carries the request" do
    setup do
      Application.put_env(:phoenix_kit_ai, :req_options, adapter: HeaderRefused, retry: false)
      :ok
    end

    test "names only its kind: in the result, the log, the row and the message", %{
      endpoint: ep
    } do
      Application.put_env(:phoenix_kit_ai, :retry, max_attempts: 3, base_delay: 1, max_delay: 1)

      log =
        capture_log(fn ->
          assert {:error,
                  {:connection_error, {:http_error, Req.HTTPError, :invalid_header_value}} =
                    reason} = PhoenixKitAI.ask(ep.uuid, "Hello")

          refute PhoenixKitAI.Errors.message(reason) =~ @secret
          assert PhoenixKitAI.Errors.message(reason) =~ "Req.HTTPError"
        end)

      refute log =~ @secret
      assert [%Request{status: "error", error_message: message, metadata: metadata}] = rows(ep)
      refute message =~ @secret
      refute inspect(metadata) =~ @secret
    end
  end

  describe "a 200 that is not an answer" do
    test "a body that does not parse is an error, retried never, its text logged nowhere", %{
      endpoint: ep
    } do
      Application.put_env(:phoenix_kit_ai, :retry, max_attempts: 3, base_delay: 1, max_delay: 1)
      counting_stub(&raw(&1, 200, ~s({"choices": [{"message": {"content": "the secret answer)))

      log =
        capture_log(fn ->
          assert {:error, :invalid_json_response} = PhoenixKitAI.ask(ep.uuid, "Hello")
        end)

      assert posts() == 1
      refute log =~ "secret answer"
      assert [%Request{status: "error", error_message: message}] = rows(ep)
      refute message =~ "secret answer"
    end

    test "JSON that is not an object is an error, not a raise", %{endpoint: ep} do
      counting_stub(&raw(&1, 200, "[]"))
      assert {:error, :invalid_response_format} = PhoenixKitAI.ask(ep.uuid, "Hello")

      counting_stub(&raw(&1, 200, "42"))
      assert {:error, :invalid_response_format} = PhoenixKitAI.embed(ep.uuid, "Hello")
    end

    test "an error without a code is an error, and is not cached", %{endpoint: ep} do
      counting_stub(&raw(&1, 200, ~s({"error": {"message": "upstream overloaded"}})))

      for _ <- 1..2 do
        assert {:error, _reason} = PhoenixKitAI.ask(ep.uuid, "Hello", cache: true)
      end

      assert posts() == 2
      assert Enum.all?(rows(ep), &(&1.status == "error"))
    end
  end

  describe "a row the database would refuse" do
    test "a NUL in the answer and a long model name: the answer and its row both arrive", %{
      endpoint: ep
    } do
      long_model = "vendor/" <> String.duplicate("m", 200)
      counting_stub(&Req.Test.json(&1, answer("before\u0000after")))

      assert {:ok, response} = PhoenixKitAI.ask(ep.uuid, "Hi\u0000there", model: long_model)
      assert {:ok, "before\u0000after"} = PhoenixKitAI.extract_content(response)

      assert [%Request{status: "success", model: model, metadata: metadata}] = rows(ep)
      assert String.length(model) == 150
      refute inspect(metadata) =~ "\\0"
      assert metadata["response"] == "beforeafter"
    end
  end

  describe "retry options that are not numbers" do
    test "fall back to their defaults instead of retrying for ever", %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :retry,
        max_attempts: nil,
        base_delay: 1,
        max_delay: nil
      )

      counting_stub(&raw(&1, 503, ~s({"error": {"message": "busy"}})))

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   PhoenixKitAI.ask(ep.uuid, "Hello", retry: [max_attempts: nil, max_delay: 1])
        end)

      assert posts() == 3
      assert log =~ "retry option max_attempts: nil is not valid"
    end
  end

  describe "the limiter's wait" do
    test ":infinity waits for the slot; a value that is no number is the default", %{
      endpoint: ep
    } do
      start_supervised!(Limiter)
      Application.put_env(:phoenix_kit_ai, :concurrency, %{"provider:openrouter" => 1})
      parent = self()

      holder =
        spawn(fn ->
          Limiter.run(ep, [], fn ->
            send(parent, :holding)
            receive(do: (:release -> :ok))
          end)
        end)

      assert_receive :holding

      waiter =
        Task.async(fn -> Limiter.run(ep, [concurrency: [wait: :infinity]], fn -> :ran end) end)

      Process.sleep(50)
      assert %{running: 1, waiting: 1} = Limiter.stats("provider:openrouter")
      send(holder, :release)
      assert Task.await(waiter) == :ran
      assert Limiter.run(ep, [concurrency: [wait: "soon"]], fn -> :also end) == :also
      assert Limiter.stats("provider:openrouter") == %{running: 0, waiting: 0}
    end
  end

  test "a key pasted with a trailing newline is sent without it" do
    assert {"Authorization", "Bearer sk-or-v1-abc"} in OpenRouterClient.build_headers(
             "  sk-or-v1-abc\n"
           )
  end
end
