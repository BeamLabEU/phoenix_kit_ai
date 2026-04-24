defmodule PhoenixKitAI.CompletionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Completion

  describe "handle_error_status/2" do
    test "401 returns :invalid_api_key" do
      assert Completion.handle_error_status(401, "") == {:error, :invalid_api_key}
    end

    test "402 returns :insufficient_credits" do
      assert Completion.handle_error_status(402, "") == {:error, :insufficient_credits}
    end

    test "429 returns :rate_limited" do
      assert Completion.handle_error_status(429, "") == {:error, :rate_limited}
    end

    test "generic non-2xx returns {:api_error, status} and logs the parsed message" do
      body = ~s({"error":{"message":"Upstream timeout"}})

      log =
        capture_log(fn ->
          assert Completion.handle_error_status(503, body) == {:error, {:api_error, 503}}
        end)

      assert log =~ "OpenRouter completion failed: 503"
      assert log =~ "Upstream timeout"
      # Raw body should NOT be in the log when we have a parsed message
      refute log =~ "error\":{\"message"
    end

    test "generic non-2xx with opaque body logs 'no parsable error body'" do
      log =
        capture_log(fn ->
          assert Completion.handle_error_status(500, "<!DOCTYPE html>") ==
                   {:error, {:api_error, 500}}
        end)

      assert log =~ "OpenRouter completion failed: 500 (no parsable error body)"
      # Raw HTML body should NOT be logged
      refute log =~ "DOCTYPE"
    end

    test "400 with string error body returns {:api_error, 400}" do
      body = ~s({"error":"missing required field: model"})

      log =
        capture_log(fn ->
          assert Completion.handle_error_status(400, body) == {:error, {:api_error, 400}}
        end)

      assert log =~ "missing required field: model"
    end
  end

  describe "extract_error_message/1" do
    test "parses nested error.message shape" do
      body = ~s({"error":{"message":"Invalid model"}})
      assert Completion.extract_error_message(body) == "Invalid model"
    end

    test "parses string error shape" do
      body = ~s({"error":"bad request"})
      assert Completion.extract_error_message(body) == "bad request"
    end

    test "returns nil for unrecognised shapes" do
      assert Completion.extract_error_message(~s({"foo":"bar"})) == nil
    end

    test "returns nil for non-JSON body" do
      assert Completion.extract_error_message("<!DOCTYPE html>") == nil
    end
  end

  describe "extract_content/1" do
    test "pulls content from the first choice" do
      response = %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Hi!"}}
        ]
      }

      assert Completion.extract_content(response) == {:ok, "Hi!"}
    end

    test "returns :no_choices_in_response when choices are empty" do
      assert Completion.extract_content(%{"choices" => []}) ==
               {:error, :no_choices_in_response}
    end

    test "returns :invalid_response_format for malformed response" do
      assert Completion.extract_content(%{}) == {:error, :invalid_response_format}
    end
  end

  describe "extract_usage/1" do
    test "reads token counts and cost" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15,
          "cost" => 0.0001
        }
      }

      assert %{
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15,
               cost_cents: 100
             } = Completion.extract_usage(response)
    end

    test "falls back to zeros when usage is absent" do
      assert %{
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 0,
               cost_cents: nil
             } = Completion.extract_usage(%{})
    end

    test "reads total_cost as fallback for cost" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 0,
          "completion_tokens" => 0,
          "total_tokens" => 0,
          "total_cost" => 0.000001
        }
      }

      assert %{cost_cents: 1} = Completion.extract_usage(response)
    end
  end
end
