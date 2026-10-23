defmodule PhoenixKitAI.Request do
  use Gettext, backend: PhoenixKitAI.Gettext

  @moduledoc """
  AI request schema for PhoenixKit AI system.

  Tracks every AI API request for usage history and statistics.
  Used for monitoring costs, performance, and debugging.

  ## Schema Fields

  ### Request Identity
  - `endpoint_uuid`: Foreign key to the AI endpoint used
  - `endpoint_name`: Denormalized endpoint name for historical display
  - `prompt_uuid`: Foreign key to the AI prompt used (if request used a prompt template)
  - `prompt_name`: Denormalized prompt name for historical display
  - `user_uuid`: Foreign key to the user who made the request (nullable if user deleted)
  - `slot_index`: Which slot was used (deprecated, for backward compatibility)

  ### Request Details
  - `model`: Model identifier (e.g., "anthropic/claude-3-haiku")
  - `request_type`: Type of request (e.g., "text_completion", "chat", "embedding", "tts", "image", "image_edit", "vision")

  ### Token Usage
  - `input_tokens`: Number of tokens in the prompt
  - `output_tokens`: Number of tokens in the response
  - `total_tokens`: Total tokens used (input + output)

  ### Performance & Cost
  - `cost`: What the call cost in US dollars, a `Decimal` (when known)
  - `latency_ms`: Response time in milliseconds
  - `status`: Request status - "success", "error", or "timeout"
  - `error_message`: Error details if status is not "success"

  ### Metadata
  - `metadata`: Additional context (temperature, max_tokens, etc.)
  - `metadata.answered_model`: on chat and embedding rows, the model the
    provider says answered, where it is not the one asked for in `model`
    (`answered_model/1`). Image and vision rows record the answered model
    in `model` itself.
  - `metadata.provider_error`: on a failed call, what the provider said —
    `status`, `code`, `message` (trimmed, key-shaped words redacted) and
    `retry_after_s` for an error that is not about money.

  ## Status Types

  - `success` - Request completed successfully
  - `error` - Request failed with an error
  - `timeout` - Request timed out

  ## Usage Examples

      # Log a successful request
      {:ok, request} = PhoenixKitAI.create_request(%{
        endpoint_uuid: endpoint.uuid,
        endpoint_name: "Claude Fast",
        user_uuid: user.uuid,
        model: "anthropic/claude-3-haiku",
        request_type: "chat",
        input_tokens: 150,
        output_tokens: 320,
        total_tokens: 470,
        latency_ms: 850,
        status: "success",
        metadata: %{"temperature" => 0.7}
      })

      # Log a failed request
      {:ok, request} = PhoenixKitAI.create_request(%{
        endpoint_uuid: endpoint.uuid,
        endpoint_name: "Claude Fast",
        model: "anthropic/claude-3-haiku",
        status: "error",
        error_message: "Rate limit exceeded"
      })
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Prompt

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(success error timeout)
  @valid_request_types ~w(text_completion chat embedding tts image image_edit vision)

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :endpoint_name,
             :prompt_name,
             :slot_index,
             :model,
             :request_type,
             :input_tokens,
             :output_tokens,
             :total_tokens,
             :cost,
             :latency_ms,
             :status,
             :error_message,
             :metadata,
             :inserted_at
           ]}

  schema "phoenix_kit_ai_requests" do
    # New endpoint system fields
    field(:endpoint_name, :string)

    # Prompt tracking (when request uses a prompt template)
    field(:prompt_name, :string)

    # Request details
    field(:slot_index, :integer)
    field(:model, :string)
    field(:request_type, :string, default: "chat")
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:total_tokens, :integer, default: 0)
    # US dollars (core's V223, numeric(20,10)); see `PhoenixKitAI.Money`.
    field(:cost, :decimal)
    field(:latency_ms, :integer)
    field(:status, :string, default: "success")
    field(:error_message, :string)
    field(:metadata, :map, default: %{})

    # Associations
    belongs_to(:endpoint, Endpoint, foreign_key: :endpoint_uuid, references: :uuid, type: UUIDv7)
    belongs_to(:prompt, Prompt, foreign_key: :prompt_uuid, references: :uuid, type: UUIDv7)
    field(:account_uuid, UUIDv7)
    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for request creation.
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :endpoint_uuid,
      :endpoint_name,
      :prompt_uuid,
      :prompt_name,
      :account_uuid,
      :user_uuid,
      :slot_index,
      :model,
      :request_type,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cost,
      :latency_ms,
      :status,
      :error_message,
      :metadata
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:request_type, @valid_request_types)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_cost()
    |> calculate_total_tokens()
    # Core names these constraints `fk_ai_requests_*` (v135), not the
    # `phoenix_kit_ai_requests_<field>_fkey` that `foreign_key_constraint/2`
    # derives by default — without an explicit `:name` the names never match,
    # so a violation escapes as a raw `Ecto.ConstraintError` instead of a
    # changeset error. Keep these in step with core's migration chain.
    |> foreign_key_constraint(:endpoint_uuid, name: :fk_ai_requests_endpoint_uuid)
    |> foreign_key_constraint(:user_uuid, name: :fk_ai_requests_user_uuid)
    # `prompt_uuid` had no declaration at all, so a bad prompt reference raised
    # instead of returning a changeset error — the same defect as the two above.
    #
    # It needs BOTH names. This module pins core `~> 2.0`, and the surviving
    # constraint name differs by install age: core's v135 adds the FK twice
    # under two names, each guarded only by its own name, so a freshly migrated
    # database carries `fk_ai_requests_prompt_uuid` AND
    # `phoenix_kit_ai_requests_prompt_uuid_fkey`, while a database predating the
    # second block carries only the latter (measured on max-dev, which has only
    # `phoenix_kit_ai_requests_prompt_uuid_fkey`). Declaring one name would keep
    # raising on whichever installs have the other. Ecto matches a constraint by
    # name, so listing both is exact, not a guess — and it stays correct after a
    # core cleanup migration converges the two.
    |> foreign_key_constraint(:prompt_uuid, name: :fk_ai_requests_prompt_uuid)
    |> foreign_key_constraint(:prompt_uuid, name: :phoenix_kit_ai_requests_prompt_uuid_fkey)
  end

  @doc """
  Returns the list of valid status types.
  """
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Whether the row is a call the guard refused before any HTTP
  (`metadata.refused`). Its status is `"error"`; the Usage tab marks it and
  filters on it as `"refused"`.
  """
  @spec refused?(t()) :: boolean()
  def refused?(%__MODULE__{metadata: %{} = metadata}),
    do: Map.get(metadata, "refused", Map.get(metadata, :refused)) == true

  def refused?(_request), do: false

  @doc """
  Returns the list of valid request types.
  """
  @spec valid_request_types() :: [String.t()]
  def valid_request_types, do: @valid_request_types

  @doc """
  Returns a human-readable, gettext-translated status label.

  Literal-call clauses are required so `mix gettext.extract` picks the
  strings up — a `gettext(status)` call over a variable wouldn't make
  it into the .pot.
  """
  @spec status_label(String.t()) :: String.t()
  def status_label("success"), do: gettext("Success")
  def status_label("error"), do: gettext("Error")
  def status_label("timeout"), do: gettext("Timeout")
  def status_label("refused"), do: gettext("Refused")
  def status_label(_), do: gettext("Unknown")

  @doc """
  The core `status_badge` status that colours a request's status: green for
  a success, red for an error, amber for a timeout. The label stays
  `status_label/1`.
  """
  @spec badge_status(String.t()) :: String.t()
  def badge_status("success"), do: "completed"
  def badge_status("error"), do: "error"
  def badge_status("timeout"), do: "offline"
  def badge_status(_), do: "unknown"

  @doc """
  Returns a CSS class for the status badge.
  """
  @spec status_color(String.t()) :: String.t()
  def status_color("success"), do: "badge-success"
  def status_color("error"), do: "badge-error"
  def status_color("timeout"), do: "badge-warning"
  def status_color(_), do: "badge-neutral"

  @doc """
  Formats the latency for display.
  """
  @spec format_latency(integer() | nil) :: String.t()
  def format_latency(nil), do: "-"
  def format_latency(ms) when ms < 1000, do: "#{ms}ms"
  def format_latency(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @doc """
  Formats the token count for display.
  """
  @spec format_tokens(integer() | nil) :: String.t()
  def format_tokens(nil), do: "-"
  def format_tokens(0), do: "0"
  def format_tokens(tokens) when tokens < 1000, do: "#{tokens}"
  def format_tokens(tokens) when tokens < 1_000_000, do: "#{Float.round(tokens / 1000, 1)}K"
  def format_tokens(tokens), do: "#{Float.round(tokens / 1_000_000, 2)}M"

  @doc """
  Formats a cost in dollars for display, with the precision the amount needs:
  - >= $0.01: 2 decimal places ($0.05, $1.23)
  - >= $0.0001: 4 decimal places ($0.0012)
  - >= $0.000001: 6 decimal places ($0.000030)
  - > $0: 10 decimal places ($0.0000000400)
  """
  @spec format_cost(Decimal.t() | 0 | nil) :: String.t()
  def format_cost(nil), do: "-"
  def format_cost(0), do: "$0.00"

  def format_cost(%Decimal{} = dollars) do
    places =
      cond do
        Decimal.compare(dollars, "0.01") != :lt -> 2
        Decimal.compare(dollars, "0.0001") != :lt -> 4
        Decimal.compare(dollars, "0.000001") != :lt -> 6
        Decimal.compare(dollars, 0) == :gt -> 10
        true -> 2
      end

    "$" <>
      (dollars |> Decimal.round(places, :half_up) |> Decimal.to_string(:normal) |> pad(places))
  end

  # `Decimal.round/3` keeps the places it was given, except for a whole number
  # read back with fewer: pad so `$1` shows as `$1.00`.
  defp pad(text, places) do
    case String.split(text, ".") do
      [whole] -> whole <> "." <> String.duplicate("0", places)
      [whole, frac] -> whole <> "." <> String.pad_trailing(frac, places, "0")
    end
  end

  @doc """
  The model the provider says answered (`metadata.answered_model`), where it
  is not the one asked for; `nil` otherwise.
  """
  @spec answered_model(t()) :: String.t() | nil
  def answered_model(%__MODULE__{model: model, metadata: %{} = metadata}),
    do: other_model(model, metadata["answered_model"] || metadata[:answered_model])

  def answered_model(_request), do: nil

  @doc false
  # `answered` where it names another model than `asked`; nil when it is
  # the same: the same name in any letter case (`Qwen/Qwen3-Embedding-8B` /
  # `qwen/qwen3-embedding-8b`), the same name with a provider prefix on one
  # side only (`gpt-4o` / `openai/gpt-4o`; two different prefixes are two
  # models), or a dated snapshot (`-2024-08-06`, `-20241022`) of an
  # undated name asked for. A snapshot other than the one asked for is
  # another model.
  @spec other_model(String.t() | nil, term()) :: String.t() | nil
  def other_model(asked, answered) when is_binary(answered) and answered != "" do
    if same_model?(asked, answered), do: nil, else: answered
  end

  def other_model(_asked, _answered), do: nil

  @dated ~r/-(?:\d{4}-\d{2}-\d{2}|\d{8})\z/

  defp same_model?(asked, answered) when is_binary(asked) do
    {asked, answered} = unprefixed(String.downcase(asked), String.downcase(answered))
    asked == answered or (not (asked =~ @dated) and String.replace(answered, @dated, "") == asked)
  end

  defp same_model?(_asked, _answered), do: false

  defp unprefixed(asked, answered) do
    case {String.contains?(asked, "/"), String.contains?(answered, "/")} do
      {true, false} -> {last_part(asked), answered}
      {false, true} -> {asked, last_part(answered)}
      _both_or_neither -> {asked, answered}
    end
  end

  defp last_part(model), do: model |> String.split("/") |> List.last()

  @doc """
  Extracts the model name without provider prefix.
  """
  def short_model_name(nil), do: "-"
  def short_model_name(""), do: "-"

  def short_model_name(model) do
    case String.split(model, "/") do
      [_provider, name | _rest] -> name
      [name] -> name
      _ -> model
    end
  end

  # Private functions

  # A cost is dollars, not negative, and fits the column: at most 10 decimal
  # places (a caller passing more is refused, not silently rounded).
  defp validate_cost(changeset) do
    case get_change(changeset, :cost) do
      %Decimal{} = cost ->
        cond do
          Decimal.negative?(cost) ->
            add_error(changeset, :cost, "must be greater than or equal to 0")

          Decimal.normalize(cost).exp < -10 ->
            add_error(changeset, :cost, "has more than 10 decimal places")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp calculate_total_tokens(changeset) do
    input = get_field(changeset, :input_tokens) || 0
    output = get_field(changeset, :output_tokens) || 0
    total = get_field(changeset, :total_tokens) || 0

    # Only calculate if total is 0 or not set
    if total == 0 and (input > 0 or output > 0) do
      put_change(changeset, :total_tokens, input + output)
    else
      changeset
    end
  end
end
