defmodule PhoenixKitAI.Money do
  @moduledoc """
  Money as the module keeps it, never a float, in two units:

    * **nanodollars** (billionths of a dollar, `1_000_000_000` = $1) — what
      a call cost: `Request.cost_nanodollars`, `CallCost`, and every sum of
      the journal;
    * **micro-dollars** (millionths, `1_000_000` = $1) — every amount a
      person or a module sets: the spend caps (`PhoenixKitAI.Budget`), the
      task limits and their declared defaults (`PhoenixKitAI.TaskLimits`),
      the prices per 1M tokens (`PhoenixKitAI.ManualPrice`, the catalogue,
      `PhoenixKitAI.AnthropicPricing`). `parse_dollars/1` reads what a person
      typed into this unit.

  A journal sum meets a set amount only through `nano_to_micro/1`, so a
  comparison is always micro against micro.
  """

  @nano_per_micro 1_000

  @max_dollars Decimal.new(1_000_000_000)

  @doc """
  Dollars typed by a person, as whole micro-dollars: finite, from 0 to
  $1 000 000 000. `:error` for anything else — not a number, NaN, an
  infinity, a negative amount, or a positive one that would round to 0
  micro-dollars.
  """
  @spec parse_dollars(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_dollars(value) when is_binary(value) do
    with {decimal, ""} <- Decimal.parse(String.trim(value)),
         false <- Decimal.nan?(decimal) or Decimal.inf?(decimal),
         false <- Decimal.negative?(decimal),
         false <- Decimal.gt?(decimal, @max_dollars),
         micro = decimal |> Decimal.mult(1_000_000) |> Decimal.round(0) |> Decimal.to_integer(),
         false <- micro == 0 and not Decimal.eq?(decimal, 0) do
      {:ok, micro}
    else
      _ -> :error
    end
  end

  def parse_dollars(_value), do: :error

  @doc """
  Nanodollars as whole micro-dollars, rounded half up: a sum of the journal
  in the unit of the amounts it is checked against. `nil` stays `nil`.
  """
  @spec nano_to_micro(integer() | nil) :: integer() | nil
  def nano_to_micro(nil), do: nil

  def nano_to_micro(nano) when is_integer(nano) and nano >= 0,
    do: div(nano + 500, @nano_per_micro)

  def nano_to_micro(nano) when is_integer(nano), do: -nano_to_micro(-nano)

  @doc "Micro-dollars as nanodollars."
  @spec micro_to_nano(integer()) :: integer()
  def micro_to_nano(micro) when is_integer(micro), do: micro * @nano_per_micro

  @doc "Dollars (a provider's reported cost) as whole nanodollars, rounded."
  @spec dollars_to_nano(number()) :: integer()
  def dollars_to_nano(dollars) when is_number(dollars), do: round(dollars * 1_000_000_000)
end
