defmodule PhoenixKitAI.Web.EndpointFormOfferedProviderTest do
  @moduledoc """
  A new endpoint starts on a provider the form offers: with connections for
  one provider only, that provider, its connections in the picker, and the
  value the form submits — not the mount default the select cannot show.
  """

  use PhoenixKitAI.LiveCase

  test "with only a Mistral connection, a new endpoint starts on Mistral", %{conn: conn} do
    name = "only-mistral-#{System.unique_integer([:positive])}"
    seed_mistral_connection(name)

    {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

    assert view |> element("#endpoint-provider-picker") |> render() =~ name

    assert view |> element("select[name='endpoint[provider]'] option[selected]") |> render() =~
             "mistral"
  end

  test "an offered provider the form already has is kept", %{conn: conn} do
    seed_openrouter_connection("or-#{System.unique_integer([:positive])}")
    seed_mistral_connection("mi-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

    assert view |> element("select[name='endpoint[provider]'] option[selected]") |> render() =~
             "openrouter"
  end
end
