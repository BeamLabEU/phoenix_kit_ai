defmodule PhoenixKitAI.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Errors

  describe "message/1 — plain atoms" do
    test "known atoms translate to strings" do
      atoms = [
        :endpoint_not_found,
        :endpoint_disabled,
        :invalid_endpoint_identifier,
        :invalid_api_key,
        :insufficient_credits,
        :rate_limited,
        :request_timeout,
        :invalid_json_response,
        :no_choices_in_response,
        :invalid_response_format,
        :empty_input,
        :endpoint_no_model,
        :integration_deleted,
        :integration_not_configured
      ]

      for atom <- atoms do
        result = Errors.message(atom)
        assert is_binary(result), "expected string for #{atom}, got #{inspect(result)}"
        assert result != "", "empty message for #{atom}"
      end
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
