defmodule PhoenixKitAI.RequestRulesTest do
  @moduledoc """
  What the request body carries under the guard's rules: Anthropic's
  parameter rules (sampling only when the caller sets it, never
  `temperature` with `top_p`, no penalties or `seed`, `reasoning` →
  `thinking`), OpenRouter's `require_parameters` with the unsupported
  parameters left out, its "no provider for these parameters" answer, and
  a vision call's own reasoning options. Bodies are captured from a
  `Req.Test` stub.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Capabilities, Completion, Errors, Request}
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>
  @anthropic "https://api.anthropic.com/v1"

  @openrouter_catalogue [
    %{
      "id" => "vendor/vision",
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => [
        "tools",
        "response_format",
        "structured_outputs",
        "max_tokens",
        "temperature"
      ]
    }
  ]

  @anthropic_catalogue [
    %{
      "id" => "claude-takes-disabled",
      "type" => "model",
      "capabilities" => %{
        "image_input" => %{"supported" => true},
        "thinking" => %{
          "supported" => true,
          "types" => %{
            "adaptive" => %{"supported" => true},
            "disabled" => %{"supported" => true}
          }
        }
      }
    },
    %{
      "id" => "claude-always-thinks",
      "type" => "model",
      "capabilities" => %{
        "image_input" => %{"supported" => true},
        "thinking" => %{
          "supported" => true,
          "types" => %{
            "enabled" => %{"supported" => false},
            "adaptive" => %{"supported" => true},
            "disabled" => %{"supported" => false}
          }
        }
      }
    },
    # An older model: a token budget, no adaptive thinking.
    %{
      "id" => "claude-budget-only",
      "type" => "model",
      "capabilities" => %{
        "image_input" => %{"supported" => true},
        "thinking" => %{
          "supported" => true,
          "types" => %{
            "enabled" => %{"supported" => true},
            "adaptive" => %{"supported" => false}
          }
        }
      }
    }
  ]

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      ModuleRegistry.unregister(FakeAITasks)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  test "a parameter-routing refusal does not log the provider's echoed content" do
    secret = "private-prompt-and-key"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:no_provider_for_params, []}} =
                 Completion.handle_error_status(
                   404,
                   Jason.encode!(%{
                     "error" => %{"message" => "No endpoints for requested parameters: #{secret}"}
                   })
                 )
      end)

    assert log =~ "requested parameters"
    refute log =~ secret
  end

  defp answer(content \\ "ok") do
    %{
      "model" => "m",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp stub(post_status \\ 200, post_answer \\ answer()) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.host} do
        {"GET", "api.anthropic.com"} ->
          Req.Test.json(conn, %{"data" => @anthropic_catalogue, "has_more" => false})

        {"GET", _} ->
          Req.Test.json(conn, %{"data" => @openrouter_catalogue})

        {"POST", _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:body, Jason.decode!(raw)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(post_status, Jason.encode!(post_answer))
      end
    end)
  end

  defp start_catalogue do
    pid =
      start_supervised!(
        {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    assert :ok = Capabilities.refresh()
  end

  defp endpoint(attrs) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Rules EP #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "vendor/vision",
            api_key: "sk-test-key"
          },
          attrs
        )
      )

    endpoint
  end

  defp anthropic_endpoint(attrs) do
    endpoint(
      Map.merge(
        %{provider: "anthropic", base_url: @anthropic, model: "claude-takes-disabled"},
        attrs
      )
    )
  end

  defp sent_body do
    assert_received {:body, body}
    body
  end

  describe "Anthropic" do
    test "the endpoint's sampling values, penalties and seed are not sent" do
      stub()

      ep =
        anthropic_endpoint(%{
          top_p: 0.9,
          top_k: 40,
          frequency_penalty: 0.5,
          presence_penalty: 0.5,
          repetition_penalty: 1.1,
          seed: 7,
          max_tokens: 500
        })

      # The schema default the endpoint carries is not sent.
      assert ep.temperature == 0.7

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      body = sent_body()

      for key <-
            ~w(temperature top_p top_k frequency_penalty presence_penalty repetition_penalty seed),
          do: refute(Map.has_key?(body, key), key)

      assert body["max_tokens"] == 500
    end

    test "a caller's own temperature or top_p is sent, never both; penalties never" do
      stub()
      # A model before Claude Opus 4.7: the later ones take neither
      # (`AnthropicRulesTest`).
      ep = anthropic_endpoint(%{model: "claude-sonnet-4-6"})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", temperature: 1.0)
      assert %{"temperature" => 1.0} = sent_body()

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", top_p: 0.99)
      body = sent_body()
      assert body["top_p"] == 0.99
      refute Map.has_key?(body, "temperature")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", temperature: 1.0, top_p: 0.99, seed: 3)
      body = sent_body()
      assert body["temperature"] == 1.0
      refute Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "seed")
    end

    test "reasoning becomes thinking, only in a form the model's catalogue says it takes" do
      stub()
      adaptive = anthropic_endpoint(%{model: "claude-always-thinks", reasoning_enabled: true})

      adaptive_budget =
        anthropic_endpoint(%{model: "claude-always-thinks", reasoning_max_tokens: 2048})

      budget = anthropic_endpoint(%{model: "claude-budget-only", reasoning_max_tokens: 2048})

      budget_no_value =
        anthropic_endpoint(%{model: "claude-budget-only", reasoning_enabled: true})

      # Before the catalogue is read nothing is known: no thinking field, and
      # the reasoning object is not sent either (what the layer got before).
      assert {:ok, _} = PhoenixKitAI.ask(adaptive.uuid, "hi")
      body = sent_body()
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "reasoning")

      start_catalogue()

      assert %Capabilities{thinking_enabled: :no, thinking_adaptive: :yes} =
               Capabilities.for_endpoint(adaptive)

      assert %Capabilities{thinking_enabled: :yes, thinking_adaptive: :no} =
               Capabilities.for_endpoint(budget)

      assert {:ok, _} = PhoenixKitAI.ask(adaptive.uuid, "hi")
      assert %{"thinking" => %{"type" => "adaptive"}} = sent_body()

      assert {:ok, _} = PhoenixKitAI.ask(adaptive.uuid, "hi", reasoning_effort: "low")
      assert %{"thinking" => %{"type" => "adaptive"}} = sent_body()

      # A token budget is a 400 on a model without `enabled`: adaptive instead.
      assert {:ok, _} = PhoenixKitAI.ask(adaptive_budget.uuid, "hi")
      assert %{"thinking" => %{"type" => "adaptive"}} = sent_body()

      assert {:ok, _} = PhoenixKitAI.ask(budget.uuid, "hi")
      assert %{"thinking" => %{"type" => "enabled", "budget_tokens" => 2048}} = sent_body()

      # Neither a budget nor adaptive thinking: nothing is sent.
      assert {:ok, _} = PhoenixKitAI.ask(budget_no_value.uuid, "hi")
      refute Map.has_key?(sent_body(), "thinking")
    end

    test "a budget not below max_tokens sends no thinking and notes it on the row" do
      stub()

      ep =
        anthropic_endpoint(%{
          model: "claude-budget-only",
          reasoning_max_tokens: 2048,
          max_tokens: 1000
        })

      start_catalogue()

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      body = sent_body()
      refute Map.has_key?(body, "thinking")
      assert body["max_tokens"] == 1000

      # Vision takes the call's own options: the same rule.
      assert {:ok, _} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 reasoning_max_tokens: 4096,
                 max_tokens: 4096
               )

      refute Map.has_key?(sent_body(), "thinking")

      # A budget below max_tokens is sent.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", max_tokens: 4000)
      assert %{"thinking" => %{"type" => "enabled", "budget_tokens" => 2048}} = sent_body()

      rows =
        TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.uuid))

      assert [
               %{metadata: %{"guard_warnings" => ["thinking_budget_not_below_max_tokens"]}},
               %{metadata: %{"guard_warnings" => ["thinking_budget_not_below_max_tokens"]}},
               %{metadata: third}
             ] = rows

      refute Map.has_key?(third, "guard_warnings")
    end

    test "thinking off is sent only to a model whose catalogue says it takes it" do
      stub()
      takes = anthropic_endpoint(%{reasoning_enabled: false})

      always =
        anthropic_endpoint(%{reasoning_enabled: false, model: "claude-always-thinks"})

      # Unknown before the catalogue is read: nothing is sent.
      assert {:ok, _} = PhoenixKitAI.ask(takes.uuid, "hi")
      refute Map.has_key?(sent_body(), "thinking")

      start_catalogue()

      assert %Capabilities{thinking_disabled: :yes} = Capabilities.for_endpoint(takes)
      assert %Capabilities{thinking_disabled: :no} = Capabilities.for_endpoint(always)

      assert {:ok, _} = PhoenixKitAI.ask(takes.uuid, "hi")
      assert %{"thinking" => %{"type" => "disabled"}} = sent_body()

      assert {:ok, _} = PhoenixKitAI.ask(always.uuid, "hi")
      body = sent_body()
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "reasoning")
    end

    test "other providers keep the endpoint's values and the reasoning object" do
      stub()
      ep = endpoint(%{model: "vendor/other", top_p: 0.9, reasoning_enabled: true})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      body = sent_body()
      assert body["temperature"] == 0.7
      assert body["top_p"] == 0.9
      assert body["reasoning"] == %{"enabled" => true}
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "provider")
    end
  end

  describe "OpenRouter require_parameters" do
    test "a hard need asks for it and leaves out what the model's catalogue lacks" do
      stub()

      ep =
        endpoint(%{top_k: 40, frequency_penalty: 0.5, max_tokens: 300, reasoning_effort: "low"})

      start_catalogue()

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.photo")
      body = sent_body()

      assert body["provider"] == %{"require_parameters" => true}
      assert body["temperature"] == 0.7
      assert body["max_tokens"] == 300

      for key <- ~w(top_k frequency_penalty reasoning),
          do: refute(Map.has_key?(body, key), key)

      assert [%{metadata: %{"stripped_params" => ["frequency_penalty", "reasoning", "top_k"]}}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))
    end

    test "without the model's parameter list (catalogue not read) nothing changes" do
      stub()
      ep = endpoint(%{top_k: 40})
      tools = [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}]

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", tools: tools)
      body = sent_body()
      refute Map.has_key?(body, "provider")
      assert body["top_k"] == 40

      assert [%{metadata: metadata}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))

      refute Map.has_key?(metadata, "stripped_params")
    end

    test "tools: asks for it; a call without a hard need does not" do
      stub()
      ep = endpoint(%{top_k: 40})
      start_catalogue()
      tools = [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}]

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", tools: tools)
      body = sent_body()
      assert body["provider"] == %{"require_parameters" => true}
      assert body["tools"] == tools
      refute Map.has_key?(body, "top_k")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.json")
      body = sent_body()
      refute Map.has_key?(body, "provider")
      assert body["top_k"] == 40
    end

    test "a vision call with a json_schema task asks for it too" do
      stub(200, answer(~s({"items": []})))
      ep = endpoint(%{})
      start_catalogue()

      assert {:ok, %{json: %{"items" => []}}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 task: "test.photo",
                 json: true,
                 seed: 5
               )

      body = sent_body()
      assert body["provider"] == %{"require_parameters" => true}
      refute Map.has_key?(body, "seed")
    end

    test "no provider for the parameters is its own error, not model_unfit" do
      stub(404, %{
        "error" => %{
          "code" => 404,
          "message" => "No endpoints found that can handle the requested parameters."
        }
      })

      ep = endpoint(%{max_tokens: 100})
      start_catalogue()
      tools = [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}]

      assert {:error, {:no_provider_for_params, params}} =
               PhoenixKitAI.ask(ep.uuid, "hi", tools: tools)

      # Only what an endpoint's settings put there: the call's own tools and
      # format are not something to remove from the endpoint.
      assert "max_tokens" in params

      for name <- ~w(tools tool_choice parallel_tool_calls response_format messages),
          do: refute(name in params, name)

      assert [%{status: "error", error_message: message, metadata: metadata}] =
               TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid))

      assert message == Errors.message({:no_provider_for_params, params})
      refute metadata["refused"]
    end

    test "handle_error_status/2 maps only the parameters answer" do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" => "No endpoints found that can handle the requested parameters."
          }
        })

      assert {:error, {:no_provider_for_params, []}} = Completion.handle_error_status(404, body)

      other = Jason.encode!(%{"error" => %{"message" => "Model not found"}})
      assert {:error, {:api_error, 404}} = Completion.handle_error_status(404, other)
    end
  end

  describe "reasoning in vision" do
    test "describe_image sends the call's own reasoning options, never the endpoint's" do
      stub(200, answer("A cat."))
      ep = endpoint(%{model: "vendor/vision-reasoning", reasoning_enabled: true})

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)
      refute Map.has_key?(sent_body(), "reasoning")

      assert {:ok, _} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 reasoning_enabled: false,
                 reasoning_max_tokens: 0
               )

      assert %{"reasoning" => %{"enabled" => false, "max_tokens" => 0}} = sent_body()
    end
  end

  describe "error texts" do
    test "the new reasons have their own texts" do
      assert Errors.message({:model_unfit, [:vision, :json_schema]}) =~ "images, JSON schema"
      assert Errors.message({:model_unverified, [:tools]}) =~ "tools"

      assert Errors.message({:no_provider_for_params, ["top_k", "seed"]}) =~ "top_k, seed"
      refute Errors.message({:no_provider_for_params, []}) =~ "()"
    end
  end
end
