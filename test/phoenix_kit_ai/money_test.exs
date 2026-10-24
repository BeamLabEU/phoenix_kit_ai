defmodule PhoenixKitAI.MoneyTest do
  @moduledoc """
  `PhoenixKitAI.Money`: every amount is US dollars as a `Decimal`. Floats go
  through their shortest decimal form, integers are refused where they could
  be the released versions' millionths, and a call's cost is rounded once.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Money

  defp ok?({:ok, %Decimal{} = value}, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp ok?(_result, _expected), do: false

  describe "to_decimal/1" do
    test "a float is the decimal it reads as, never its binary tail" do
      for {float, text} <- [
            {3.0e-5, "0.00003"},
            {4.0e-8, "0.00000004"},
            {0.1, "0.1"},
            {6.0e-7, "0.0000006"},
            {2.5, "2.5"}
          ] do
        assert {:ok, decimal} = Money.to_decimal(float)
        # equal AND written the same: Decimal.from_float(0.1) would be 0.1000000000000000055…
        assert Decimal.equal?(decimal, Decimal.new(text)), inspect(float)
        assert Decimal.to_string(Decimal.normalize(decimal), :normal) == text
      end
    end

    test "integers, decimal strings and Decimals are read as they are" do
      assert ok?(Money.to_decimal(5), "5")
      assert ok?(Money.to_decimal(" 0.25 "), "0.25")
      assert ok?(Money.to_decimal(Decimal.new("1.5")), "1.5")
    end

    test "NaN, infinities and garbage are refused" do
      for bad <- ["NaN", "inf", "-Infinity", "abc", "1.2.3", "", nil, %{}, Decimal.new("NaN")] do
        assert Money.to_decimal(bad) == :error, inspect(bad)
      end
    end
  end

  describe "amount/1" do
    test "takes a Decimal or a dollar string, and the integer 0" do
      assert ok?(Money.amount("5"), "5")
      assert ok?(Money.amount("0.10"), "0.1")
      assert ok?(Money.amount(Decimal.new("2")), "2")
      assert ok?(Money.amount(0), "0")
    end

    test "refuses any other integer and every float as ambiguous" do
      # 5_000_000 was $5 in the released millionths; 5 might be either.
      for value <- [5_000_000, 5, 1, 0.5, 5.0] do
        assert Money.amount(value) == {:error, :ambiguous_amount}, inspect(value)
      end
    end

    test "refuses negatives, more than $1 000 000 000 and garbage" do
      for bad <- ["-1", "1000000000.01", "lots", nil] do
        assert Money.amount(bad) == :error, inspect(bad)
      end
    end
  end

  describe "legacy_amount?/1" do
    test "integers and digits-only strings are the released millionths" do
      assert Money.legacy_amount?(5_000_000)
      assert Money.legacy_amount?("5000000")
      assert Money.legacy_amount?(" 250000 ")
    end

    test "a dollar string, zero, blank and garbage are not" do
      for value <- ["5.00", "0.25", "0", "000", 0, "", "lots", nil, Decimal.new(5)] do
        refute Money.legacy_amount?(value), inspect(value)
      end
    end
  end

  describe "to_json/1" do
    test "writes at least two places, so a dollar amount never looks like millionths" do
      assert Money.to_json(Decimal.new("5")) == "5.00"
      assert Money.to_json(Decimal.new("0.1")) == "0.10"
      assert Money.to_json(Decimal.new("0.25")) == "0.25"
      assert Money.to_json(Decimal.new("0.0000004")) == "0.0000004"
      assert Money.to_json(Decimal.new("1.50000")) == "1.50"
      assert Money.to_json(Decimal.new("0")) == "0.00"

      for amount <- ~w(5 0.1 1 1000000 0.0000004) do
        refute amount |> Decimal.new() |> Money.to_json() |> Money.legacy_amount?()
      end
    end
  end

  describe "round_cost/1" do
    test "rounds to the cost column's 18 places, half up" do
      assert Decimal.equal?(
               Money.round_cost(Decimal.new("0.0000000000000000015")),
               Decimal.new("0.000000000000000002")
             )

      assert Decimal.equal?(
               Money.round_cost(Decimal.new("0.0000000000000000014")),
               Decimal.new("0.000000000000000001")
             )

      # the cheapest cached token today ($0.0014 per 1M) keeps every digit
      assert Decimal.equal?(
               Money.round_cost(Decimal.new("0.0000000014")),
               Decimal.new("0.0000000014")
             )

      assert Decimal.equal?(Money.round_cost(Decimal.new("0.00003")), Decimal.new("0.00003"))
      assert Money.round_cost(nil) == nil
    end
  end

  describe "sum/1" do
    test "a database sum is dollars; no rows is zero" do
      assert Decimal.equal?(Money.sum(nil), 0)
      assert Decimal.equal?(Money.sum(Decimal.new("0.0012")), Decimal.new("0.0012"))
      assert Decimal.equal?(Money.sum(3), 3)
    end
  end
end
