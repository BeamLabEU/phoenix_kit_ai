defmodule PhoenixKitAI.Web.UsageRefusedTest do
  @moduledoc """
  The Usage tab tells a call the guard refused before any HTTP from one the
  provider failed: a "Refused" badge on the row, and a status filter for
  refused calls only.
  """

  use PhoenixKitAI.LiveCase

  defp row(ep, model, metadata) do
    {:ok, request} =
      PhoenixKitAI.create_request(%{
        endpoint_uuid: ep.uuid,
        endpoint_name: ep.name,
        model: model,
        request_type: "chat",
        status: "error",
        error_message: "no",
        metadata: metadata
      })

    request
  end

  setup do
    ep = fixture_endpoint()
    refused = row(ep, "refused-model", %{"refused" => true, "task" => "test.plain"})
    failed = row(ep, "failed-model", %{"error_reason" => "{:api_error, 500}"})
    {:ok, refused: refused, failed: failed}
  end

  test "a refused row is marked; a failed one is not", %{
    conn: conn,
    refused: refused,
    failed: failed
  } do
    {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

    assert has_element?(view, "[data-refused='#{refused.uuid}']")
    refute has_element?(view, "[data-refused='#{failed.uuid}']")
  end

  test "the status filter offers refused calls only", %{conn: conn, refused: refused} do
    {:ok, view, html} = live(conn, "/en/admin/ai/usage?status=refused")

    assert has_element?(view, "#ai-usage-filters option[value=refused]")
    assert html =~ "Showing 1 of 1 requests"
    assert has_element?(view, "[data-refused='#{refused.uuid}']")

    {:ok, _view, html} = live(conn, "/en/admin/ai/usage?status=error")
    assert html =~ "Showing 2 of 2 requests"
  end
end
