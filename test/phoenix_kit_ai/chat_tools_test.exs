defmodule PhoenixKitAI.ChatToolsTest do
  @moduledoc """
  Tool calling through `complete/3`: the request body keeps `tool_calls`,
  `tool_call_id` and `name`, takes `tools` / `tool_choice` /
  `parallel_tool_calls`, the response's `tool_calls` are readable, a
  `tools` call bypasses the cache, and `capture_request_content:` decides
  per call whether a usage row stores message content.

  The provider is a `Req.Test` stub; every request body is captured and
  asserted. Nothing leaves the process.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Completion, Request}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  @tools [
    %{
      "type" => "function",
      "function" => %{
        "name" => "get_order",
        "description" => "Look an order up",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"number" => %{"type" => "string"}},
          "required" => ["number"]
        }
      }
    }
  ]

  @tool_call %{
    "id" => "call_1",
    "type" => "function",
    "function" => %{"name" => "get_order", "arguments" => ~s({"number":"A-1"})}
  }

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.ChatToolsTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :capture_request_content)
    end)

    :ok
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "Tools-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "deepseek/deepseek-v4-flash",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  # Every POST body is forwarded to the test process verbatim (the raw
  # JSON string and its decoded form); the answer is canned.
  defp stub(answer, status \\ 200) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:post, conn.request_path, raw, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(answer))
    end)
  end

  defp text_answer(content) do
    %{
      "model" => "deepseek/deepseek-v4-flash",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end

  defp tool_call_answer(message_extra \\ %{}) do
    message = Map.merge(%{"role" => "assistant", "tool_calls" => [@tool_call]}, message_extra)

    %{
      "model" => "deepseek/deepseek-v4-flash",
      "choices" => [%{"message" => message, "finish_reason" => "tool_calls"}],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
    }
  end

  defp rows(endpoint),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))

  defp row(endpoint) do
    assert [row] = rows(endpoint)
    row
  end

  defp posts do
    receive do
      {:post, _path, _raw, body} -> [body | posts()]
    after
      0 -> []
    end
  end

  describe "request body" do
    test "without the new options it is byte-for-byte what it was" do
      stub(text_answer("hi"))
      ep = endpoint_fixture()

      messages = [
        %{role: "system", content: "Be brief."},
        %{"role" => "user", "content" => "Hello"},
        # fields the body never carried stay out of it
        %{role: :assistant, content: "Hi", name: "bot", tool_calls: nil, extra: 1},
        %{role: "user", content: [%{"type" => "text", "text" => "parts"}], name: "ann"}
      ]

      assert {:ok, _} = Completion.chat_completion(ep, messages)

      assert_received {:post, "/api/v1/chat/completions", raw, _}

      assert raw ==
               ~s({"messages":[) <>
                 ~s({"content":"Be brief.","role":"system"},) <>
                 ~s({"content":"Hello","role":"user"},) <>
                 ~s({"content":"Hi","role":"assistant"},) <>
                 ~s({"content":[{"text":"parts","type":"text"}],"role":"user"}) <>
                 ~s(],"model":"deepseek/deepseek-v4-flash"})
    end

    test "keeps tool_calls on assistant and tool_call_id + name on tool messages" do
      stub(text_answer("Order A-1 is paid."))
      ep = endpoint_fixture()

      messages = [
        %{role: "user", content: "Status of A-1?"},
        %{role: "assistant", content: nil, tool_calls: [@tool_call]},
        %{role: "tool", tool_call_id: "call_1", name: "get_order", content: ~s({"paid":true})},
        # string keys work the same
        %{
          "role" => "assistant",
          "content" => "Looking.",
          "tool_calls" => [@tool_call]
        },
        %{"role" => "tool", "tool_call_id" => "call_2", "name" => "x", "content" => "{}"}
      ]

      assert {:ok, _} = Completion.chat_completion(ep, messages)
      assert_received {:post, _, _, %{"messages" => sent}}

      assert sent == [
               %{"role" => "user", "content" => "Status of A-1?"},
               %{"role" => "assistant", "content" => nil, "tool_calls" => [@tool_call]},
               %{
                 "role" => "tool",
                 "tool_call_id" => "call_1",
                 "name" => "get_order",
                 "content" => ~s({"paid":true})
               },
               %{"role" => "assistant", "content" => "Looking.", "tool_calls" => [@tool_call]},
               %{"role" => "tool", "tool_call_id" => "call_2", "name" => "x", "content" => "{}"}
             ]
    end

    test "an empty tool_calls list is not sent, and tool fields stay on their own roles" do
      stub(text_answer("ok"))
      ep = endpoint_fixture()

      messages = [
        %{role: "assistant", content: "x", tool_calls: []},
        %{role: "user", content: "y", tool_call_id: "c", name: "n", tool_calls: [@tool_call]}
      ]

      assert {:ok, _} = Completion.chat_completion(ep, messages)
      assert_received {:post, _, _, %{"messages" => sent}}

      assert sent == [
               %{"role" => "assistant", "content" => "x"},
               %{"role" => "user", "content" => "y"}
             ]
    end

    test ":tools, :tool_choice and :parallel_tool_calls go into the body when set" do
      stub(text_answer("ok"))
      ep = endpoint_fixture()

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}],
                 tools: @tools,
                 tool_choice: "auto",
                 parallel_tool_calls: false
               )

      assert_received {:post, _, _, body}
      assert body["tools"] == @tools
      assert body["tool_choice"] == "auto"
      assert body["parallel_tool_calls"] == false
    end

    test "tool_choice may name a function" do
      stub(text_answer("ok"))
      ep = endpoint_fixture()
      choice = %{"type" => "function", "function" => %{"name" => "get_order"}}

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}],
                 tools: @tools,
                 tool_choice: choice,
                 parallel_tool_calls: true
               )

      assert_received {:post, _, _, body}
      assert body["tool_choice"] == choice
      assert body["parallel_tool_calls"] == true
    end

    test "the three keys are absent when not given" do
      stub(text_answer("ok"))
      ep = endpoint_fixture()

      assert {:ok, _} =
               Completion.chat_completion(ep, [%{role: "user", content: "hi"}], tools: [])

      assert_received {:post, _, _, body}
      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "tool_choice")
      refute Map.has_key?(body, "parallel_tool_calls")
    end
  end

  describe "reading the answer" do
    test "extract_tool_calls/1 returns choices[0].message.tool_calls" do
      response = %{"choices" => [%{"message" => %{"tool_calls" => [@tool_call]}}]}

      assert Completion.extract_tool_calls(response) == [@tool_call]
      assert PhoenixKitAI.extract_tool_calls(response) == [@tool_call]
    end

    test "extract_tool_calls/1 is [] for a plain answer, null, empty or malformed responses" do
      assert Completion.extract_tool_calls(text_answer("hi")) == []

      assert Completion.extract_tool_calls(%{
               "choices" => [%{"message" => %{"tool_calls" => nil}}]
             }) == []

      assert Completion.extract_tool_calls(%{
               "choices" => [%{"message" => %{"tool_calls" => []}}]
             }) == []

      assert Completion.extract_tool_calls(%{"choices" => []}) == []
      assert Completion.extract_tool_calls(%{"error" => "x"}) == []
      assert Completion.extract_tool_calls(nil) == []
    end

    test "extract_content/1 gives {:ok, nil} for content: nil, with or without the key" do
      assert Completion.extract_content(tool_call_answer(%{"content" => nil})) == {:ok, nil}
      assert Completion.extract_content(tool_call_answer()) == {:ok, nil}
    end

    test "extract_content/1 still rejects a message with neither content nor tool_calls" do
      assert Completion.extract_content(%{
               "choices" => [%{"message" => %{"role" => "assistant"}}]
             }) ==
               {:error, :invalid_response_format}
    end
  end

  describe "complete/3 with tools" do
    test "returns the tool_calls and logs the row (content nil) with capture on" do
      stub(tool_call_answer(%{"content" => nil}))
      ep = endpoint_fixture()

      assert {:ok, response} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "A-1?"}],
                 tools: @tools,
                 user_uuid: nil
               )

      assert PhoenixKitAI.extract_tool_calls(response) == [@tool_call]

      row = row(ep)
      assert row.status == "success"
      assert row.total_tokens == 29
      assert row.metadata["response"] == nil
      assert [%{"role" => "user", "content" => "A-1?"}] = row.metadata["messages"]
    end

    test "the journal keeps the tool messages of a later round" do
      stub(text_answer("Paid."))
      ep = endpoint_fixture()

      messages = [
        %{role: "user", content: "A-1?"},
        %{role: "assistant", content: nil, tool_calls: [@tool_call]},
        %{role: "tool", tool_call_id: "call_1", name: "get_order", content: ~s({"paid":true})}
      ]

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, tools: @tools)

      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "content" => nil, "tool_calls" => [@tool_call]},
               %{"role" => "tool", "tool_call_id" => "call_1", "name" => "get_order"}
             ] = row(ep).metadata["messages"]
    end

    test "cache: true is ignored when tools are given: every call reaches the provider" do
      stub(tool_call_answer())
      ep = endpoint_fixture()
      messages = [%{role: "user", content: "A-1?"}]

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, tools: @tools, cache: true)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, tools: @tools, cache: true)

      assert length(posts()) == 2
      assert length(rows(ep)) == 2
      refute Enum.any?(rows(ep), & &1.metadata["cached"])
    end

    test "cache: [key: ...] and :refresh are ignored as well" do
      stub(tool_call_answer())
      ep = endpoint_fixture()
      messages = [%{role: "user", content: "A-1?"}]

      for cache <- [[key: "k"], [key: "k"], :refresh] do
        assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, tools: @tools, cache: cache)
      end

      assert length(posts()) == 3
    end

    test "without tools the cache works as before" do
      stub(text_answer("hi"))
      ep = endpoint_fixture()
      messages = [%{role: "user", content: "hello"}]

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, cache: true)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, cache: true)

      assert length(posts()) == 1
    end

    test "a cached call over tool-role messages and part lists builds its key" do
      stub(text_answer("fine"))
      ep = endpoint_fixture()

      messages = [
        %{role: "user", content: [%{"type" => "text", "text" => "A-1?"}]},
        %{role: "assistant", content: nil, tool_calls: [@tool_call]},
        %{role: "tool", tool_call_id: "call_1", name: "get_order", content: "{}"}
      ]

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, cache: true)
      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, cache: true)

      assert length(posts()) == 1
    end
  end

  describe "capture_request_content: per call" do
    test "false overrides the global default (true): no content, base metadata stays" do
      stub(text_answer("secret answer"))
      ep = endpoint_fixture()

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "secret"}],
                 capture_request_content: false,
                 source: "agent",
                 user_uuid: nil
               )

      row = row(ep)
      assert row.metadata["content_redacted"] == true
      assert row.metadata["source"] == "agent"
      assert is_map(row.metadata["caller_context"])
      refute Map.has_key?(row.metadata, "messages")
      refute Map.has_key?(row.metadata, "response")
      refute Map.has_key?(row.metadata, "request_payload")
      assert row.total_tokens == 8
    end

    test "true overrides the global false" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      stub(text_answer("kept answer"))
      ep = endpoint_fixture()

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "kept"}],
                 capture_request_content: true
               )

      row = row(ep)
      refute Map.has_key?(row.metadata, "content_redacted")
      assert row.metadata["response"] == "kept answer"
      assert [%{"content" => "kept"}] = row.metadata["messages"]
    end

    test "not given: the global setting decides, as before" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      stub(text_answer("x"))
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "x"}])
      assert row(ep).metadata["content_redacted"] == true
    end

    test "the failed-request row honours it too" do
      stub(%{"error" => %{"message" => "boom"}}, 500)
      ep = endpoint_fixture()

      assert {:error, {:api_error, 500}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "secret"}],
                 capture_request_content: false,
                 source: "agent"
               )

      row = row(ep)
      assert row.status == "error"
      assert row.metadata["content_redacted"] == true
      assert row.metadata["source"] == "agent"
      refute Map.has_key?(row.metadata, "messages")

      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)

      assert {:error, {:api_error, 500}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "shown"}],
                 capture_request_content: true
               )

      assert Enum.any?(rows(ep), &match?(%{"messages" => [%{"content" => "shown"}]}, &1.metadata))
    end

    test "the option does not change the cache key" do
      stub(text_answer("hi"))
      ep = endpoint_fixture()
      messages = [%{role: "user", content: "hello"}]

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, messages, cache: true)

      assert {:ok, _} =
               PhoenixKitAI.complete(ep.uuid, messages,
                 cache: true,
                 capture_request_content: false
               )

      assert length(posts()) == 1
    end

    test "describe_image/3: false redacts the prompt and the answer, base metadata stays" do
      stub(text_answer("A chocolate bar."))
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok, %{text: "A chocolate bar."}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 prompt: "What is on the secret label?",
                 capture_request_content: false,
                 source: "agent"
               )

      row = row(ep)
      assert row.request_type == "vision"
      assert row.metadata["source"] == "agent"
      assert row.metadata["input_image_count"] == 1
      refute Map.has_key?(row.metadata, "input")
      refute Map.has_key?(row.metadata, "response")
    end

    test "describe_image/3: true overrides the global false" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      stub(text_answer("A chocolate bar."))
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok, _} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 prompt: "What is on the label?",
                 capture_request_content: true
               )

      row = row(ep)
      assert row.metadata["input"] == "What is on the label?"
      assert row.metadata["response"] == "A chocolate bar."
    end

    test "describe_image/3: the failed row and the unparsed-JSON row honour it" do
      stub(%{"error" => %{"message" => "boom"}}, 500)
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:error, _} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 prompt: "secret prompt",
                 capture_request_content: false
               )

      failed = row(ep)
      assert failed.status == "error"
      assert failed.metadata["error_reason"] == ":api_error"
      refute Map.has_key?(failed.metadata, "input")

      stub(text_answer("prose, not json"))
      ep2 = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.describe_image(ep2.uuid, @jpeg,
                 prompt: "secret prompt",
                 json: true,
                 capture_request_content: false
               )

      unparsed = row(ep2)
      assert unparsed.status == "success"
      refute Map.has_key?(unparsed.metadata, "input")
      refute Map.has_key?(unparsed.metadata, "response")
    end
  end
end
