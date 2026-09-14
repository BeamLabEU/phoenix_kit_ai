defmodule PhoenixKitAI.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the AI module's public
  API) to translated human-readable strings.

  Keeping the API layer locale-agnostic means callers and integration
  consumers can pattern-match on atoms and decide their own presentation.
  Anything user-facing (flash messages, error banners) goes through
  `message/1` which wraps each mapping in `gettext/1` using the
  `PhoenixKitAI.Gettext` backend.

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

  use Gettext, backend: PhoenixKitAI.Gettext

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
  def message(:invalid_image_input), do: gettext("Invalid image input")

  # The model answered with prose (usually a refusal) instead of an image.
  # The prose travels in the tuple so the request log keeps the reason;
  # the user-facing message stays generic.
  def message({:no_image_in_response, _text}), do: gettext("The model returned no image")

  def message(:invalid_audio_response) do
    gettext("The TTS provider returned an unreadable audio response.")
  end

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

  def message(:not_supported), do: gettext("Not supported by this provider")
  def message(:reference_image_required), do: gettext("This operation needs a reference image")

  def message({:unsupported_option, key, value}) do
    gettext("The model does not accept %{option} = %{value}", option: key, value: inspect(value))
  end

  def message({:too_many_images, count, max}) do
    gettext("Too many images: %{count} given, the model takes at most %{max}",
      count: count,
      max: max
    )
  end

  def message({:unknown_operation, operation}) do
    gettext("Unknown image operation: %{operation}", operation: inspect(operation))
  end

  def message({:missing_parameter, operation, key}) do
    gettext("Image operation %{operation} needs %{key}", operation: operation, key: key)
  end

  def message({:no_json_in_response, _text}), do: gettext("The model did not answer with JSON")

  def message({:conflicting_operations, first, second}) do
    gettext("Image operations %{first} and %{second} cannot be combined",
      first: first,
      second: second
    )
  end

  def message({:content_policy, reason}) do
    gettext("The provider refused this content: %{reason}", reason: reason)
  end

  def message({:image_too_large, bytes, max}) do
    gettext("Image too large: %{bytes} bytes, the limit is %{max}", bytes: bytes, max: max)
  end

  def message({:unsafe_url, _url}), do: gettext("That image URL cannot be fetched from here")

  def message({:fetch_failed, _url, _reason}), do: gettext("The image could not be downloaded")

  # Passthrough for strings so legacy callers returning {:error, "..."}
  # still render something. New code should return atoms/tuples.
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
