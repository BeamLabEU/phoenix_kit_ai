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

  describe "edge-case input handling" do
    # Pins C12 agent #2's "tests cover error paths, not just happy paths"
    # requirement. Each case is a class of input that has historically
    # tripped Phoenix forms or Ecto changesets.

    test "Unicode name + content round-trips through changeset + DB" do
      attrs = %{
        name: "日本語プロンプト — Café 🚀 #{System.unique_integer([:positive])}",
        content: "Translate {{Text}} to 日本語 — keep emoji like 🎯 verbatim"
      }

      assert {:ok, prompt} = PhoenixKitAI.create_prompt(attrs)
      assert prompt.name =~ "日本語"
      assert prompt.content =~ "🎯"

      reloaded = PhoenixKitAI.get_prompt!(prompt.uuid)
      assert reloaded.name == prompt.name
      assert reloaded.content == prompt.content
    end

    test "SQL metacharacters in content store verbatim (Ecto parameterises queries)" do
      malicious_content = "'; DROP TABLE phoenix_kit_ai_prompts; -- {{Var}}"

      assert {:ok, prompt} =
               PhoenixKitAI.create_prompt(%{
                 name: "SQL Probe #{System.unique_integer([:positive])}",
                 content: malicious_content
               })

      assert prompt.content == malicious_content
      assert PhoenixKitAI.get_prompt!(prompt.uuid).content == malicious_content
    end

    test "very long content (>10k chars) is accepted — no length cap on content" do
      long_content = String.duplicate("Variable {{X}} ", 800)

      assert byte_size(long_content) > 10_000

      assert {:ok, prompt} =
               PhoenixKitAI.create_prompt(%{
                 name: "Long Prompt #{System.unique_integer([:positive])}",
                 content: long_content
               })

      assert byte_size(prompt.content) == byte_size(long_content)
    end

    test "empty content fails validate_required at the form layer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        view
        |> form("form", %{"prompt" => %{"name" => "Empty Content", "content" => ""}})
        |> render_submit()

      # Inline error renders — `:action = :validate` is set on save-error
      # so `<.input>`/`<.textarea>` gate on `field.errors`.
      assert html =~ "can&#39;t be blank" or html =~ "blank"
    end
  end
end
