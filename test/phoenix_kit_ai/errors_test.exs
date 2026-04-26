defmodule PhoenixKitAI.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Errors

  describe "message/1 — plain atoms" do
    # Pin the EXACT translated string for every atom in the public
    # error vocabulary. `assert is_binary/1` is the wrong bar — every
    # branch returns a binary — so a typo in one of the gettext calls
    # would slip through. A new atom added to `Errors.message/1` MUST
    # come with a row here.

    test ":endpoint_not_found" do
      assert Errors.message(:endpoint_not_found) == "Endpoint not found"
    end

    test ":endpoint_disabled" do
      assert Errors.message(:endpoint_disabled) == "Endpoint is disabled"
    end

    test ":invalid_endpoint_identifier" do
      assert Errors.message(:invalid_endpoint_identifier) == "Invalid endpoint identifier"
    end

    test ":invalid_api_key" do
      assert Errors.message(:invalid_api_key) == "Invalid API key"
    end

    test ":api_key_forbidden" do
      assert Errors.message(:api_key_forbidden) == "API key forbidden"
    end

    test ":model_not_found" do
      assert Errors.message(:model_not_found) == "Model not found"
    end

    test ":insufficient_credits" do
      assert Errors.message(:insufficient_credits) == "Insufficient credits"
    end

    test ":rate_limited" do
      assert Errors.message(:rate_limited) == "Rate limited"
    end

    test ":request_timeout" do
      assert Errors.message(:request_timeout) == "Request timeout"
    end

    test ":invalid_json_response" do
      assert Errors.message(:invalid_json_response) == "Invalid JSON response"
    end

    test ":no_choices_in_response" do
      assert Errors.message(:no_choices_in_response) == "No choices in response"
    end

    test ":invalid_response_format" do
      assert Errors.message(:invalid_response_format) == "Invalid response format"
    end

    test ":empty_input" do
      assert Errors.message(:empty_input) == "Input cannot be empty"
    end

    test ":endpoint_no_model" do
      assert Errors.message(:endpoint_no_model) == "Endpoint has no model configured"
    end

    test ":integration_deleted carries the full guidance string" do
      msg = Errors.message(:integration_deleted)
      assert msg =~ "integration used by this endpoint has been deleted"
      assert msg =~ "Please select a new one"
    end

    test ":integration_not_configured points to Settings → Integrations" do
      msg = Errors.message(:integration_not_configured)
      assert msg =~ "No integration configured for this endpoint"
      assert msg =~ "Settings → Integrations"
    end
  end

  describe "message/1 — tagged tuples" do
    test "{:api_error, status} interpolates the status code" do
      assert Errors.message({:api_error, 503}) == "API error: 503"
      assert Errors.message({:api_error, 400}) == "API error: 400"
    end

    test "{:connection_error, reason} inspects the reason" do
      msg = Errors.message({:connection_error, :closed})
      assert msg =~ "Connection error"
      assert msg =~ ":closed"
    end

    test "prompt error variants" do
      assert Errors.message({:prompt_error, :not_found}) == "Prompt not found"
      assert Errors.message({:prompt_error, :disabled}) == "Prompt is disabled"
      assert Errors.message({:prompt_error, :empty_content}) == "Prompt has no content"
      assert Errors.message({:prompt_error, :invalid_identifier}) == "Invalid prompt identifier"
      assert Errors.message({:prompt_error, :content_not_string}) == "Content must be a string"
    end

    test "{:prompt_error, {:missing_variables, [...]}} joins variable names" do
      msg = Errors.message({:prompt_error, {:missing_variables, ["Name", "Age"]}})
      assert msg =~ "Missing prompt variables"
      assert msg =~ "Name"
      assert msg =~ "Age"
    end

    test "unknown prompt error reason still returns a string" do
      msg = Errors.message({:prompt_error, :weird_thing})
      assert msg =~ "Prompt error"
    end
  end

  describe "message/1 — fallback paths" do
    test "string reasons pass through unchanged" do
      assert Errors.message("legacy reason") == "legacy reason"
    end

    test "unknown reasons surface via inspect" do
      msg = Errors.message({:something_new, 123})
      assert msg =~ "Unexpected error"
      assert msg =~ ":something_new"
    end
  end
end
