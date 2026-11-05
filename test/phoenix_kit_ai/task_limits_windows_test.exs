defmodule PhoenixKitAI.TaskLimitsWindowsTest do
  @moduledoc """
  `TaskLimits.windows/2` and `period_keys/2` at fixed instants and zones: the
  month window the monthly spend cap starts from. No database.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.TaskLimits

  @tallinn "Europe/Tallinn"
  @auckland "Pacific/Auckland"

  defp month(now, zone), do: TaskLimits.windows(now, zone).month

  test "February of a leap year has 29 days" do
    # Clocks in Tallinn are at +2 in winter.
    {from, to} = month(~U[2028-02-15 12:00:00Z], @tallinn)

    assert from == ~U[2028-01-31 22:00:00Z]
    assert to == ~U[2028-02-29 22:00:00Z]
    assert DateTime.diff(to, from, :hour) == 29 * 24

    {from, to} = month(~U[2027-02-15 12:00:00Z], @tallinn)
    assert DateTime.diff(to, from, :hour) == 28 * 24
  end

  test "the last local moments of December already belong to January" do
    # 23:30Z on December 31 is 01:30 on January 1 in Tallinn (+2).
    now = ~U[2026-12-31 23:30:00Z]

    assert month(now, @tallinn) == {~U[2026-12-31 22:00:00Z], ~U[2027-01-31 22:00:00Z]}
    assert TaskLimits.period_keys(now, @tallinn) == %{day: "2027-01-01", month: "2027-01"}

    # One minute before local midnight it is still December.
    before_midnight = ~U[2026-12-31 21:59:00Z]

    assert month(before_midnight, @tallinn) ==
             {~U[2026-11-30 22:00:00Z], ~U[2026-12-31 22:00:00Z]}

    assert TaskLimits.period_keys(before_midnight, @tallinn).month == "2026-12"
  end

  test "a month that starts in summer time and ends in winter time is an hour longer" do
    # Tallinn: +3 on October 1, back to +2 on October 25, 2026.
    {from, to} = month(~U[2026-10-10 12:00:00Z], @tallinn)

    assert from == ~U[2026-09-30 21:00:00Z]
    assert to == ~U[2026-10-31 22:00:00Z]
    assert DateTime.diff(to, from, :hour) == 31 * 24 + 1
  end

  test "a month that starts in winter time and ends in summer time is an hour shorter" do
    # Tallinn: +2 on March 1, forward to +3 on March 28, 2027.
    {from, to} = month(~U[2027-03-10 12:00:00Z], @tallinn)

    assert from == ~U[2027-02-28 22:00:00Z]
    assert to == ~U[2027-03-31 21:00:00Z]
    assert DateTime.diff(to, from, :hour) == 31 * 24 - 1
  end

  test "a southern zone: October starts after the switch to summer time" do
    # Auckland: +13 from September 27, 2026.
    {from, to} = month(~U[2026-10-15 00:00:00Z], @auckland)

    assert from == ~U[2026-09-30 11:00:00Z]
    assert to == ~U[2026-10-31 11:00:00Z]
  end

  test "a legacy offset and an unknown zone" do
    now = ~U[2026-10-15 12:00:00Z]

    # "3" is a fixed +3.
    assert month(now, "3") == {~U[2026-09-30 21:00:00Z], ~U[2026-10-31 21:00:00Z]}
    # "0" is UTC, and so is a name nobody knows.
    assert month(now, "0") == {~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z]}
    assert month(now, "Nowhere/Land") == month(now, "0")
  end

  test "the day window of the same call agrees with the month" do
    now = ~U[2026-10-31 21:30:00Z]
    windows = TaskLimits.windows(now, "3")

    # 00:30 on November 1 in +3: the day is November 1, the month November.
    assert windows.day == {~U[2026-10-31 21:00:00Z], ~U[2026-11-01 21:00:00Z]}
    assert windows.month == {~U[2026-10-31 21:00:00Z], ~U[2026-11-30 21:00:00Z]}
    assert TaskLimits.period_keys(now, "3") == %{day: "2026-11-01", month: "2026-11"}
  end
end
