defmodule PhoenixKitAI.ProviderErrorTest do
  @moduledoc """
  A provider's error body, not only its HTTP status: money told apart from
  request rate, and the provider's own (short) words kept on the request row
  next to the module's class of error. Bodies are the shapes each provider
  documents (links in `PhoenixKitAI.ProviderError`); every call is a
  `Req.Test` stub.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Completion

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp stub(status, body, headers \\ []) do
    Req.Test.stub(__MODULE__, fn conn ->
      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, encode(body))
    end)
  end

  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body)

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "glm-4.5",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp row_for(ep) do
    PhoenixKitAI.list_requests()
    |> elem(0)
    |> Enum.find(&(&1.endpoint_uuid == ep.uuid))
  end

  defp class(status, body), do: Completion.handle_error_status(status, Jason.encode!(body))

  defp zai(code, message), do: %{"error" => %{"code" => code, "message" => message}}

  defp openai(type, code, message \\ "x"),
    do: %{"error" => %{"message" => message, "type" => type, "param" => nil, "code" => code}}

  defp anthropic(type, message, details \\ nil) do
    error = %{"type" => type, "message" => message}
    error = if details, do: Map.put(error, "details", details), else: error
    %{"type" => "error", "error" => error, "request_id" => "req_011CSHoEeqs5C35K2UUqR7Fy"}
  end

  defp openrouter(code, message, metadata),
    do: %{"error" => %{"code" => code, "message" => message, "metadata" => metadata}}

  describe "Z.ai business codes" do
    test "1113 on a 429 is money, not rate" do
      body = zai("1113", "Insufficient balance or no resource package. Please recharge.")
      assert class(429, body) == {:error, :insufficient_credits}
    end

    test "the other documented package and balance codes are money" do
      for code <- ~w(1309 1314 1316 1317) do
        assert class(429, zai(code, "package")) == {:error, :insufficient_credits}, code
      end
    end

    test "1302 (rate limit) and 1305 (overloaded) stay rate limited" do
      assert class(429, zai("1302", "Rate limit reached for requests")) == {:error, :rate_limited}

      assert class(429, zai("1305", "The service may be temporarily overloaded")) ==
               {:error, :rate_limited}
    end
  end

  describe "OpenAI" do
    test "a 429 billing code is money" do
      for code <-
            ~w(credit_balance_exhausted organization_spend_limit_exceeded project_spend_limit_exceeded organization_usage_limit_exceeded) do
        assert class(429, openai("insufficient_quota", code)) == {:error, :insufficient_credits},
               code
      end
    end

    test "insufficient_quota as the type or as the code is money" do
      assert class(429, openai("insufficient_quota", nil)) == {:error, :insufficient_credits}

      assert class(429, openai("requests", "insufficient_quota")) ==
               {:error, :insufficient_credits}
    end

    test "rate_limit_exceeded and slow_down stay rate limited" do
      assert class(429, openai("requests", "rate_limit_exceeded")) == {:error, :rate_limited}
      assert class(429, openai("rate_limit_error", "slow_down")) == {:error, :rate_limited}
    end
  end

  describe "Anthropic" do
    test "a 429 rate_limit_error is rate limited" do
      assert class(429, anthropic("rate_limit_error", "Number of requests has exceeded")) ==
               {:error, :rate_limited}
    end

    test "the spend-cap 429 (details.error_code) is money" do
      body =
        anthropic(
          "rate_limit_error",
          "You have reached your API usage limits: your organization has crossed its monthly API usage threshold.",
          %{"error_code" => "enforced_spend_limit_reached"}
        )

      assert class(429, body) == {:error, :insufficient_credits}
    end

    test "a 400 for a spend limit you set is money; any other 400 is not" do
      for message <- [
            "You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC.",
            "You have reached your specified workspace API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."
          ] do
        assert class(400, anthropic("invalid_request_error", message)) ==
                 {:error, :insufficient_credits}
      end

      assert class(400, anthropic("invalid_request_error", "max_tokens: field required")) ==
               {:error, {:api_error, 400}}
    end

    test "402 billing_error is money" do
      assert class(402, anthropic("billing_error", "Check your payment details")) ==
               {:error, :insufficient_credits}
    end
  end

  describe "OpenRouter" do
    test "a 402 is money" do
      body = openrouter(402, "Insufficient credits", %{"limit_source" => "openrouter_credits"})
      assert class(402, body) == {:error, :insufficient_credits}
    end

    test "a 402 for the in-flight spending budget is transient: rate limited" do
      body =
        openrouter(402, "This request would exceed your available credits", %{
          "reason" => "in_flight_budget_exhausted",
          "limit_source" => "openrouter_in_flight_budget"
        })

      assert class(402, body) == {:error, :rate_limited}
    end

    test "a 403 for a spent budget is money; another 403 is not" do
      for source <-
            ~w(openrouter_guardrail_budget openrouter_workspace_budget openrouter_key_limit) do
        body = openrouter(403, "Budget limit exceeded", %{"limit_source" => source})
        assert class(403, body) == {:error, :insufficient_credits}, source
      end

      assert class(403, openrouter(403, "Flagged", %{"reasons" => ["x"]})) ==
               {:error, {:api_error, 403}}
    end

    test "a provider error in a 200 body is classified by its body too" do
      body =
        openrouter(402, "in flight", %{"limit_source" => "openrouter_in_flight_budget"})

      stub(200, body)

      assert {:error, :rate_limited} =
               Completion.chat_completion(endpoint_fixture(), [%{role: "user", content: "hi"}])
    end
  end

  describe "DeepSeek" do
    test "402 Insufficient Balance is money" do
      body = %{"error" => %{"message" => "Insufficient Balance", "type" => "unknown_error"}}
      assert class(402, body) == {:error, :insufficient_credits}
    end
  end

  describe "a 429 with nothing recognisable" do
    test "stays rate limited" do
      assert Completion.handle_error_status(429, "") == {:error, :rate_limited}
      assert Completion.handle_error_status(429, "<html>busy</html>") == {:error, :rate_limited}
      assert class(429, %{"error" => %{"message" => "Too many"}}) == {:error, :rate_limited}
    end
  end

  describe "the request row" do
    test "keeps the provider's words next to the class" do
      stub(429, zai("1113", "Insufficient balance or no resource package. Please recharge."))
      ep = endpoint_fixture()

      assert {:error, :insufficient_credits} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)

      assert row.error_message ==
               "Insufficient credits — Insufficient balance or no resource package. Please recharge. (1113)"

      assert row.metadata["error_reason"] == ":insufficient_credits"

      assert row.metadata["provider_error"] == %{
               "status" => 429,
               "code" => "1113",
               "message" => "Insufficient balance or no resource package. Please recharge."
             }
    end

    test "a money error carries no retry_after, even with the header" do
      stub(429, zai("1113", "Insufficient balance"), [{"retry-after", "30"}])
      ep = endpoint_fixture()

      assert {:error, :insufficient_credits} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      refute Map.has_key?(row_for(ep).metadata["provider_error"], "retry_after_s")
    end

    test "a rate limit carries Retry-After in seconds" do
      stub(429, zai("1302", "Rate limit reached for requests"), [{"retry-after", "30"}])
      ep = endpoint_fixture()

      assert {:error, :rate_limited} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)
      assert row.metadata["provider_error"]["retry_after_s"] == 30
      assert row.error_message == "Rate limited — Rate limit reached for requests (1302)"
    end

    test "a Retry-After HTTP date becomes seconds from now" do
      date =
        DateTime.utc_now()
        |> DateTime.add(120, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      stub(429, %{}, [{"retry-after", date}])
      ep = endpoint_fixture()

      assert {:error, :rate_limited} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      assert row_for(ep).metadata["provider_error"]["retry_after_s"] in 110..121
    end

    test "an unreadable Retry-After is left out" do
      stub(429, %{}, [{"retry-after", "soon"}])
      ep = endpoint_fixture()

      assert {:error, :rate_limited} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)
      refute Map.has_key?(row.metadata, "provider_error")
      assert row.error_message == "Rate limited"
    end

    test "the provider's text is trimmed and never the whole body" do
      long = String.duplicate("word ", 400)

      stub(400, %{
        "error" => %{"message" => long, "type" => "invalid_request_error"},
        "debug" => "not-for-the-row"
      })

      ep = endpoint_fixture()

      assert {:error, {:api_error, 400}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)
      message = row.metadata["provider_error"]["message"]
      assert String.length(message) <= 300
      assert String.starts_with?(message, "word word")
      refute row.error_message =~ "not-for-the-row"
      refute inspect(row.metadata) =~ "not-for-the-row"
    end

    test "a key quoted in the provider's text is not kept" do
      stub(401, %{
        "error" => %{
          "message" => "Incorrect API key provided: sk-proj-AbCdEf0123456789xyz. Check it.",
          "type" => "invalid_request_error",
          "code" => "invalid_api_key"
        }
      })

      ep = endpoint_fixture()

      assert {:error, :invalid_api_key} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)
      refute inspect(row.metadata) =~ "AbCdEf0123456789"
      refute row.error_message =~ "AbCdEf0123456789"
      refute inspect(row.metadata) =~ "sk-test-key"
      assert row.metadata["provider_error"]["message"] =~ "Incorrect API key provided"
    end

    test "nothing from an earlier call reaches a later row" do
      stub(429, zai("1113", "Insufficient balance"))
      first = endpoint_fixture()

      # A direct call writes no row, so nothing takes its note.
      assert {:error, :insufficient_credits} =
               Completion.chat_completion(first, [%{role: "user", content: "hi"}])

      stub(429, "")
      second = endpoint_fixture()

      assert {:error, :rate_limited} =
               PhoenixKitAI.complete(second.uuid, [%{role: "user", content: "hi"}])

      row = row_for(second)
      refute Map.has_key?(row.metadata, "provider_error")
      assert row.error_message == "Rate limited"
    end

    test "an image call's row keeps the provider's words too" do
      stub(429, openai("insufficient_quota", "credit_balance_exhausted", "No credits left"))
      ep = endpoint_fixture(%{provider: "openai", model: "gpt-image-1"})

      assert {:error, :insufficient_credits} = PhoenixKitAI.generate_image(ep.uuid, "a cat")

      row = row_for(ep)

      assert row.error_message ==
               "Insufficient credits — No credits left (credit_balance_exhausted)"

      assert row.metadata["provider_error"]["code"] == "credit_balance_exhausted"
    end

    test "an embedding call's row keeps the provider's words too" do
      stub(402, %{"error" => %{"message" => "Insufficient Balance", "type" => "unknown_error"}})
      ep = endpoint_fixture(%{model: "openai/text-embedding-3-small"})

      assert {:error, :insufficient_credits} = PhoenixKitAI.embed(ep.uuid, "hello")

      assert row_for(ep).error_message ==
               "Insufficient credits — Insufficient Balance (unknown_error)"
    end
  end

  describe "the answered model" do
    defp answer(model) do
      %{
        "id" => "gen-1",
        "model" => model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      }
    end

    test "is kept when it differs from the model asked for" do
      stub(200, answer("glm-5.3-flash"))
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])

      row = row_for(ep)
      assert row.model == "glm-4.5"
      assert row.metadata["answered_model"] == "glm-5.3-flash"
    end

    test "is left out when it is the model asked for" do
      stub(200, answer("glm-4.5"))
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "hi"}])
      refute Map.has_key?(row_for(ep).metadata, "answered_model")
    end
  end
end
