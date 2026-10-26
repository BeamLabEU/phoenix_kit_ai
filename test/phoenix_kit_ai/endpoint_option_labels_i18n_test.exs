defmodule PhoenixKitAI.EndpointOptionLabelsI18nTest do
  @moduledoc """
  The select-option labels and placeholder strings `PhoenixKitAI.Endpoint`
  hands to the admin forms follow the module's locale; the values the
  forms store do not.
  """

  # The locale lives in the process dictionary, so tests may run together.
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Endpoint

  @options [
    :image_size_options,
    :image_quality_options,
    :image_aspect_ratio_options,
    :reasoning_effort_options
  ]

  defp in_locale(locale, fun), do: Gettext.with_locale(PhoenixKitAI.Gettext, locale, fun)

  defp labels(options), do: Enum.map(options, &elem(&1, 0))
  defp values(options), do: Enum.map(options, &elem(&1, 1))

  for locale <- ["ru", "et"], fun <- @options do
    test "#{fun}/0 in #{locale}: translated labels, the same stored values" do
      english = in_locale("en", fn -> apply(Endpoint, unquote(fun), []) end)
      localized = in_locale(unquote(locale), fn -> apply(Endpoint, unquote(fun), []) end)

      assert values(localized) == values(english)

      # Every label that carries a word is translated; a bare ratio such as
      # "4:3" or the "HD" mark reads the same everywhere.
      for {{english_label, value}, {label, value}} <- Enum.zip(english, localized),
          english_label =~ ~r/[a-z]{2}/ do
        assert label != english_label, "#{english_label} is not translated in #{unquote(locale)}"
      end
    end
  end

  test "the stored values are the ones the providers accept" do
    assert values(Endpoint.image_size_options()) == ["1024x1024", "1792x1024", "1024x1792"]
    assert values(Endpoint.image_quality_options()) == ["standard", "hd"]
    assert values(Endpoint.reasoning_effort_options()) == ~w(none minimal low medium high xhigh)

    assert values(Endpoint.image_aspect_ratio_options()) ==
             ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]
  end

  test "English labels are the msgids themselves" do
    in_locale("en", fn ->
      assert labels(Endpoint.image_quality_options()) == ["Standard", "HD"]
      assert "Extra High (~95%)" in labels(Endpoint.reasoning_effort_options())
      assert Endpoint.masked_api_key(nil) == "Not set"
    end)
  end

  test "masked_api_key/1's placeholder is translated; a masked key is not touched" do
    assert in_locale("ru", fn -> Endpoint.masked_api_key(nil) end) == "Не задан"
    assert in_locale("et", fn -> Endpoint.masked_api_key("") end) == "Määramata"
    assert in_locale("ru", fn -> Endpoint.masked_api_key(:not_a_key) end) == "Не задан"

    assert in_locale("ru", fn -> Endpoint.masked_api_key("sk-or-v1-1234567890abcdef") end) ==
             "•••cdef"
  end
end
