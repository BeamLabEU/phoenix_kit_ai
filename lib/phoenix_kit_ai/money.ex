defmodule PhoenixKitAI.Money do
  @moduledoc """
  Money as the module keeps it: an amount of US dollars as a `Decimal`, never a
  float and never a scaled integer. A call's cost (`Request.cost`), the spend caps
  (`PhoenixKitAI.Budget`), the task limits (`PhoenixKitAI.TaskLimits`) and the
  prices per 1M tokens (`PhoenixKitAI.ManualPrice`) are all plain dollars.

  * `to_decimal/1` reads a number from anywhere (a provider's JSON float, a stored
    string, a `Decimal`); a float goes through its shortest decimal form, so
    `3.0e-5` is exactly `0.00003`, never `Decimal.from_float/1`'s binary tail.
  * `parse_dollars/1` reads what a person typed.
  * `amount/1` is the strict reader for an amount set in code or stored as a
    setting: a `Decimal` or a dollar string. An integer is refused there, because
    the released versions stored those amounts as integer millionths of a dollar
    (`5_000_000` meant $5), and reading one as dollars would loosen a cap a
    million times over. `0` is the one integer accepted (no amount).
  * `round_cost/1` is the only rounding: a call's total cost, to the 10 decimal
    places of the `cost` column.
  * `to_json/1` is how an amount is written into a JSON map: a string, so it reads
    back as the same decimal and never as a float.
  """

  @max_dollars Decimal.new(1_000_000_000)
  @cost_places 10

  @doc """
  A number as a `Decimal`: a `Decimal`, an integer, a finite float (through its
  shortest decimal form) or a decimal string (trimmed). `:error` for anything
  else, NaN and infinities included.
  """
  @spec to_decimal(term()) :: {:ok, Decimal.t()} | :error
  def to_decimal(%Decimal{} = value), do: finite(value)
  def to_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  def to_decimal(value) when is_float(value), do: value |> Float.to_string() |> to_decimal()

  def to_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> finite(decimal)
      _ -> :error
    end
  end

  def to_decimal(_value), do: :error

  defp finite(decimal) do
    if Decimal.nan?(decimal) or Decimal.inf?(decimal), do: :error, else: {:ok, decimal}
  end

  @doc """
  Dollars typed by a person: finite, from 0 to $1 000 000 000. `:error` for
  anything else — not a number, NaN, an infinity, a negative amount.
  """
  @spec parse_dollars(term()) :: {:ok, Decimal.t()} | :error
  def parse_dollars(value) when is_binary(value) do
    with {:ok, decimal} <- to_decimal(value),
         false <- Decimal.negative?(decimal),
         false <- Decimal.gt?(decimal, @max_dollars) do
      {:ok, decimal}
    else
      _ -> :error
    end
  end

  def parse_dollars(_value), do: :error

  @doc """
  An amount set in code or stored as a setting, as dollars: a `Decimal` or a
  dollar string, from 0 to $1 000 000 000; the integer `0` is no amount.
  `{:error, :ambiguous_amount}` for any other integer or a float (see the
  moduledoc), `:error` for anything that is not an amount at all.
  """
  @spec amount(term()) :: {:ok, Decimal.t()} | {:error, :ambiguous_amount} | :error
  def amount(0), do: {:ok, Decimal.new(0)}
  def amount(value) when is_integer(value) or is_float(value), do: {:error, :ambiguous_amount}
  def amount(%Decimal{} = value), do: in_range(to_decimal(value))
  def amount(value) when is_binary(value), do: in_range(to_decimal(value))
  def amount(_value), do: :error

  defp in_range({:ok, decimal}) do
    if Decimal.negative?(decimal) or Decimal.gt?(decimal, @max_dollars),
      do: :error,
      else: {:ok, decimal}
  end

  defp in_range(:error), do: :error

  @doc """
  Whether a stored amount is in the shape the released versions wrote: an
  integer, or a string of digits only (`"5000000"`), which meant millionths of a
  dollar. A dollar string always has a decimal point or is `"0"`.
  """
  @spec legacy_amount?(term()) :: boolean()
  def legacy_amount?(value) when is_integer(value), do: value != 0

  def legacy_amount?(value) when is_binary(value) do
    trimmed = String.trim(value)
    String.match?(trimmed, ~r/\A\d+\z/) and String.trim_leading(trimmed, "0") != ""
  end

  def legacy_amount?(_value), do: false

  @doc "A call's total cost rounded to the 10 decimal places of the `cost` column."
  @spec round_cost(Decimal.t() | nil) :: Decimal.t() | nil
  def round_cost(nil), do: nil
  def round_cost(%Decimal{} = cost), do: Decimal.round(cost, @cost_places, :half_up)

  @doc """
  An amount as it is written into a JSON map or a setting: a decimal string with
  at least two places (`"5.00"`, `"0.10"`, `"0.0000004"`), so it reads back as the
  same decimal, never as a float, and never looks like the released versions'
  digits-only millionths (`legacy_amount?/1`).
  """
  @spec to_json(Decimal.t()) :: String.t()
  def to_json(%Decimal{} = amount) do
    amount = Decimal.normalize(amount)
    amount = if amount.exp > -2, do: Decimal.round(amount, 2), else: amount
    Decimal.to_string(amount, :normal)
  end

  @doc "A sum read back from the database (a `Decimal`, or nil for no rows) as dollars."
  @spec sum(Decimal.t() | integer() | nil) :: Decimal.t()
  def sum(nil), do: Decimal.new(0)
  def sum(%Decimal{} = sum), do: sum
  def sum(sum) when is_integer(sum), do: Decimal.new(sum)

  @doc """
  Whether the database keeps costs in dollars: core's V223 has made
  `phoenix_kit_ai_requests.cost` and no legacy cost column (`cost_cents`,
  `cost_nanodollars`) is left beside it. Checked once per node and remembered
  once true; until then every call is refused
  (`{:error, :money_migration_required}`), because a sum of a column that is
  not there — or of a new empty one beside the old costs — reads as no spend.
  """
  @spec ready?() :: boolean()
  def ready? do
    case :persistent_term.get({__MODULE__, :ready}, false) do
      true -> true
      false -> check_ready()
    end
  end

  defp check_ready do
    import Ecto.Query, only: [from: 2]

    repo = PhoenixKit.RepoHelper.repo()
    repo.all(from(r in PhoenixKitAI.Request, select: r.cost, limit: 0))

    %{rows: [[legacy]]} =
      repo.query!(
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = $1 " <>
          "AND table_name = 'phoenix_kit_ai_requests' " <>
          "AND column_name IN ('cost_cents', 'cost_nanodollars')",
        [PhoenixKitAI.Request.__schema__(:prefix) || "public"]
      )

    ready? = legacy == 0
    if ready?, do: :persistent_term.put({__MODULE__, :ready}, true)
    ready?
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
