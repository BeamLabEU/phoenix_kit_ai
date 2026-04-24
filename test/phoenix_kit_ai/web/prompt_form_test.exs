defmodule PhoenixKitAI.Web.PromptFormTest do
  use PhoenixKitAI.LiveCase

  alias PhoenixKit.Utils.Slug

  describe "new" do
    test "renders the create prompt form with phx-disable-with on submit",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts/new")

      assert html =~ "New AI Prompt"
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
      assert html =~ ~s(name="prompt[name]")
    end
  end

  describe "edit" do
    test "renders the edit form for an existing prompt with phx-disable-with",
         %{conn: conn} do
      prompt = fixture_prompt(name: "Editable Prompt")

      {:ok, _view, html} = live(conn, "/en/admin/ai/prompts/#{prompt.uuid}/edit")

      assert html =~ "Editable Prompt"
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
    end

    test "redirects with a translated error flash when the prompt doesn't exist",
         %{conn: conn} do
      missing_uuid = "01234567-89ab-7def-8000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/ai/prompts/#{missing_uuid}/edit")

      assert flash["error"] =~ "Prompt not found"
    end
  end

  describe "save" do
    test "successful save persists, navigates to /prompts, and logs `prompt.created`",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      name = "Created via LV #{System.unique_integer([:positive])}"

      # Save push_navigates back to the prompts list. `follow_redirect/2`
      # walks that navigation and decodes the flash on the destination
      # page so we can assert on the actual translated success copy
      # (instead of the cookie-encoded flash token from the redirect).
      result =
        view
        |> form("form", %{"prompt" => %{"name" => name, "content" => "Hello!"}})
        |> render_submit()

      {:ok, _next_view, html} = follow_redirect(result, conn)

      assert html =~ "Prompt created successfully"

      created = PhoenixKitAI.get_prompt_by_slug(Slug.slugify(name))
      assert created
      assert_activity_logged("prompt.created", resource_uuid: created.uuid)
    end
  end
end
