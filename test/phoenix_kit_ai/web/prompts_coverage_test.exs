defmodule PhoenixKitAI.Web.PromptsCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.Prompts` LiveView.

  Hits sort, pagination, PubSub handlers — every event handler not
  pinned by `prompts_test.exs`.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Test.Repo, as: TestRepo

  describe "sort + pagination" do
    test "sort by name patches URL with :asc default", %{conn: conn} do
      _ = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      render_hook(view, "sort", %{"by" => "name"})
      assert_patch(view, "/en/admin/ai/prompts?sort=name&dir=asc")
    end

    test "sort by usage_count uses :desc as default", %{conn: conn} do
      _ = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts?sort=name&dir=asc")

      render_hook(view, "sort", %{"by" => "usage_count"})
      assert_patch(view, "/en/admin/ai/prompts?sort=usage_count&dir=desc")
    end

    test "clicking same sort field flips direction", %{conn: conn} do
      _ = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts?sort=name&dir=asc")

      render_hook(view, "sort", %{"by" => "name"})
      assert_patch(view, "/en/admin/ai/prompts?sort=name&dir=desc")
    end

    test "sort with bogus field falls back to :sort_order", %{conn: conn} do
      _ = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts?sort=name&dir=asc")

      render_hook(view, "sort", %{"by" => "bogus_field_not_real"})
      assert_patch(view, "/en/admin/ai/prompts?sort=sort_order&dir=asc")
    end

    test "goto_page with valid number patches URL", %{conn: conn} do
      _ = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts?sort=name&dir=asc")
      render_hook(view, "goto_page", %{"page" => "2"})
      path = assert_patch(view)
      assert path =~ "page=2"
    end

    test "goto_page with garbage stays put", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts?sort=name&dir=asc")
      render_hook(view, "goto_page", %{"page" => "junk"})
      render_hook(view, "goto_page", %{"page" => "0"})

      # The next patch the view makes is this one — the two above made none.
      render_hook(view, "sort", %{"by" => "name"})
      assert_patch(view, "/en/admin/ai/prompts?sort=name&dir=desc")
    end
  end

  describe "PubSub broadcast handling" do
    test "the list follows prompts created, renamed and deleted elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      prompt = fixture_prompt(name: "Broadcast-#{System.unique_integer([:positive])}")
      assert render(view) =~ prompt.name

      renamed = "Renamed-#{System.unique_integer([:positive])}"
      {:ok, prompt} = PhoenixKitAI.update_prompt(prompt, %{name: renamed})
      assert render(view) =~ renamed

      {:ok, _} = PhoenixKitAI.delete_prompt(prompt)
      refute render(view) =~ renamed
    end
  end

  describe "a prompt that is already gone" do
    test "toggling or deleting it says so instead of crashing", %{conn: conn} do
      gone = fixture_prompt(name: "Gone-#{System.unique_integer([:positive])}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      # Removed behind the list's back: no broadcast, so its row is still shown.
      TestRepo.delete!(gone)

      html = render_hook(view, "toggle_prompt", %{"uuid" => gone.uuid})
      assert html =~ "Prompt not found"
      refute html =~ gone.name

      html = render_hook(view, "delete_prompt", %{"uuid" => gone.uuid})
      assert html =~ "Prompt not found"
    end
  end

  describe "actor_opts / admin? without an injected scope" do
    test "delete_prompt without put_test_scope hits the no-scope actor_opts branch",
         %{conn: conn} do
      # Pin `actor_opts` `_ -> [actor_role: role]` (line 264) and
      # `admin?` `nil -> false` (line 270) — the no-scope branches
      # of both helpers. Exercised by NOT calling `put_test_scope`
      # in the test (so `socket.assigns[:phoenix_kit_current_scope]`
      # is nil and `socket.assigns[:phoenix_kit_current_user]` is
      # also nil).
      prompt = fixture_prompt()
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts")

      view
      |> element("#prompt-tbl-menu-#{prompt.uuid} button[phx-click='delete_prompt']")
      |> render_click()

      assert PhoenixKitAI.get_prompt(prompt.uuid) == nil
    end
  end

  describe "URL params — empty / non-numeric page" do
    test "an empty or non-numeric page param shows the first page", %{conn: conn} do
      prompt = fixture_prompt(name: "FirstPage-#{System.unique_integer([:positive])}")

      for page <- ["", "abc", "-1"] do
        {:ok, _view, html} = live(conn, "/en/admin/ai/prompts?page=#{page}")
        assert html =~ prompt.name
      end
    end
  end
end
