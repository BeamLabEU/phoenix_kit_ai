defmodule PhoenixKitAI.Web.UsageAnsweredModelTest do
  @moduledoc """
  The Usage tab names the model that answered where it is not the one asked
  for (`metadata.answered_model`), in the list and in the request details;
  a row answered by the model asked for shows only that one.
  """

  use PhoenixKitAI.LiveCase

  defp row(ep, metadata) do
    {:ok, request} =
      PhoenixKitAI.create_request(%{
        endpoint_uuid: ep.uuid,
        endpoint_name: ep.name,
        model: "glm-4.5",
        request_type: "chat",
        status: "success",
        metadata: metadata
      })

    request
  end

  setup do
    ep = fixture_endpoint()
    rerouted = row(ep, %{"answered_model" => "glm-5.3-flash"})
    plain = row(ep, %{})
    {:ok, rerouted: rerouted, plain: plain}
  end

  test "the list names the answered model only where it differs", %{
    conn: conn,
    rerouted: rerouted,
    plain: plain
  } do
    {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

    assert view |> element("[data-answered-model='#{rerouted.uuid}']") |> render() =~
             "glm-5.3-flash"

    refute has_element?(view, "[data-answered-model='#{plain.uuid}']")
  end

  test "the request details name the answered model", %{conn: conn, rerouted: rerouted} do
    {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

    view
    |> element("button[phx-click=show_request_details][phx-value-uuid='#{rerouted.uuid}']")
    |> render_click()

    assert view |> element("#ai-request-answered-model") |> render() =~
             "answered by glm-5.3-flash"
  end

  test "the details of a row answered by the model asked for name no other", %{
    conn: conn,
    plain: plain
  } do
    {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

    view
    |> element("button[phx-click=show_request_details][phx-value-uuid='#{plain.uuid}']")
    |> render_click()

    assert has_element?(view, "#ai-request-details")
    refute has_element?(view, "#ai-request-answered-model")
  end
end
