defmodule PhoenixKitAI.QueryLogRedactionTest do
  @moduledoc """
  Writes that carry conversation content or secrets (usage rows with
  captured messages, endpoint api keys, prompt texts) must not reach the
  Ecto query log, which prints every query parameter at `:debug`.

  `async: false`: the Logger level is global.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    Application.delete_env(:phoenix_kit_ai, :capture_request_content)

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  # Proves the test repo really logs query parameters at this level; without
  # it every refute below would pass vacuously.
  test "the test repo logs query parameters at :debug" do
    log =
      capture_log([level: :debug], fn ->
        TestRepo.query!("SELECT $1::text", ["query-log-canary"])
      end)

    assert log =~ "query-log-canary"
  end

  test "a usage row with captured content keeps the messages and the reply out of the log" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(success_payload("REPLY-SENTINEL-7d1c")))
    end)

    endpoint = endpoint_fixture()

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _} =
                 PhoenixKitAI.complete(endpoint.uuid, [
                   %{role: "user", content: "PROMPT-SENTINEL-3a9f"}
                 ])
      end)

    row = Enum.find(elem(PhoenixKitAI.list_requests(), 0), &(&1.endpoint_uuid == endpoint.uuid))
    assert row.metadata["response"] == "REPLY-SENTINEL-7d1c"
    assert inspect(row.metadata["messages"]) =~ "PROMPT-SENTINEL-3a9f"

    refute log =~ "PROMPT-SENTINEL-3a9f"
    refute log =~ "REPLY-SENTINEL-7d1c"
  end

  test "a usage row written inside a caller's transaction stays out of the log too" do
    log =
      capture_log([level: :debug], fn ->
        assert {:ok, {:ok, _}} =
                 TestRepo.transaction(fn ->
                   PhoenixKitAI.create_request(%{
                     model: "anthropic/claude-3-haiku",
                     request_type: "chat",
                     status: "success",
                     metadata: %{
                       "messages" => [%{"role" => "user", "content" => "TX-SENTINEL-4b62"}],
                       "response" => "TX-REPLY-SENTINEL-90fd"
                     }
                   })
                 end)
      end)

    refute log =~ "TX-SENTINEL-4b62"
    refute log =~ "TX-REPLY-SENTINEL-90fd"
  end

  test "creating and updating an endpoint keeps the api key out of the log" do
    log =
      capture_log([level: :debug], fn ->
        endpoint = endpoint_fixture(%{api_key: "sk-SENTINEL-create-51e2"})

        assert {:ok, _} =
                 PhoenixKitAI.update_endpoint(endpoint, %{api_key: "sk-SENTINEL-update-88b4"})
      end)

    refute log =~ "sk-SENTINEL-create-51e2"
    refute log =~ "sk-SENTINEL-update-88b4"
  end

  test "creating and updating a prompt keeps its text out of the log" do
    log =
      capture_log([level: :debug], fn ->
        assert {:ok, prompt} =
                 PhoenixKitAI.create_prompt(%{
                   name: "P-#{System.unique_integer([:positive])}",
                   content: "PROMPT-TEXT-SENTINEL-c047 {{Text}}"
                 })

        assert {:ok, _} =
                 PhoenixKitAI.update_prompt(prompt, %{
                   content: "PROMPT-TEXT-SENTINEL-e913 {{Text}}"
                 })
      end)

    refute log =~ "PROMPT-TEXT-SENTINEL-c047"
    refute log =~ "PROMPT-TEXT-SENTINEL-e913"
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "anthropic/claude-3-haiku",
      api_key: "sk-test-key"
    }

    {:ok, endpoint} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    endpoint
  end

  defp success_payload(content) do
    %{
      "id" => "gen-1",
      "model" => "anthropic/claude-3-haiku",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end
end
