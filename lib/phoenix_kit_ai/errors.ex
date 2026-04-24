defmodule PhoenixKitAI.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the AI module's public
  API) to translated human-readable strings.

  Keeping the API layer locale-agnostic means callers and integration
  consumers can pattern-match on atoms and decide their own presentation.
  Anything user-facing (flash messages, error banners) goes through
  `message/1` which wraps each mapping in `gettext/1` using the
  `PhoenixKitWeb.Gettext` backend.

  ## Supported reason shapes

    * plain atoms — `:endpoint_not_found`, `:invalid_api_key`, etc.
    * tagged tuples — `{:api_error, status}`, `{:connection_error, reason}`,
      `{:prompt_error, :not_found | :disabled | :missing_variables}`
    * unknown reasons — rendered as `"Unexpected error: <inspect>"` via
      gettext so nothing ever silently surfaces a raw struct

  ## Example

      iex> PhoenixKitAI.Errors.message(:invalid_api_key)
      "Invalid API key"

      iex> PhoenixKitAI.Errors.message({:api_error, 503})
      "API error: 503"
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Translates an error reason (atom or tagged tuple) into a user-facing
  string via gettext.
  """
  @spec message(term()) :: String.t()
  def message(:endpoint_not_found), do: gettext("Endpoint not found")
  def message(:endpoint_disabled), do: gettext("Endpoint is disabled")
  def message(:invalid_endpoint_identifier), do: gettext("Invalid endpoint identifier")
  def message(:invalid_api_key), do: gettext("Invalid API key")
  def message(:api_key_forbidden), do: gettext("API key forbidden")
  def message(:model_not_found), do: gettext("Model not found")
  def message(:insufficient_credits), do: gettext("Insufficient credits")
  def message(:rate_limited), do: gettext("Rate limited")
  def message(:request_timeout), do: gettext("Request timeout")
  def message(:invalid_json_response), do: gettext("Invalid JSON response")
  def message(:no_choices_in_response), do: gettext("No choices in response")
  def message(:invalid_response_format), do: gettext("Invalid response format")
  def message(:empty_input), do: gettext("Input cannot be empty")
  def message(:endpoint_no_model), do: gettext("Endpoint has no model configured")

  def message(:integration_deleted) do
    gettext(
      "The integration used by this endpoint has been deleted. Please select a new one in the endpoint settings."
    )
  end

  def message(:integration_not_configured) do
    gettext(
      "No integration configured for this endpoint. Set up the API key in Settings → Integrations."
    )
  end

  def message({:api_error, status}) when is_integer(status) do
    gettext("API error: %{status}", status: status)
  end

  def message({:connection_error, reason}) do
    gettext("Connection error: %{reason}", reason: inspect(reason))
  end

  def message({:prompt_error, :not_found}), do: gettext("Prompt not found")
  def message({:prompt_error, :disabled}), do: gettext("Prompt is disabled")
  def message({:prompt_error, :empty_content}), do: gettext("Prompt has no content")
  def message({:prompt_error, :invalid_identifier}), do: gettext("Invalid prompt identifier")
  def message({:prompt_error, :content_not_string}), do: gettext("Content must be a string")

  def message({:prompt_error, {:missing_variables, vars}}) when is_list(vars) do
    gettext("Missing prompt variables: %{vars}", vars: Enum.join(vars, ", "))
  end

  def message({:prompt_error, reason}) do
    gettext("Prompt error: %{reason}", reason: inspect(reason))
  end

  # Passthrough for strings so legacy callers returning {:error, "..."}
  # still render something. New code should return atoms/tuples.
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
