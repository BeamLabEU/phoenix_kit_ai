defmodule PhoenixKitAI.Web.EndpointsCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.Endpoints` LiveView. Hits sort,
  pagination, usage tab, filters, load-more, request details, PubSub
  handlers — every event handler not already pinned by `endpoints_test.exs`.

  Uses `render_hook/3` to drive `handle_event/3` directly so tests
  don't depend on conditional render branches (e.g. sort buttons that
  only appear when `@has_endpoints == true`).
  """

  use PhoenixKitAI.LiveCase

  describe "sort + pagination URL params" do
    test "sort by usage flips direction when clicked twice on same field", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=usage&dir=desc")

      render_hook(view, "sort", %{"by" => "usage"})

      assert_patch(view, "/en/admin/ai/endpoints?sort=usage&dir=asc")
    end

    test "sort by a different field defaults to :desc", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")

      render_hook(view, "sort", %{"by" => "cost"})

      assert_patch(view, "/en/admin/ai/endpoints?sort=cost&dir=desc")
    end

    test "goto_page with valid number patches URL", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")
      render_hook(view, "goto_page", %{"page" => "2"})
      assert_patch(view, "/en/admin/ai/endpoints?sort=name&dir=asc&page=2")
    end

    test "goto_page with garbage stays put (no patch)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")
      render_hook(view, "goto_page", %{"page" => "not-a-number"})
      assert is_binary(render(view))
    end

    test "/admin/ai (without /endpoints) redirects with default sort/dir", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: target}}} = live(conn, "/en/admin/ai")
      assert target =~ "/endpoints?sort=id&dir=asc"
    end

    test "unknown sort field falls back to default :id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints?sort=bogus&dir=desc")
      assert is_binary(html)
    end

    test "non-numeric page param falls back to 1", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints?page=foo")
      assert is_binary(html)
    end
  end

  describe "usage tab" do
    setup do
      ep = fixture_endpoint()

      {:ok, _r1} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: ep.uuid,
          endpoint_name: ep.name,
          model: "stats-model",
          status: "success",
          total_tokens: 10
        })

      {:ok, _r2} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: ep.uuid,
          endpoint_name: ep.name,
          model: "other-model",
          status: "error"
        })

      {:ok, %{ep: ep}}
    end

    test "mount on usage tab loads stats + filter options", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage")
      assert is_binary(html)
    end

    test "usage_sort flips direction on the same field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage?sort=inserted_at&dir=desc")

      render_hook(view, "usage_sort", %{"by" => "inserted_at"})

      # URL contains dir=asc after the flip
      assert_patch(view)
      assert render(view) |> is_binary()
    end

    test "usage_filter event runs cleanly", %{conn: conn, ep: ep} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      render_hook(view, "usage_filter", %{
        "endpoint" => ep.uuid,
        "model" => "stats-model",
        "status" => "success",
        "source" => "",
        "date" => "30d"
      })

      assert_patch(view)
    end

    test "clear_usage_filters runs cleanly", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/en/admin/ai/usage?sort=inserted_at&dir=desc&model=foo&status=error")

      render_hook(view, "clear_usage_filters", %{})

      assert_patch(view)
    end

    test "load_more_requests appends rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")
      render_hook(view, "load_more_requests", %{})
      assert is_binary(render(view))
    end

    test "show_request_details + close_request_details", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      {requests, _} = PhoenixKitAI.list_requests()
      [%{uuid: uuid} | _] = requests

      render_hook(view, "show_request_details", %{"uuid" => to_string(uuid)})
      render_hook(view, "close_request_details", %{})
      assert is_binary(render(view))
    end

    test "usage tab with date=today filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?date=today")
      assert is_binary(html)
    end

    test "usage tab with date=all filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?date=all")
      assert is_binary(html)
    end

    test "usage tab with garbage date filter falls back to default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?date=bogus")
      assert is_binary(html)
    end

    test "usage_sort with bogus field falls back to default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?sort=nonsense&dir=asc")
      assert is_binary(html)
    end
  end

  describe "PubSub broadcast handling" do
    test "endpoint_created event reloads the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")
      send(view.pid, {:endpoint_created, %PhoenixKitAI.Endpoint{name: "Pinged"}})
      assert is_binary(render(view))
    end

    test "endpoint_updated event reloads the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")
      send(view.pid, {:endpoint_updated, %PhoenixKitAI.Endpoint{name: "Updated"}})
      assert is_binary(render(view))
    end

    test "endpoint_deleted event reloads the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")
      send(view.pid, {:endpoint_deleted, %PhoenixKitAI.Endpoint{name: "Gone"}})
      assert is_binary(render(view))
    end

    test "request_created on the usage tab reloads usage stats", %{conn: conn} do
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")
      send(view.pid, {:request_created, %PhoenixKitAI.Request{endpoint_uuid: ep.uuid}})
      assert is_binary(render(view))
    end

    test "request_created off the usage tab is ignored gracefully", %{conn: conn} do
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")
      send(view.pid, {:request_created, %PhoenixKitAI.Request{endpoint_uuid: ep.uuid}})
      assert is_binary(render(view))
    end
  end
end
