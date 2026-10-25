defmodule PhoenixKitAI.Web.Components.JournalRetentionCardDatesTest do
  use PhoenixKitAI.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitAI.Web.Components.JournalRetentionCard

  setup do
    on_exit(fn -> Gettext.put_locale(PhoenixKitAI.Gettext, "en") end)
  end

  @months %{
    "en" =>
      ~w(January February March April May June July August September October November December),
    "ru" => ~w(января февраля марта апреля мая июня июля августа сентября октября ноября декабря),
    "et" =>
      ~w(jaanuar veebruar märts aprill mai juuni juuli august september oktoober november detsember)
  }

  defp at(month), do: DateTime.new!(Date.new!(2026, month, 25), ~T[14:05:00], "Etc/UTC")

  defp with_locale(locale, fun) do
    Gettext.put_locale(PhoenixKitAI.Gettext, locale)
    fun.()
  end

  defp since(locale, month) do
    with_locale(locale, fn ->
      render_component(&JournalRetentionCard.retained_since/1, id: "since", at: at(month))
    end)
  end

  defp pruned(locale, month) do
    with_locale(locale, fn ->
      iso = DateTime.to_iso8601(at(month))
      render_component(&JournalRetentionCard.content_pruned/1, at: iso)
    end)
  end

  test "every month is spelled out in the form used after a day number" do
    for {locale, names} <- @months, {name, index} <- Enum.with_index(names, 1) do
      assert since(locale, index) =~ "25 #{name} 2026", "#{locale} #{index}"
      assert pruned(locale, index) =~ "25 #{name} 2026 14:05", "#{locale} #{index}"
    end
  end
end
