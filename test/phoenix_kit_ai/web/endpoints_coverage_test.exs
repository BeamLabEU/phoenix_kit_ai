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

  import Ecto.Query

  alias PhoenixKit.Utils.Format
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "sort + pagination URL params" do
    test "sort by usage flips direction when clicked twice on same field", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=usage&dir=desc")

      render_hook(view, "sort", %{"by" => "usage"})

      assert_patch(view, PhoenixKitAI.Routes.ai_path() <> "/endpoints?sort=usage&dir=asc")
    end

    test "sort by a different field defaults to :desc", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")

      render_hook(view, "sort", %{"by" => "cost"})

      assert_patch(view, PhoenixKitAI.Routes.ai_path() <> "/endpoints?sort=cost&dir=desc")
    end

    test "goto_page with valid number patches URL", %{conn: conn} do
      _ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")
      render_hook(view, "goto_page", %{"page" => "2"})
      assert_patch(view, PhoenixKitAI.Routes.ai_path() <> "/endpoints?sort=name&dir=asc&page=2")
    end

    test "goto_page with garbage stays put (no patch)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")
      render_hook(view, "goto_page", %{"page" => "not-a-number"})
      render_hook(view, "goto_page", %{"page" => "0"})

      # The next patch the view makes is this one — the two above made none.
      render_hook(view, "goto_page", %{"page" => "3"})
      assert_patch(view, PhoenixKitAI.Routes.ai_path() <> "/endpoints?sort=name&dir=asc&page=3")
    end

    test "a sort event naming no known field keeps the current field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=name&dir=asc")

      # Not an existing atom at all, and an atom that is no sort field.
      for field <- ["no_such_sort_field_#{System.unique_integer([:positive])}", "uuid"] do
        render_hook(view, "sort", %{"by" => field})
        path = assert_patch(view)
        assert path =~ "sort=name"
      end
    end

    test "/admin/ai (without /endpoints) redirects with default sort/dir", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: target}}} = live(conn, "/en/admin/ai")
      assert target =~ "/endpoints?sort=id&dir=asc"
    end

    test "an unknown sort field in the URL falls back to the default field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints?sort=bogus&dir=desc")

      # Clicking the default field's header flips the direction, which it
      # only does when that field is the current one.
      render_hook(view, "sort", %{"by" => "inserted_at"})
      assert_patch(view, PhoenixKitAI.Routes.ai_path() <> "/endpoints?sort=inserted_at&dir=asc")
    end

    test "a non-numeric or empty page param shows the first page", %{conn: conn} do
      ep = fixture_endpoint()

      for page <- ["foo", "", "-2"] do
        {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints?page=#{page}")
        assert html =~ ep.name
      end
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

    defp backdate(%Request{uuid: uuid}, days) do
      at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)
      TestRepo.update_all(from(r in Request, where: r.uuid == ^uuid), set: [inserted_at: at])
    end

    test "mount on the usage tab lists the requests", %{conn: conn, ep: ep} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/usage")

      assert html =~ "Showing 2 of 2 requests"
      assert html =~ "stats-model"
      assert html =~ "other-model"
      assert html =~ ep.name
    end

    test "usage_sort flips direction on the same field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage?sort=inserted_at&dir=desc")

      render_hook(view, "usage_sort", %{"by" => "inserted_at"})

      path = assert_patch(view)
      assert path =~ "sort=inserted_at"
      assert path =~ "dir=asc"
    end

    test "a usage_sort event naming no known field keeps the current field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage?sort=model&dir=asc")

      for field <- ["no_such_usage_field_#{System.unique_integer([:positive])}", "uuid"] do
        render_hook(view, "usage_sort", %{"by" => field})
        path = assert_patch(view)
        assert path =~ "sort=model"
      end
    end

    test "usage_filter narrows the list to what matches", %{conn: conn, ep: ep} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      render_hook(view, "usage_filter", %{
        "endpoint" => ep.uuid,
        "model" => "stats-model",
        "status" => "success",
        "source" => "",
        "date" => "30d"
      })

      path = assert_patch(view)
      assert path =~ "model=stats-model"
      assert path =~ "status=success"
      assert path =~ "date=30d"

      assert render(view) =~ "Showing 1 of 1 requests"
    end

    test "clear_usage_filters drops every filter", %{conn: conn} do
      {:ok, view, html} =
        live(conn, "/en/admin/ai/usage?sort=inserted_at&dir=desc&model=foo&status=error")

      assert html =~ "No requests match the current filters"

      render_hook(view, "clear_usage_filters", %{})

      path = assert_patch(view)
      refute path =~ "model="
      refute path =~ "status="
      assert render(view) =~ "Showing 2 of 2 requests"
    end

    test "load_more_requests appends the next page and retires the button", %{conn: conn, ep: ep} do
      for _ <- 1..23 do
        {:ok, _} =
          PhoenixKitAI.create_request(%{
            endpoint_uuid: ep.uuid,
            endpoint_name: ep.name,
            model: "bulk-model",
            status: "success"
          })
      end

      {:ok, view, html} = live(conn, "/en/admin/ai/usage")
      assert html =~ "Showing 20 of 25 requests"
      assert has_element?(view, "button[phx-click='load_more_requests'][phx-disable-with]")

      html = render_hook(view, "load_more_requests", %{})

      assert html =~ "Showing 25 of 25 requests"
      refute has_element?(view, "button[phx-click='load_more_requests']")
    end

    test "show_request_details opens the request, close_request_details closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      {[%{uuid: uuid} | _], _} = PhoenixKitAI.list_requests()
      refute has_element?(view, "#ai-request-details")

      render_hook(view, "show_request_details", %{"uuid" => uuid})
      assert view |> element("#ai-request-details") |> render() =~ uuid

      render_hook(view, "close_request_details", %{})
      refute has_element?(view, "#ai-request-details")
    end

    test "the date filter bounds the list; an unknown value means the last 7 days", %{
      conn: conn,
      ep: ep
    } do
      {:ok, old} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: ep.uuid,
          endpoint_name: ep.name,
          model: "ten-days-old",
          status: "success"
        })

      backdate(old, 10)

      for {date, shown} <- [
            {"today", 2},
            {"7d", 2},
            {"30d", 3},
            {"all", 3},
            {"bogus", 2},
            {"", 2}
          ] do
        {:ok, _view, html} = live(conn, "/en/admin/ai/usage?date=#{date}")
        assert html =~ "Showing #{shown} of #{shown} requests", "date=#{date}"
      end
    end

    test "an unknown usage sort field in the URL falls back to the default field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/usage?sort=nonsense&dir=asc")

      # Clicking the default field's header flips the direction, which it
      # only does when that field is the current one.
      render_hook(view, "usage_sort", %{"by" => "inserted_at"})
      path = assert_patch(view)
      assert path =~ "sort=inserted_at"
      assert path =~ "dir=desc"
    end

    test "empty filter values filter nothing", %{conn: conn} do
      # Drive the empty-string clauses: parse_string_param("") → nil,
      # parse_endpoint_filter("") → nil, parse_date_filter("") → "7d",
      # parse_page("") → 1, maybe_add_filter(opts, _, "") → opts.
      {:ok, _view, html} =
        live(conn, "/en/admin/ai/usage?model=&status=&source=&endpoint=&date=&page=")

      assert html =~ "Showing 2 of 2 requests"
    end

    test "an endpoint filter shows only that endpoint's requests", %{conn: conn, ep: ep} do
      idle = fixture_endpoint()

      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?endpoint=#{ep.uuid}")
      assert html =~ "Showing 2 of 2 requests"

      {:ok, _view, html} = live(conn, "/en/admin/ai/usage?endpoint=#{idle.uuid}")
      assert html =~ "No requests match the current filters"
    end

    test "delete_endpoint without put_test_scope hits the no-scope actor_opts branch",
         %{conn: conn} do
      # Pin `actor_opts` `_ -> [actor_role: role]` (line 613) and
      # `admin?` `nil -> false` (line 619) — no-scope branches.
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      view
      |> element("#endpoint-tbl-menu-#{ep.uuid} button[phx-click='delete_endpoint']")
      |> render_click()

      assert PhoenixKitAI.get_endpoint(ep.uuid) == nil
    end

    test "the request modal shows the caller's memory in a readable unit", %{conn: conn, ep: ep} do
      sizes = [{512, "B"}, {500_000, "KB"}, {500_000_000, "MB"}, {2_000_000_000, "GB"}]

      requests =
        for {memory, unit} <- sizes do
          {:ok, request} =
            PhoenixKitAI.create_request(%{
              endpoint_uuid: ep.uuid,
              endpoint_name: ep.name,
              model: ep.model,
              request_type: "chat",
              status: "success",
              metadata: %{caller_context: %{memory_bytes: memory}}
            })

          {request, memory, unit}
        end

      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      for {request, memory, unit} <- requests do
        render_hook(view, "show_request_details", %{"uuid" => request.uuid})
        shown = Format.bytes(memory)

        assert shown =~ unit
        assert view |> element("#ai-request-details") |> render() =~ shown
      end
    end

    test "deleting or toggling an endpoint that is already gone says so instead of crashing", %{
      conn: conn
    } do
      gone = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      # Removed behind the list's back: no broadcast, so its row is still shown.
      TestRepo.delete!(gone)

      html = render_hook(view, "toggle_endpoint", %{"uuid" => gone.uuid})
      assert html =~ "Endpoint not found"
      refute html =~ gone.name

      html = render_hook(view, "delete_endpoint", %{"uuid" => gone.uuid})
      assert html =~ "Endpoint not found"
    end
  end

  describe "PubSub broadcast handling" do
    test "the list follows endpoints created, renamed and deleted elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      ep = fixture_endpoint(name: "Broadcast-#{System.unique_integer([:positive])}")
      assert render(view) =~ ep.name

      renamed = "Renamed-#{System.unique_integer([:positive])}"
      {:ok, ep} = PhoenixKitAI.update_endpoint(ep, %{name: renamed})
      html = render(view)
      assert html =~ renamed

      {:ok, _} = PhoenixKitAI.delete_endpoint(ep)
      refute render(view) =~ renamed
    end

    test "requests logged while the usage tab is open reach it in one coalesced reload", %{
      conn: conn
    } do
      ep = fixture_endpoint()
      {:ok, view, html} = live(conn, "/en/admin/ai/usage")
      refute html =~ "burst-model"

      create = fn ->
        {:ok, _} =
          PhoenixKitAI.create_request(%{
            endpoint_uuid: ep.uuid,
            endpoint_name: ep.name,
            model: "burst-model",
            status: "success"
          })
      end

      create.()
      # Not reloaded on the spot: a reload is scheduled instead.
      refute render(view) =~ "burst-model"
      timer = assigns(view).usage_refresh_timer
      assert is_reference(timer)

      create.()
      create.()
      render(view)
      # The two that followed are covered by the reload already scheduled.
      assert assigns(view).usage_refresh_timer == timer

      assert eventually(fn -> render(view) =~ "Showing 3 of 3 requests" end)
      assert assigns(view).usage_refresh_timer == nil
    end

    test "a request logged while another tab is open schedules nothing", %{conn: conn} do
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      {:ok, _} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: ep.uuid,
          endpoint_name: ep.name,
          model: "elsewhere",
          status: "success"
        })

      render(view)
      assert assigns(view).usage_refresh_timer == nil
    end
  end
end
