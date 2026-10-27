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
  def message(:request_failed), do: gettext("The request could not be completed")
  def message(:invalid_endpoint_identifier), do: gettext("Invalid endpoint identifier")
  def message(:invalid_api_key), do: gettext("Invalid API key")
  def message(:api_key_forbidden), do: gettext("API key forbidden")
  def message(:model_not_found), do: gettext("Model not found")
  def message(:insufficient_credits), do: gettext("Insufficient credits")
  def message(:rate_limited), do: gettext("Rate limited")
  def message(:request_timeout), do: gettext("Request timeout")

  def message(:concurrency_limit_timeout),
    do: gettext("Too many AI requests are running; this one waited too long for its turn")

  def message(:concurrency_queue_full),
    do: gettext("Too many AI requests are waiting; try again shortly")

  def message(:invalid_json_response), do: gettext("Invalid JSON response")
  def message(:no_choices_in_response), do: gettext("No choices in response")
  def message(:invalid_response_format), do: gettext("Invalid response format")
  def message(:invalid_image_input), do: gettext("Invalid image input")

  def message(:invalid_embedding_input),
    do: gettext("Embedding input must be text or an image")

  def message(:invalid_statements),
    do: gettext("Statements must be a list of texts")

  def message(:invalid_batch_items), do: gettext("Batch items must be a list")
  def message(:invalid_labels), do: gettext("Labels must be a list of words")
  def message(:invalid_run), do: gettext("A run must be named with a text")
  def message(:item_timeout), do: gettext("The item took too long and was stopped")

  def message(:missing_in_group),
    do: gettext("The answer for this item was missing from its group's answer")

  def message({:item_exit, _tag}), do: gettext("The item failed with an internal error")
  def message({:invalid_budget, _reason}), do: gettext("The budget must be an amount in dollars")
  def message({:exception, _kind}), do: gettext("The item failed with an internal error")

  def message({:unsupported_batch_verb, verb}),
    do: gettext("A batch cannot run %{verb}", verb: inspect(verb))

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
    shown =
      if is_binary(value) and byte_size(value) > 120,
        do: "<#{byte_size(value)} bytes>",
        else: inspect(value)

    gettext("The model does not accept %{option} = %{value}", option: key, value: shown)
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

  def message({:output_truncated, _text}),
    do:
      gettext("The answer was cut off at the output limit; allow more output tokens (max_tokens)")

  def message({:model_not_listed, model}) do
    gettext("The provider's model list does not include %{model}", model: model)
  end

  def message({:budget_exceeded, :global}),
    do: gettext("The AI budget for the last 24 hours has been used up")

  def message({:budget_exceeded, :endpoint}),
    do: gettext("This endpoint's budget for the last 24 hours has been used up")

  def message({:budget_exceeded, :user}),
    do: gettext("You have used your AI allowance for the last 24 hours")

  def message({:budget_exceeded, :user_calls}),
    do: gettext("You have made as many AI requests as allowed for the last 24 hours")

  def message({:budget_unmigrated, _scope}),
    do: gettext("AI spending limits need an update before AI requests can run again")

  def message({:task_limit_unmigrated, _task}),
    do: gettext("This task's spending limit needs an update before it can run again")

  def message(:money_migration_required),
    do: gettext("AI requests are paused until the latest database update has run")

  def message({:task_limit_exceeded, :task, unit, period}) do
    gettext("This AI task has reached its %{name}",
      name: PhoenixKitAI.GuardEvents.limit_name(unit, period)
    )
  end

  def message({:task_limit_exceeded, :user, unit, period}) do
    gettext("You have reached your %{name} in this AI task",
      name: PhoenixKitAI.GuardEvents.limit_name(unit, period)
    )
  end

  # The group only: the block's reason is not for the blocked person, and a
  # refusal is a journal row every holder of `ai` reads.
  def message({:task_disabled, _key}),
    do: gettext("This AI task's module is switched off, so the task cannot run")

  def message({:task_blocked, _group}),
    do: gettext("You are blocked from this AI task until an administrator lifts the block")

  def message({:model_unfit, missing}) when is_list(missing) do
    gettext("The endpoint's model cannot do what this task needs: %{needs}",
      needs: PhoenixKitAI.Tasks.need_labels(missing)
    )
  end

  def message({:model_unverified, unclear}) when is_list(unclear) do
    gettext(
      "It is not known whether the endpoint's model can do what this task needs (%{needs}). Mark the model's capabilities on the endpoint first.",
      needs: PhoenixKitAI.Tasks.need_labels(unclear)
    )
  end

  def message({:no_provider_for_params, []}) do
    gettext(
      "No provider of this model accepts all the request's parameters. Remove the ones it does not support from the endpoint."
    )
  end

  def message({:no_provider_for_params, params}) when is_list(params) do
    gettext(
      "No provider of this model accepts all the request's parameters (%{params}). Remove the ones it does not support from the endpoint.",
      params: Enum.join(params, ", ")
    )
  end

  def message({:capabilities_unavailable, _reason}),
    do: gettext("The provider's model list could not be fetched")

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
  def message({:fetch_failed, _reason}), do: gettext("The image could not be downloaded")

  def message(:forbidden), do: gettext("You are not allowed to do this")
  def message(:module_disabled), do: gettext("The AI module is disabled")

  def message({:cutoff_in_future, kind}) do
    gettext("The cleanup boundary for %{kind} is in the future", kind: retention_kind(kind))
  end

  def message({:invalid_cutoff, kind}) do
    gettext("The cleanup boundary for %{kind} is not a date and time", kind: retention_kind(kind))
  end

  def message({:invalid_retention, kind}) do
    gettext("Invalid retention period for %{kind}", kind: retention_kind(kind))
  end

  def message(:prune_running), do: gettext("A journal cleanup is already running")

  def message(:stale_retention),
    do: gettext("The retention periods were changed by someone else; reload the page")

  def message({:foreign_key_blocks, table}) do
    gettext(
      "The table %{table} references the AI journal or the guard events in a way that would block or spread the deletion; nothing was deleted",
      table: table
    )
  end

  def message(:preview_timeout),
    do: gettext("Counting what would be deleted took too long")

  def message({:unknown_kind, _key}), do: gettext("Unknown kind of journal retention")

  def message(:settings_write_failed),
    do: gettext("The retention periods could not be saved")

  def message(:retention_busy),
    do: gettext("The retention periods are being saved by someone else; try again")

  def message(:enqueue_failed), do: gettext("The journal cleanup could not be queued")
  def message(:nothing_to_run), do: gettext("Choose what to clean up")

  def message(:preview_failed),
    do: gettext("Counting what would be deleted failed")

  def message({:prune_failed, "foreign_key_blocks"}),
    do:
      gettext(
        "A table references the AI journal or the guard events in a way that would block or spread the deletion; nothing was deleted"
      )

  def message({:prune_failed, "cutoff_in_future"}),
    do: gettext("A cleanup boundary was in the future; nothing was deleted")

  def message({:prune_failed, "invalid_cutoff"}),
    do: gettext("A cleanup boundary was not a date and time; nothing was deleted")

  def message({:prune_failed, "invalid_args"}),
    do: gettext("The cleanup job's arguments could not be read; nothing was deleted")

  def message({:prune_failed, _class}), do: gettext("The journal cleanup failed")

  # Passthrough for strings so legacy callers returning {:error, "..."}
  # still render something. New code should return atoms/tuples.
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end

  defp retention_kind(:content), do: gettext("the content of journal entries")
  defp retention_kind(:requests), do: gettext("journal entries")
  defp retention_kind(:guard_events), do: gettext("guard events")
  defp retention_kind(other), do: inspect(other)
end
