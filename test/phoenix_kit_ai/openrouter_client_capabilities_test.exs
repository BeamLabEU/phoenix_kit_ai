defmodule PhoenixKitAI.OpenRouterClientCapabilitiesTest do
  @moduledoc """
  The model list as the endpoint form gets it: the chat filter by output
  modality (so models that take images stay in the chat list), the
  capabilities each model carries, and Anthropic's native `/v1/models`
  (paged, with its own headers and lifecycle filter).
  """

  use ExUnit.Case, async: false

  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.OpenRouterClient

  setup do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    {:ok, stub: stub}
  end

  @openrouter_models [
    %{
      "id" => "openai/gpt-4o-mini",
      "architecture" => %{"modality" => "text->text"},
      "supported_parameters" => ["tools"]
    },
    %{
      "id" => "~google/gemini-flash-latest",
      "architecture" => %{
        "modality" => "text+image+file+audio+video->text",
        "input_modalities" => ["text", "image", "video", "file", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["tools", "response_format", "structured_outputs"]
    },
    %{
      "id" => "anthropic/claude-sonnet",
      "architecture" => %{"modality" => "text+image->text"},
      "supported_parameters" => ["tools"]
    },
    %{
      "id" => "google/gemini-image",
      "architecture" => %{
        "modality" => "text+image->text+image",
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["image", "text"]
      }
    },
    %{"id" => "openai/dall-e", "architecture" => %{"modality" => "text->image"}}
  ]

  describe "the chat list" do
    test "keeps every model whose only output is text, image input included", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => @openrouter_models}))

      {:ok, models} = OpenRouterClient.fetch_models("sk-or-v1-test", model_type: :text)

      assert Enum.map(models, & &1.id) == [
               "openai/gpt-4o-mini",
               "~google/gemini-flash-latest",
               "anthropic/claude-sonnet"
             ]
    end

    test "each OpenRouter model carries its capabilities", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => @openrouter_models}))

      {:ok, models} = OpenRouterClient.fetch_models("sk-or-v1-test", model_type: :all)
      by_id = Map.new(models, &{&1.id, &1})

      assert %AIModel{capabilities: %Capabilities{vision: :yes, json_schema: :yes}} =
               by_id["~google/gemini-flash-latest"]

      assert %AIModel{capabilities: %Capabilities{vision: :no, tools: :yes}} =
               by_id["openai/gpt-4o-mini"]
    end

    test "a provider without a catalogue gets unknown capabilities", %{stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => [%{"id" => "grok-4"}]}))

      {:ok, [model]} =
        OpenRouterClient.fetch_models("xai-key",
          base_url: "https://api.x.ai/v1",
          fallback_provider: "xai",
          model_type: :text
        )

      assert %AIModel{
               capabilities: %Capabilities{
                 vision: :unknown,
                 tools: :unknown,
                 json_schema: :unknown
               }
             } = model
    end
  end

  describe "Anthropic's /v1/models" do
    defp claude(id, overrides \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "type" => "model",
          "display_name" => "Display #{id}",
          "max_input_tokens" => 200_000,
          "max_tokens" => 64_000,
          "lifecycle" => "active",
          "capabilities" => %{"image_input" => %{"supported" => true}}
        },
        overrides
      )
    end

    test "is read page by page with the version header and every lifecycle", %{stub: stub} do
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:page, conn.request_path, conn.query_params, conn.req_headers})

        if conn.query_params["after_id"] == "claude-b" do
          Req.Test.json(conn, %{
            "data" => [claude("claude-c", %{"lifecycle" => "deprecated"})],
            "has_more" => false,
            "last_id" => "claude-c"
          })
        else
          Req.Test.json(conn, %{
            "data" => [claude("claude-a"), claude("claude-b", %{"capabilities" => nil})],
            "has_more" => true,
            "last_id" => "claude-b"
          })
        end
      end)

      {:ok, models} =
        OpenRouterClient.fetch_models("sk-ant-test",
          base_url: "https://api.anthropic.com/v1",
          fallback_provider: "anthropic",
          model_type: :text
        )

      assert_received {:page, "/v1/models", first, headers}
      assert first["limit"] == "1000"
      assert first["lifecycle"] == "active,deprecated,retired"
      refute Map.has_key?(first, "after_id")
      assert {"authorization", "Bearer sk-ant-test"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers

      assert_received {:page, "/v1/models", %{"after_id" => "claude-b"}, _}

      assert [
               %AIModel{
                 id: "claude-a",
                 name: "Display claude-a",
                 context_length: 200_000,
                 max_completion_tokens: 64_000,
                 capabilities: %Capabilities{vision: :yes, json_schema: :no, lifecycle: :active}
               },
               %AIModel{id: "claude-b", capabilities: %Capabilities{vision: :unknown}},
               %AIModel{id: "claude-c", capabilities: %Capabilities{lifecycle: :deprecated}}
             ] = models
    end

    test "a server that rejects the lifecycle filter is asked again without it", %{stub: stub} do
      test_pid = self()

      Req.Test.stub(stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:page, conn.query_params})

        if Map.has_key?(conn.query_params, "lifecycle") do
          Plug.Conn.send_resp(conn, 400, ~s({"type":"error"}))
        else
          Req.Test.json(conn, %{"data" => [claude("claude-a")], "has_more" => false})
        end
      end)

      assert {:ok, [%AIModel{id: "claude-a"}]} =
               OpenRouterClient.fetch_models("sk-ant-test",
                 base_url: "https://api.anthropic.com/v1",
                 fallback_provider: "anthropic"
               )

      assert_received {:page, %{"lifecycle" => _}}
      assert_received {:page, without}
      refute Map.has_key?(without, "lifecycle")
    end

    test "has_more without a last_id is a truncated list, not the last page", %{stub: stub} do
      Req.Test.stub(
        stub,
        &Req.Test.json(&1, %{"data" => [claude("claude-a")], "has_more" => true})
      )

      assert {:error, :invalid_response_format} =
               OpenRouterClient.fetch_models("sk-ant-test",
                 base_url: "https://api.anthropic.com/v1",
                 fallback_provider: "anthropic"
               )
    end

    test "a failed page fails the fetch", %{stub: stub} do
      Req.Test.stub(stub, &Plug.Conn.send_resp(&1, 401, ""))

      assert {:error, :invalid_api_key} =
               OpenRouterClient.fetch_models("bad",
                 base_url: "https://api.anthropic.com/v1",
                 fallback_provider: "anthropic"
               )
    end
  end
end
