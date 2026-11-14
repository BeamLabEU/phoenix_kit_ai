defmodule PhoenixKitAI.Providers.BedrockConverseTest do
  @moduledoc """
  Chat on Amazon Bedrock through Converse: which calls take it, the request
  translated from the chat-completions shape, the answer and the errors
  translated back. The request and answer shapes are those of the Converse
  API reference and of live calls to `eu.anthropic.claude-haiku-4-5` on a
  test account. HTTP goes to `Req.Test` stubs only.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Providers.BedrockConverse

  @haiku "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp endpoint(model, attrs \\ %{}) do
    {:ok, endpoint} =
      %{
        name: "Bedrock #{System.unique_integer([:positive])}",
        provider: "amazon_bedrock",
        model: model,
        api_key: "ABSK-test-key"
      }
      |> Map.merge(attrs)
      |> PhoenixKitAI.create_endpoint()

    endpoint
  end

  # Answers every request with `answer` (a Converse body) and sends the test
  # the request's path, authorization header and decoded body.
  defp stub(status \\ 200, answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {
        :request,
        conn.request_path,
        Plug.Conn.get_req_header(conn, "authorization"),
        Jason.decode!(raw)
      })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(answer))
    end)
  end

  defp converse_answer(content, stop_reason \\ "end_turn") do
    %{
      "output" => %{"message" => %{"role" => "assistant", "content" => content}},
      "stopReason" => stop_reason,
      "usage" => %{
        "inputTokens" => 10,
        "outputTokens" => 5,
        "totalTokens" => 15,
        "cacheReadInputTokens" => 0,
        "cacheWriteInputTokens" => 0
      },
      "metrics" => %{"latencyMs" => 424}
    }
  end

  describe "converse?/2" do
    test "an amazon_bedrock endpoint with a model other than openai.* takes Converse" do
      ep = %{provider: "amazon_bedrock"}

      for model <- [
            @haiku,
            "eu.anthropic.claude-opus-4-6-v1",
            "global.anthropic.claude-sonnet-5",
            "anthropic.claude-haiku-4-5-20251001-v1:0",
            "arn:aws:bedrock:eu-central-1:123456789012:inference-profile/eu.anthropic.claude-sonnet-5",
            "amazon.nova-pro-v1:0"
          ] do
        assert BedrockConverse.converse?(ep, model), model
      end

      assert BedrockConverse.converse?(%{provider: "amazon_bedrock:work"}, @haiku)
    end

    test "gpt-oss models stay on the OpenAI-compatible URL, other providers never take it" do
      refute BedrockConverse.converse?(%{provider: "amazon_bedrock"}, "openai.gpt-oss-120b-1:0")
      refute BedrockConverse.converse?(%{provider: "amazon_bedrock"}, "us.openai.gpt-oss-20b-1:0")
      refute BedrockConverse.converse?(%{provider: "anthropic"}, "claude-opus-5-5")
      refute BedrockConverse.converse?(%{provider: "openrouter"}, @haiku)
      refute BedrockConverse.converse?(%{provider: "amazon_bedrock"}, nil)
      refute BedrockConverse.converse?(%{provider: nil}, @haiku)
    end

    test "claude_id/1 reads the Anthropic model id out of a Bedrock id" do
      assert BedrockConverse.claude_id(@haiku) == "claude-haiku-4-5-20251001"
      assert BedrockConverse.claude_id("eu.anthropic.claude-opus-4-6-v1") == "claude-opus-4-6"

      assert BedrockConverse.claude_id("global.anthropic.claude-sonnet-5-5") ==
               "claude-sonnet-5-5"

      assert BedrockConverse.claude_id(
               "arn:aws:bedrock:eu-central-1:1:inference-profile/eu.anthropic.claude-opus-4-7"
             ) == "claude-opus-4-7"

      assert BedrockConverse.claude_id("amazon.nova-pro-v1:0") == nil
      assert BedrockConverse.claude_id(nil) == nil
    end
  end

  describe "the request" do
    test "goes to /model/<id>/converse on the base URL's host with the key as a Bearer token" do
      stub(converse_answer([%{"text" => "OK."}]))
      ep = endpoint(@haiku)

      assert {:ok, response} = PhoenixKitAI.ask(ep.uuid, "Say OK.", max_tokens: 20)

      assert_received {:request, path, ["Bearer ABSK-test-key"], body}
      assert path == "/model/eu.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse"

      assert body == %{
               "messages" => [%{"role" => "user", "content" => [%{"text" => "Say OK."}]}],
               # 0.7: the endpoint's default temperature, which Claude Haiku 4.5 takes.
               "inferenceConfig" => %{"maxTokens" => 20, "temperature" => 0.7}
             }

      assert {:ok, "OK."} = PhoenixKitAI.extract_content(response)
      assert response["model"] == @haiku
    end

    test "the region is the base URL's host; its path is not used" do
      stub(converse_answer([%{"text" => "OK."}]))

      ep = %Endpoint{
        uuid: Ecto.UUID.generate(),
        provider: "amazon_bedrock",
        base_url: "https://bedrock-runtime.eu-west-1.amazonaws.com/openai/v1",
        model: @haiku,
        api_key: "ABSK-test-key"
      }

      assert BedrockConverse.url(ep, @haiku) ==
               "https://bedrock-runtime.eu-west-1.amazonaws.com/model/eu.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse"

      assert {:ok, _} = Completion.chat_completion(ep, [%{role: "user", content: "hi"}])
      assert_received {:request, "/model/" <> _, _auth, _body}
    end

    test "a per-call model: goes in the URL" do
      stub(converse_answer([%{"text" => "OK."}]))
      ep = endpoint(@haiku)

      assert {:ok, _} =
               PhoenixKitAI.ask(ep.uuid, "hi", model: "global.anthropic.claude-sonnet-5")

      assert_received {:request, "/model/global.anthropic.claude-sonnet-5/converse", _, _}
    end

    test "a gpt-oss endpoint keeps the OpenAI-compatible chat completions" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:path, conn.request_path})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "hi"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      end)

      ep = endpoint("openai.gpt-oss-120b-1:0")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      assert_received {:path, "/openai/v1/chat/completions"}
    end

    test "system messages go to system, the roles alternate, tool rounds become toolUse and toolResult" do
      messages = [
        %{role: "system", content: "Be brief."},
        %{role: "user", content: "Find order A-1"},
        %{
          role: "assistant",
          content: "Looking.",
          tool_calls: [
            %{
              "id" => "tooluse_1",
              "type" => "function",
              "function" => %{"name" => "get_order", "arguments" => ~s({"number":"A-1"})}
            },
            %{
              "id" => "tooluse_2",
              "type" => "function",
              "function" => %{"name" => "get_client", "arguments" => "{}"}
            }
          ]
        },
        %{
          role: "tool",
          tool_call_id: "tooluse_1",
          name: "get_order",
          content: ~s({"status":"sent"})
        },
        %{role: "tool", tool_call_id: "tooluse_2", name: "get_client", content: "Ann"},
        %{role: "user", content: "And?"}
      ]

      assert {:ok, body} = BedrockConverse.request(@haiku, messages, [])

      assert body["system"] == [%{"text" => "Be brief."}]

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"text" => "Find order A-1"}]},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{"text" => "Looking."},
                   %{
                     "toolUse" => %{
                       "toolUseId" => "tooluse_1",
                       "name" => "get_order",
                       "input" => %{"number" => "A-1"}
                     }
                   },
                   %{
                     "toolUse" => %{
                       "toolUseId" => "tooluse_2",
                       "name" => "get_client",
                       "input" => %{}
                     }
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "toolResult" => %{
                       "toolUseId" => "tooluse_1",
                       "content" => [%{"text" => ~s({"status":"sent"})}]
                     }
                   },
                   %{
                     "toolResult" => %{
                       "toolUseId" => "tooluse_2",
                       "content" => [%{"text" => "Ann"}]
                     }
                   },
                   %{"text" => "And?"}
                 ]
               }
             ]
    end

    test "an assistant message that only calls tools carries no text block" do
      messages = [
        %{role: "user", content: "hi"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "f", "arguments" => "{}"}
            }
          ]
        }
      ]

      assert {:ok, %{"messages" => [_, %{"content" => [%{"toolUse" => _}]}]}} =
               BedrockConverse.request(@haiku, messages, [])
    end

    test "images in a data: URL go as bytes; links, audio and files are not supported" do
      data_url = "data:image/png;base64," <> Base.encode64(@png)

      content = [
        %{"type" => "text", "text" => "What is it?"},
        %{"type" => "image_url", "image_url" => %{"url" => data_url}}
      ]

      assert {:ok, %{"messages" => [%{"content" => blocks}]}} =
               BedrockConverse.request(@haiku, [%{role: "user", content: content}], [])

      assert blocks == [
               %{"text" => "What is it?"},
               %{"image" => %{"format" => "png", "source" => %{"bytes" => Base.encode64(@png)}}}
             ]

      for part <- [
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/a.png"}},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/bmp;base64,AAAA"}},
            %{"type" => "input_audio", "input_audio" => %{"data" => "AAAA", "format" => "wav"}},
            %{"type" => "file", "file" => %{"file_data" => "data:application/pdf;base64,AAAA"}}
          ] do
        assert {:error, :not_supported} =
                 BedrockConverse.request(@haiku, [%{role: "user", content: [part]}], []),
               inspect(part)
      end

      assert {:error, :invalid_image_input} =
               BedrockConverse.request(
                 @haiku,
                 [
                   %{
                     role: "user",
                     content: [
                       %{
                         "type" => "image_url",
                         "image_url" => %{"url" => "data:image/png;base64,***"}
                       }
                     ]
                   }
                 ],
                 []
               )
    end

    test "parts, tool calls and tools given with atom keys read the same" do
      data_url = "data:image/jpeg;base64," <> Base.encode64("jpeg-bytes")

      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "Look"},
            %{type: "image_url", image_url: %{url: data_url}}
          ]
        },
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{id: "t1", type: "function", function: %{name: "f", arguments: ~s({"a":1})}}
          ]
        }
      ]

      tools = [%{type: "function", function: %{name: "f", description: "F", parameters: %{}}}]

      assert {:ok, body} = BedrockConverse.request(@haiku, messages, tools: tools)

      assert [
               %{
                 "content" => [
                   %{"text" => "Look"},
                   %{"image" => %{"format" => "jpeg", "source" => %{"bytes" => _}}}
                 ]
               },
               %{
                 "content" => [
                   %{"toolUse" => %{"toolUseId" => "t1", "name" => "f", "input" => %{"a" => 1}}}
                 ]
               }
             ] = body["messages"]

      assert [%{"toolSpec" => %{"name" => "f", "description" => "F"}}] =
               body["toolConfig"]["tools"]
    end

    test "an unsupported part is refused before any request is sent" do
      stub(converse_answer([%{"text" => "OK."}]))
      ep = endpoint(@haiku)

      messages = [
        %{
          role: "user",
          content: [%{"type" => "image_url", "image_url" => %{"url" => "https://x.test/a.png"}}]
        }
      ]

      assert {:error, :not_supported} = PhoenixKitAI.complete(ep.uuid, messages)
      refute_received {:request, _, _, _}
    end

    test "tools and tool_choice become toolConfig" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "get_order",
            "description" => "An order by number",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"number" => %{"type" => "string"}}
            }
          }
        },
        %{"type" => "function", "function" => %{"name" => "ping", "description" => ""}}
      ]

      assert {:ok, %{"toolConfig" => config}} =
               BedrockConverse.request(@haiku, [%{role: "user", content: "hi"}],
                 tools: tools,
                 tool_choice: "required"
               )

      assert config == %{
               "tools" => [
                 %{
                   "toolSpec" => %{
                     "name" => "get_order",
                     "description" => "An order by number",
                     "inputSchema" => %{
                       "json" => %{
                         "type" => "object",
                         "properties" => %{"number" => %{"type" => "string"}}
                       }
                     }
                   }
                 },
                 %{
                   "toolSpec" => %{
                     "name" => "ping",
                     "inputSchema" => %{"json" => %{"type" => "object", "properties" => %{}}}
                   }
                 }
               ],
               "toolChoice" => %{"any" => %{}}
             }

      choice = fn choice ->
        {:ok, body} =
          BedrockConverse.request(@haiku, [%{role: "user", content: "hi"}],
            tools: tools,
            tool_choice: choice
          )

        body["toolConfig"]["toolChoice"]
      end

      assert choice.("auto") == %{"auto" => %{}}

      assert choice.(%{"type" => "function", "function" => %{"name" => "ping"}}) ==
               %{"tool" => %{"name" => "ping"}}

      assert choice.("none") == nil

      assert {:ok, body} = BedrockConverse.request(@haiku, [%{role: "user", content: "hi"}], [])
      refute Map.has_key?(body, "toolConfig")
    end

    test "sampling follows the Anthropic rules for a Claude model" do
      request = fn model, opts ->
        {:ok, body} = BedrockConverse.request(model, [%{role: "user", content: "hi"}], opts)
        body
      end

      all = [temperature: 0.3, top_p: 0.9, top_k: 40, max_tokens: 100, stop: "END"]

      # Claude Haiku 4.5 takes sampling: temperature wins over top_p.
      body = request.(@haiku, all)

      assert body["inferenceConfig"] == %{
               "maxTokens" => 100,
               "temperature" => 0.3,
               "stopSequences" => ["END"]
             }

      assert body["additionalModelRequestFields"] == %{"top_k" => 40}

      assert request.(@haiku, top_p: 0.9)["inferenceConfig"] == %{"topP" => 0.9}

      # From Claude Opus 4.7 on: no sampling at all.
      body = request.("eu.anthropic.claude-opus-4-7", all)
      assert body["inferenceConfig"] == %{"maxTokens" => 100, "stopSequences" => ["END"]}
      refute Map.has_key?(body, "additionalModelRequestFields")

      # Another model family: temperature and top_p as given, no top_k.
      body = request.("amazon.nova-pro-v1:0", all)
      assert body["inferenceConfig"]["temperature"] == 0.3
      assert body["inferenceConfig"]["topP"] == 0.9
      refute Map.has_key?(body, "additionalModelRequestFields")
    end

    test "fields Converse has no place for are not sent" do
      {:ok, body} =
        BedrockConverse.request(@haiku, [%{role: "user", content: "hi"}],
          seed: 1,
          frequency_penalty: 0.5,
          presence_penalty: 0.5,
          repetition_penalty: 1.1,
          response_format: %{"type" => "json_object"},
          parallel_tool_calls: false,
          reasoning_enabled: true,
          reasoning_effort: "high",
          stream: false
        )

      assert Map.keys(body) == ["messages"]
    end
  end

  describe "the answer" do
    test "text, tool calls and reasoning come back in the chat-completions shape" do
      stub(
        converse_answer(
          [
            %{
              "reasoningContent" => %{
                "reasoningText" => %{"text" => "Check it.", "signature" => "sig"}
              }
            },
            %{"text" => "Looking it up."},
            %{
              "toolUse" => %{
                "toolUseId" => "tooluse_abc",
                "name" => "get_order",
                "input" => %{"number" => "A-1"}
              }
            }
          ],
          "tool_use"
        )
      )

      ep = endpoint(@haiku)

      assert {:ok, response} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "Order A-1?"}],
                 tools: [%{"type" => "function", "function" => %{"name" => "get_order"}}]
               )

      assert {:ok, "Looking it up."} = PhoenixKitAI.extract_content(response)

      assert [
               %{
                 "id" => "tooluse_abc",
                 "type" => "function",
                 "function" => %{"name" => "get_order", "arguments" => arguments}
               }
             ] = PhoenixKitAI.extract_tool_calls(response)

      assert Jason.decode!(arguments) == %{"number" => "A-1"}
      assert Completion.extract_reasoning(response) == "Check it."
      assert [%{"finish_reason" => "tool_calls"}] = response["choices"]

      assert Completion.extract_usage(response) == %{
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15,
               cost: nil
             }
    end

    test "a tool-only answer has nil content" do
      response =
        BedrockConverse.response(
          converse_answer(
            [%{"toolUse" => %{"toolUseId" => "t", "name" => "f", "input" => %{}}}],
            "tool_use"
          ),
          @haiku
        )

      assert {:ok, nil} = Completion.extract_content(response)
      assert [%{"function" => %{"arguments" => "{}"}}] = Completion.extract_tool_calls(response)
    end

    test "stop reasons map to finish reasons truncated?/1 and filtered?/1 read" do
      read = fn reason ->
        BedrockConverse.response(converse_answer([%{"text" => "x"}], reason), @haiku)
      end

      assert [%{"finish_reason" => "stop"}] = read.("end_turn")["choices"]
      assert [%{"finish_reason" => "stop"}] = read.("stop_sequence")["choices"]
      assert Completion.truncated?(read.("max_tokens"))
      assert Completion.truncated?(read.("model_context_window_exceeded"))
      assert Completion.filtered?(read.("content_filtered"))
      assert Completion.filtered?(read.("guardrail_intervened"))
      refute Completion.truncated?(read.("end_turn"))
    end

    test "the call is logged with its tokens" do
      stub(converse_answer([%{"text" => "OK."}]))
      ep = endpoint(@haiku)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert {[%{input_tokens: 10, output_tokens: 5, model: @haiku, status: "success"}], 1} =
               PhoenixKitAI.list_requests(endpoint_uuid: ep.uuid)
    end

    test "a 200 that is not a Converse answer is an invalid response" do
      stub(%{"unexpected" => true})
      ep = endpoint(@haiku)

      assert {:error, :invalid_response_format} = PhoenixKitAI.ask(ep.uuid, "hi")
    end
  end

  describe "errors" do
    test "a 403 about the key is :invalid_api_key, about access {:api_error, 403}" do
      stub(403, %{"Message" => "Invalid API Key format: Delimiter ':' not found"})
      ep = endpoint(@haiku)
      assert {:error, :invalid_api_key} = PhoenixKitAI.ask(ep.uuid, "hi")

      stub(403, %{"Message" => "Authentication failed: Please make sure your API Key is valid."})
      assert {:error, :invalid_api_key} = PhoenixKitAI.ask(ep.uuid, "hi")

      stub(403, %{"message" => "You don't have access to the model with the specified model ID."})
      assert {:error, {:api_error, 403}} = PhoenixKitAI.ask(ep.uuid, "hi")
    end

    test "an unknown or retired model is :model_not_found" do
      ep = endpoint(@haiku)

      stub(404, %{
        "message" =>
          "Access denied. This Model is marked by provider as Legacy and you have not been actively using the model in the last 30 days."
      })

      assert {:error, :model_not_found} = PhoenixKitAI.ask(ep.uuid, "hi")

      stub(400, %{"message" => "The provided model identifier is invalid."})
      assert {:error, :model_not_found} = PhoenixKitAI.ask(ep.uuid, "hi")
    end

    test "throttling is :rate_limited, a validation error {:api_error, 400}" do
      ep = endpoint(@haiku)

      stub(429, %{"message" => "Too many requests, please wait before trying again."})
      assert {:error, :rate_limited} = PhoenixKitAI.ask(ep.uuid, "hi")

      stub(400, %{"message" => "messages.0.content: Field required"})
      assert {:error, {:api_error, 400}} = PhoenixKitAI.ask(ep.uuid, "hi")
    end

    test "the provider's words reach the request row, the key never does" do
      stub(403, %{"Message" => "Invalid API Key format: Delimiter ':' not found"})
      ep = endpoint(@haiku)

      assert {:error, :invalid_api_key} = PhoenixKitAI.ask(ep.uuid, "hi")

      assert {[%{status: "error"} = row], 1} = PhoenixKitAI.list_requests(endpoint_uuid: ep.uuid)
      refute inspect(row) =~ "ABSK-test-key"
    end
  end
end
