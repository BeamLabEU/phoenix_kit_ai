defmodule PhoenixKitAI.CompletionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Completion

  describe "handle_error_status/2" do
    test "401 returns invalid API key error" do
      assert Completion.handle_error_status(401, "") == {:error, "Invalid API key"}
    end

    test "402 returns insufficient credits error" do
      assert Completion.handle_error_status(402, "") == {:error, "Insufficient credits"}
    end

    test "429 returns rate limited error" do
      assert Completion.handle_error_status(429, "") == {:error, "Rate limited"}
    end

    test "503 with OpenRouter-shaped error body returns the API message" do
      body = ~s({"error":{"message":"Upstream timeout"}})

      assert capture_log(fn ->
               assert Completion.handle_error_status(503, body) ==
                        {:error, "Upstream timeout"}
             end) =~ "OpenRouter completion failed: 503"
    end

    test "500 with opaque body falls back to generic error" do
      assert capture_log(fn ->
               assert Completion.handle_error_status(500, "<!DOCTYPE html>") ==
                        {:error, "API error: 500"}
             end) =~ "OpenRouter completion failed: 500"
    end

    test "400 with string error body returns the error string" do
      body = ~s({"error":"missing required field: model"})

      assert capture_log(fn ->
               assert Completion.handle_error_status(400, body) ==
                        {:error, "missing required field: model"}
             end) =~ "OpenRouter completion failed: 400"
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

    test "returns error when choices are empty" do
      assert Completion.extract_content(%{"choices" => []}) ==
               {:error, "No choices in response"}
    end

    test "returns error for malformed response" do
      assert Completion.extract_content(%{}) == {:error, "Invalid response format"}
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
  end
end
