defmodule PhoenixKitAI.Web.Components.CapabilityBadgesTest do
  @moduledoc """
  The capability badges: documents and image generation beside images,
  tools and JSON schema, and a capability nobody verified shown as a grey
  "?" that says where to mark it — never like a missing one.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Web.Components.CapabilityBadges

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.to_list()
  defp present?(html, selector), do: query(html, selector) |> Enum.any?()

  defp badges(caps), do: render_component(&CapabilityBadges.badges/1, %{capabilities: caps})

  test "documents and image generation have their own badges" do
    html = badges(%Capabilities{vision: :yes, file_input: :yes, image_output: :yes})

    assert [documents] = query(html, "[data-capability=file_input][data-state=yes]")
    assert LazyHTML.text(documents) =~ "Documents"
    assert [generation] = query(html, "[data-capability=image_output][data-state=yes]")
    assert LazyHTML.text(generation) =~ "Image generation"
  end

  test "an unverified capability is a grey question mark that says where to mark it" do
    html = badges(%Capabilities{vision: :yes, file_input: :unknown, image_output: :no})

    assert [unknown] = query(html, "[data-capability=file_input][data-state=unknown]")
    assert LazyHTML.text(unknown) =~ "?"
    assert LazyHTML.attribute(unknown, "title") == ["Not verified — mark it on the endpoint"]
    assert LazyHTML.attribute(unknown, "class") |> hd() =~ "badge-ghost"
    refute LazyHTML.attribute(unknown, "class") |> hd() =~ "badge-error"
    refute LazyHTML.text(unknown) =~ "✗"

    # A capability the model lacks has no badge at all.
    refute present?(html, "[data-capability=image_output]")
  end

  test "a model nobody knows anything about has one unknown badge with the same hint" do
    assert [unknown] = query(badges(%Capabilities{}), "[data-capability=unknown]")
    assert LazyHTML.attribute(unknown, "title") == ["Not verified — mark it on the endpoint"]
  end

  test "the labels speak the module's other locales" do
    for {locale, expected} <- [
          {"ru",
           ["Документы", "Генерация изображений", "Не проверено — отметьте на конечной точке"]},
          {"et", ["Dokumendid", "Pildigeneratsioon", "Kontrollimata — märkige see lõpp-punktis"]}
        ] do
      Gettext.put_locale(PhoenixKitAI.Gettext, locale)
      html = badges(%Capabilities{file_input: :yes, image_output: :yes, vision: :unknown})
      for text <- expected, do: assert(html =~ text, "#{locale}: #{text}")
    end
  after
    Gettext.put_locale(PhoenixKitAI.Gettext, "en")
  end
end
