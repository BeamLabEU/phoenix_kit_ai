defmodule PhoenixKitAI.Web.CapabilityExplanationsTest do
  @moduledoc """
  The capabilities in plain words: one source of texts
  (`CapabilityBadges.explain/1`), what each is, which task needs it and how
  to tell whether a model has it — on every badge, filter, need and
  declaration checkbox as a `title`, and in a visible glossary on the
  endpoint form, the recommendations block and the Tasks page. On the
  endpoint form, the block on how to determine a model's capabilities, and
  each capability's current value with where it comes from.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Web.Components.CapabilityBadges
  alias PhoenixKitAI.Web.EndpointForm

  @flags [:vision, :file_input, :image_output, :tools, :json_schema, :json, :context]

  @howto_links [
    "https://developers.openai.com/api/docs/models",
    "https://docs.x.ai/developers/models",
    "https://docs.z.ai/guides/overview/overview",
    "https://docs.z.ai/guides/vlm/glm-4.5v",
    "https://openrouter.ai/models"
  ]

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp attr(html, selector, name),
    do: html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "explain/1" do
    test "says, for every capability, what it is, which task needs it and how to tell" do
      for flag <- @flags do
        %{what: what, needed_by: needed_by, check: check} = CapabilityBadges.explain(flag)

        for part <- [what, needed_by, check] do
          assert is_binary(part) and String.length(part) > 10, "#{flag}: #{inspect(part)}"
        end

        assert CapabilityBadges.explain_text(flag) =~ what
        assert CapabilityBadges.explain_text(flag) =~ check
      end
    end

    test "is translated into Estonian and Russian" do
      for locale <- ["et", "ru"], flag <- @flags do
        english = CapabilityBadges.explain(flag)

        translated =
          Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
            CapabilityBadges.explain(flag)
          end)

        for key <- [:what, :needed_by, :check] do
          refute Map.fetch!(translated, key) == Map.fetch!(english, key),
                 "#{locale} #{flag} #{key} is not translated"
        end
      end
    end

    test "covers every need, declarable capability and filter" do
      assert PhoenixKitAI.TaskSpec.needs() -- CapabilityBadges.explained() == []
      assert Capabilities.declarable() -- CapabilityBadges.explained() == []
      assert PhoenixKitAI.Recommendations.filterable() -- CapabilityBadges.explained() == []
    end

    test "says something general for a capability it does not know, without failing" do
      %{what: what, needed_by: needed_by, check: check} = CapabilityBadges.explain(:teleport)
      assert what =~ "teleport"
      assert is_binary(needed_by) and is_binary(check)
      assert CapabilityBadges.explain_text(:teleport) =~ what
    end

    test "names no host project" do
      for flag <- @flags, part <- Map.values(CapabilityBadges.explain(flag)) do
        refute part =~ ~r/\bandi\b/i
      end
    end
  end

  describe "the badges" do
    test "carry the explanation as their title, the unverified hint after it" do
      html =
        render_component(&CapabilityBadges.badges/1, %{
          capabilities: %Capabilities{vision: :yes, tools: :unknown}
        })

      assert [title] = attr(html, "[data-capability=vision]", "title")
      assert title == CapabilityBadges.explain_text(:vision)

      assert [unknown] = attr(html, "[data-capability=tools]", "title")
      assert unknown =~ CapabilityBadges.explain_text(:tools)
      assert unknown =~ "Not verified — mark it on the endpoint"
    end
  end

  describe "capability_panel/5" do
    test "gives each capability its value and where it comes from" do
      model = %AIModel{
        id: "m",
        capabilities: %Capabilities{vision: :yes, file_input: :no}
      }

      endpoint = %{
        provider_settings: %{"capabilities" => %{"model" => "m", "tools" => "yes"}}
      }

      form = Phoenix.Component.to_form(%{}, as: :endpoint)
      %{rows: rows} = EndpointForm.capability_panel("m", model, form, endpoint, "openrouter")

      assert {:vision, :yes, :catalogue} in rows
      assert {:file_input, :no, :catalogue} in rows
      assert {:tools, :yes, :manual} in rows
      assert {:json_schema, :unknown, nil} in rows
    end

    test "the source of a value checked by a call has its words, for when it exists" do
      assert CapabilityBadges.source_label(:call) =~ "call"
    end
  end

  describe "the endpoint form" do
    defp declared_endpoint do
      %{uuid: integration_uuid} =
        seed_mistral_connection("howto-#{System.unique_integer([:positive])}")

      fixture_endpoint(
        provider: "mistral",
        base_url: "https://api.mistral.ai/v1",
        model: "glm-4.5v",
        integration_uuid: integration_uuid,
        provider_settings: %{"capabilities" => %{"model" => "glm-4.5v", "vision" => "yes"}}
      )
    end

    test "has the block on determining capabilities, with exactly the five links",
         %{conn: conn} do
      endpoint = declared_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "details#endpoint-capability-howto")

      hrefs =
        view
        |> element("#endpoint-capability-howto")
        |> render()
        |> attr("a", "href")

      assert Enum.sort(hrefs) == Enum.sort(@howto_links)
      assert has_element?(view, "#endpoint-capability-howto", "Playground")
    end

    test "shows each capability's value and its source", %{conn: conn} do
      endpoint = declared_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(
               view,
               "[data-capability-value=vision][data-value=yes][data-source=manual]",
               "marked by hand"
             )

      assert has_element?(view, "[data-capability-value=tools][data-value=unknown]", "?")
      refute has_element?(view, "[data-source=call]")
    end

    test "the declaration checkboxes and the glossary explain the capabilities",
         %{conn: conn} do
      endpoint = declared_endpoint()
      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert [title] = attr(html, "label:has(#endpoint-declare-tools)", "title")
      assert title == CapabilityBadges.explain_text(:tools)

      assert has_element?(view, "details#endpoint-capability-glossary")

      for flag <- @flags do
        assert has_element?(view, "#endpoint-capability-glossary [data-explain=#{flag}]")
      end
    end
  end

  describe "the Tasks page" do
    setup do
      :ok = ModuleRegistry.register(FakeAITasks)
      on_exit(fn -> ModuleRegistry.unregister(FakeAITasks) end)
      :ok
    end

    test "explains each need and has the glossary", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/ai/tasks")

      assert [title | _] = attr(html, "[data-task-key='test.photo'] [data-need=vision]", "title")
      assert title == CapabilityBadges.explain_text(:vision)

      assert has_element?(view, "details#ai-tasks-capability-glossary")

      # The recommendations block's filters and its own glossary.
      photo = "[data-task-key='test.photo']"
      assert [filter_title | _] = attr(html, "#{photo} [data-filter=vision]", "title")
      assert filter_title == CapabilityBadges.explain_text(:vision)
      assert has_element?(view, "#{photo} details[id$='-recommendations-glossary']")
    end
  end
end
