defmodule PhoenixKitAI.Money do
  @moduledoc """
  Money as the module stores it: whole micro-dollars (millionths of a
  dollar — the unit of `Request.cost_cents`, which the module calls
  nanodollars), never a float. `parse_dollars/1` reads what a person typed.
  """

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
end
