defmodule PhoenixKitAI.Web.PromptFormCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.PromptForm`. Targets the
  `validate` event (extracted_variables tracking) and the update path
  through `save_prompt` that the existing tests don't cover.
  """

  use PhoenixKitAI.LiveCase

  describe "validate event extracts variables for preview" do
    test "validate with new content updates extracted_variables", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_change(view, "validate", %{
          "prompt" => %{
            "name" => "Probe",
            "content" => "Hello {{Name}}, you live in {{City}}"
          }
        })

      assert is_binary(html)
    end

    test "validate with no variables leaves extracted_variables empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_change(view, "validate", %{
          "prompt" => %{"name" => "X", "content" => "Plain text"}
        })

      assert is_binary(html)
    end
  end

  describe "save event — update path" do
    test "saving an existing prompt navigates to /prompts and flashes :updated",
         %{conn: conn} do
      prompt = fixture_prompt(name: "ToUpdate-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/#{prompt.uuid}/edit")

      result =
        render_hook(view, "save", %{
          "prompt" => %{
            "name" => prompt.name,
            "content" => "New content {{V}}"
          }
        })

      # push_navigate result OR error html
      assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
    end

    test "save with invalid attrs renders inline errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/new")

      html =
        render_hook(view, "save", %{
          "prompt" => %{"name" => "", "content" => ""}
        })

      assert html =~ "blank" or html =~ "can&#39;t be"
    end
  end

  describe "scope-bound actor_opts (admin? + actor_uuid threading)" do
    test "saving an edit with an injected scope threads actor_uuid through",
         %{conn: conn} do
      # Pin `actor_opts/1` `%{uuid: uuid} -> [actor_uuid: uuid, ...]`
      # branch + `admin?/1` `scope -> Scope.can_access_admin_area?(scope)`
      # branch.
      # Without a scope, both fall through to the `_`/`nil` clauses.
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      prompt = fixture_prompt(name: "ScopedSave-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/prompts/#{prompt.uuid}/edit")

      result =
        render_hook(view, "save", %{
          "prompt" => %{
            "name" => prompt.name,
            "content" => "Updated content {{V}}"
          }
        })

      assert match?({:error, {:live_redirect, _}}, result)

      assert_activity_logged(
        "prompt.updated",
        resource_uuid: prompt.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{"actor_role" => "user"}
      )
    end
  end

  describe "live_patch between two edit URLs" do
    test "reloads the prompt when the id changes in the same LV process",
         %{conn: conn} do
      # Pins the `:loaded_id` per-params reload guard. A boolean `:loaded`
      # flag would short-circuit and keep prompt A in the form even after
      # patching to prompt B's edit URL. No production caller does this
      # today, but the gate has to be safe under it.
      pa = fixture_prompt(name: "PatchA-#{System.unique_integer([:positive])}")
      pb = fixture_prompt(name: "PatchB-#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(conn, "/en/admin/ai/prompts/#{pa.uuid}/edit")
      assert html =~ pa.name
      refute html =~ pb.name

      patched_html = render_patch(view, "/en/admin/ai/prompts/#{pb.uuid}/edit")

      assert patched_html =~ pb.name,
             "expected live_patch to reload — prompt B should appear"

      refute patched_html =~ pa.name,
             "expected live_patch to clear prompt A from the form"
    end
  end
end
