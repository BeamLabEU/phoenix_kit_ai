defmodule PhoenixKitAI.ProviderError do
  @moduledoc false
  # What a provider said when it refused a call.
  #
  # 1. The class its body names where the HTTP status alone misleads:
  #    money (`:insufficient_credits`, never worth a retry) sent as a 429,
  #    a 400 or a 403, and a transient budget sent as a 402. Only what the
  #    providers document:
  #
  #    * Z.ai — https://docs.z.ai/api-reference/api-code: `error.code` 1113
  #      (insufficient balance or no resource package), 1309 (GLM Coding
  #      Plan expired), 1314 (enterprise package expired), 1316 and 1317
  #      (usage limit reached, no balance for extra usage), each on a 429.
  #      1302 (rate limit) and 1305 (overloaded) stay `:rate_limited`.
  #    * OpenAI — https://developers.openai.com/api/docs/guides/error-codes:
  #      a 429 with `error.code` credit_balance_exhausted,
  #      organization_spend_limit_exceeded, project_spend_limit_exceeded or
  #      organization_usage_limit_exceeded, whose `error.type` "can still
  #      be" insufficient_quota (taken from either field).
  #    * Anthropic — https://platform.claude.com/docs/en/api/errors and
  #      https://platform.claude.com/docs/en/api/rate-limits: 402
  #      billing_error; the spend-cap 429, a rate_limit_error whose
  #      `error.details.error_code` is enforced_spend_limit_reached; the 400
  #      invalid_request_error of a spend limit you set, whose message
  #      starts "You have reached your specified (workspace) API usage
  #      limits".
  #    * OpenRouter — https://openrouter.ai/docs/api-reference/errors and
  #      https://openrouter.ai/docs/api_reference/limits: 402 (credits); a
  #      403 whose `error.metadata.limit_source` is a spent guardrail,
  #      workspace or key budget. A 402 whose `limit_source` is
  #      openrouter_in_flight_budget is transient (wait for Retry-After and
  #      retry): `:rate_limited`.
  #    * DeepSeek — https://api-docs.deepseek.com/quick_start/error_codes:
  #      402 Insufficient Balance, 429 rate limit; the status says it.
  #    * Mistral (https://docs.mistral.ai/admin/billing-usage/usage-limits)
  #      and xAI (https://docs.x.ai/developers/debugging) document no money
  #      error body: their 402 and 429 go by the status.
  #
  # 2. A note of the provider's own words for the request row: its status,
  #    code and message — the message trimmed, key-shaped words taken out,
  #    never the whole body nor a header — and the Retry-After of an error
  #    that is not about money, in seconds. The HTTP doors (`Completion`,
  #    `Providers.HTTP`) clear the note before each request and put the
  #    Retry-After; `Completion.handle_error_status/2` adds the rest;
  #    the row writers in `PhoenixKitAI` take it. It lives in the calling
  #    process, so the `{:error, reason}` shape every caller matches on
  #    stays as it is.

  @key {__MODULE__, :note}
  @max_message 300

  @zai_money ~w(1113 1309 1314 1316 1317)
  @openai_money ~w(insufficient_quota credit_balance_exhausted organization_spend_limit_exceeded
                   project_spend_limit_exceeded organization_usage_limit_exceeded)
  @openrouter_money ~w(openrouter_credits openrouter_guardrail_budget openrouter_workspace_budget
                       openrouter_key_limit)
  @anthropic_spend_limit ~r/^You have reached your specified (workspace )?API usage limits/

  # Words that look like a credential: a prefixed key (`sk-…`, `xai-…`),
  # an AWS key id, a bearer token, or a long unbroken token with a digit or
  # both cases in it — a Z.ai `id.secret`, base64, a JWT, a 32-hex request
  # id. A long run of plain words (`organization_usage_limit_exceeded`)
  # stays. A `/` splits a token and each part is judged alone, so a model id
  # (`meta-llama/llama-3.1-405b-instruct`) or a link's path stays readable;
  # the cost is that a base64 secret with `/` in it, every part under 32
  # characters, is kept. A link keeps its scheme, host and path (a path
  # part that is itself key-shaped goes); its query and fragment values
  # and any user:password go.
  @prefixed_key ~r/\b(?:sk|rk|pk|xai|gsk|key)[-_][A-Za-z0-9_\-\*\.+\/=]{6,}|\bAKIA[0-9A-Z]{16}\b|\bBearer\s+\S+/
  @long_token ~r/[A-Za-z0-9_\-\.+=]{32,}/
  @link ~r/\bhttps?:\/\/[^\s]+/
  @code_shape ~r/\A[A-Za-z0-9_.\-]{1,64}\z/

  @doc false
  @spec parse(term()) :: map() | nil
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      {:ok, %{"error" => message}} when is_binary(message) -> %{"message" => message}
      _ -> nil
    end
  end

  def parse(_body), do: nil

  @doc false
  # The class a parsed error body names, or nil to go by the status.
  @spec class(integer(), map() | nil) :: :insufficient_credits | :rate_limited | nil
  def class(_status, nil), do: nil

  def class(status, error) do
    cond do
      field(error, ["metadata", "limit_source"]) == "openrouter_in_flight_budget" -> :rate_limited
      money?(status, error) -> :insufficient_credits
      true -> nil
    end
  end

  defp money?(status, error) do
    code_string(field(error, ["code"])) in @zai_money or
      field(error, ["code"]) in @openai_money or
      field(error, ["type"]) in ["insufficient_quota", "billing_error"] or
      field(error, ["details", "error_code"]) == "enforced_spend_limit_reached" or
      field(error, ["metadata", "limit_source"]) in @openrouter_money or
      field(error, ["metadata", "error_type"]) == "payment_required" or
      (status == 400 and is_binary(error["message"]) and
         error["message"] =~ @anthropic_spend_limit)
  end

  @doc false
  # Adds what the error body said to the note of this request.
  @spec note(integer(), map() | nil, {:error, term()}) :: :ok
  def note(status, error, {:error, reason}) do
    note =
      (Process.get(@key) || %{})
      |> maybe_put(:code, error && code(status, error))
      |> maybe_put(:message, error && message(error))
      |> drop_retry_after(reason)

    if Map.drop(note, [:status]) == %{},
      do: Process.delete(@key),
      else: Process.put(@key, Map.put(note, :status, status))

    :ok
  end

  @doc false
  # A new request: nothing from an earlier one carries over.
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc false
  # The Retry-After of a refused request, as seconds; an unreadable one
  # is left out. Nothing here waits on it, so it is not capped.
  @spec put_retry_after(Req.Response.t()) :: :ok
  def put_retry_after(%Req.Response{} = response) do
    case retry_after_ms(response) do
      ms when is_integer(ms) -> Process.put(@key, %{retry_after_s: div(ms + 999, 1000)})
      _ -> :ok
    end

    :ok
  end

  defp retry_after_ms(response) do
    Req.Response.get_retry_after(response)
  rescue
    _ -> nil
  end

  @doc false
  # The note of the request that just failed, taken so it reaches one row.
  @spec take() :: map() | nil
  def take, do: Process.delete(@key)

  @doc false
  # The row's `error_message`: the module's text, then the provider's
  # words unless the text already says them, then its code.
  @spec describe(String.t(), map()) :: String.t()
  def describe(text, note) do
    message = if same_words?(note[:message], text), do: nil, else: note[:message]

    case {message, note[:code]} do
      {nil, nil} -> text
      {nil, code} -> "#{text} (#{code})"
      {message, nil} -> "#{text} — #{message}"
      {message, code} -> "#{text} — #{message} (#{code})"
    end
  end

  defp same_words?(nil, _text), do: true
  defp same_words?(message, text), do: String.contains?(plain(text), plain(message))

  defp plain(text), do: text |> String.trim_trailing(".") |> String.downcase()

  defp drop_retry_after(note, :insufficient_credits), do: Map.delete(note, :retry_after_s)
  defp drop_retry_after(note, _reason), do: note

  # The most specific code the body carries that reads as a code: a short
  # token, nothing key-shaped. OpenRouter's numeric `code` repeats the
  # status and says nothing more.
  defp code(status, error) do
    [
      field(error, ["details", "error_code"]),
      field(error, ["metadata", "limit_source"]),
      error["code"],
      field(error, ["metadata", "error_type"]),
      error["type"]
    ]
    |> Enum.find_value(fn
      code when is_integer(code) and code != status -> Integer.to_string(code)
      code when is_binary(code) -> if code_shaped?(code), do: code
      _ -> nil
    end)
  end

  defp code_shaped?(code), do: code =~ @code_shape and redact(code) == code

  defp code_string(code) when is_integer(code), do: Integer.to_string(code)
  defp code_string(code), do: code

  defp message(%{"message" => message}) when is_binary(message) do
    message
    |> redact()
    |> String.split()
    |> Enum.join(" ")
    |> cap()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp message(_error), do: nil

  defp redact(text) do
    text
    |> String.replace(@link, &redact_link/1)
    |> String.replace(@prefixed_key, "[redacted]")
    |> String.replace(@long_token, fn token ->
      if token =~ ~r/[0-9]/ or (token =~ ~r/[a-z]/ and token =~ ~r/[A-Z]/),
        do: "[redacted]",
        else: token
    end)
  end

  defp redact_link(link) do
    case String.split(link, ~r/[?#]/, parts: 2, include_captures: true) do
      [base, mark, rest] -> redact_userinfo(base) <> mark <> redact_values(rest)
      [base] -> redact_userinfo(base)
    end
  end

  defp redact_userinfo(base),
    do: Regex.replace(~r/\A(https?:\/\/)[^\/@\s]+@/, base, "\\1[redacted]@")

  defp redact_values(rest), do: Regex.replace(~r/=[^&#\s]+/, rest, "=[redacted]")

  # At most @max_message code points, so at most four times as many bytes
  # however many combining marks one character carries.
  defp cap(text) do
    text
    |> String.codepoints()
    |> Enum.take(@max_message)
    |> Enum.join()
  end

  defp field(map, [key]) when is_map(map), do: map[key]
  defp field(map, [key | rest]) when is_map(map), do: field(map[key], rest)
  defp field(_value, _path), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
