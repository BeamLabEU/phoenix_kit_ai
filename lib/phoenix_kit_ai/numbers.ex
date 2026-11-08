defmodule PhoenixKitAI.Numbers do
  @moduledoc """
  Numbers written the way the page's language writes them: `128,000` and
  `2.5` in English, `128 000` (a no-break space) and `2,5` in Estonian and Russian, where a
  comma is the decimal mark and `128,000` would read as 128.

  The language is the gettext locale of the request (core sets it for the
  page). Languages that group thousands with a comma and mark decimals with
  a point are listed; every other one groups with a no-break space and marks
  decimals with a comma. Dollar amounts are not written here: a price in US
  dollars keeps its point (`PhoenixKitAI.Request.format_cost/1`).
  """

  @point_languages ~w(en ja ko zh he th hi)
  @nbsp "\u00A0"

  @doc """
  An integer with its thousands grouped.

      iex> Gettext.with_locale(PhoenixKitAI.Gettext, "en", fn -> PhoenixKitAI.Numbers.integer(128_000) end)
      "128,000"

      iex> Gettext.with_locale(PhoenixKitAI.Gettext, "et", fn -> PhoenixKitAI.Numbers.integer(1_048_576) end)
      "1\u00A0048\u00A0576"
  """
  @spec integer(integer()) :: String.t()
  def integer(number) when is_integer(number) and number < 0, do: "-" <> integer(-number)

  def integer(number) when is_integer(number) do
    {group, _decimal} = separators()

    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1" <> group)
    |> String.reverse()
  end

  @doc """
  A number rounded to `places` decimals (trailing zeros kept as `Float.round/2`
  leaves them), with the language's decimal mark.

      iex> Gettext.with_locale(PhoenixKitAI.Gettext, "ru", fn -> PhoenixKitAI.Numbers.decimal(2.5, 1) end)
      "2,5"
  """
  @spec decimal(number(), non_neg_integer()) :: String.t()
  def decimal(number, places) when is_number(number) do
    {_group, mark} = separators()
    text = number |> Kernel.*(1.0) |> Float.round(places) |> Float.to_string()
    if mark == ".", do: text, else: String.replace(text, ".", mark)
  end

  defp separators do
    language =
      PhoenixKitAI.Gettext
      |> Gettext.get_locale()
      |> String.split(["-", "_"])
      |> hd()
      |> String.downcase()

    if language in @point_languages, do: {",", "."}, else: {@nbsp, ","}
  end
end
