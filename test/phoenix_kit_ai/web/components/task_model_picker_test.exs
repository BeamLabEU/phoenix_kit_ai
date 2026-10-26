defmodule PhoenixKitAI.Web.Components.TaskModelPickerTest do
  @moduledoc """
  The shared model picker for consumers: the enabled endpoints with a
  fitness badge each (✓ / ✗ / ?), and the collapsible recommendations panel
  with the create-endpoint button, shown only to a scope holding `ai`.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Web.Components.CapabilityBadges
  alias PhoenixKitAI.Web.Components.TaskModelPicker

  setup do
    :ok = ModuleRegistry.register(FakeAITasks)
    # The create link's ai.manage_endpoints check resolves through the registry.
    :ok = ModuleRegistry.register(PhoenixKitAI)

    on_exit(fn ->
      :persistent_term.erase({PhoenixKitAI.Tasks, :registry})
      ModuleRegistry.unregister(PhoenixKitAI)
      ModuleRegistry.unregister(FakeAITasks)
    end)

    :ok
  end

  defp declared_endpoint(name, flags, attrs \\ %{}) do
    model = "vendor/#{System.unique_integer([:positive])}"

    fixture_endpoint(
      Map.merge(
        %{
          name: name,
          model: model,
          provider_settings: %{"capabilities" => Map.put(flags, "model", model)}
        },
        attrs
      )
    )
  end

  defp field(value, name \\ "endpoint_uuid", as \\ :settings) do
    Phoenix.Component.to_form(%{name => value}, as: as)[String.to_existing_atom(name)]
  end

  defp scope(permissions),
    do: %Scope{
      user: %{uuid: Ecto.UUID.generate()},
      authenticated?: true,
      cached_roles: ["Admin"],
      cached_permissions: MapSet.new(permissions)
    }

  defp recs(overrides \\ %{}) do
    Map.merge(
      %{
        spec: %PhoenixKitAI.TaskSpec{key: "test.photo", needs: [:vision, :json_schema]},
        filters: [:vision],
        estimate: :declared,
        tokens: {10_000, 1_000},
        possible: [],
        experimental: [],
        verified: [
          %{
            model: "google/gemini-flash",
            name: "Gemini Flash",
            provider: :openrouter,
            base_url: "https://openrouter.ai/api/v1",
            integration_uuid: "0191-int",
            source_endpoint_uuid: "0191-source",
            context_length: 1_000_000,
            price_per_call: 0.0014,
            price_known?: true,
            input_price_per_million: 0.1,
            deprecated?: false,
            capabilities: %Capabilities{vision: :yes, tools: :yes, json_schema: :unknown},
            notes: [:alias, :free]
          },
          %{
            model: "claude-sonnet",
            name: "Claude Sonnet",
            provider: :anthropic,
            base_url: "https://api.anthropic.com/v1",
            integration_uuid: nil,
            context_length: 200_000,
            price_per_call: nil,
            price_known?: false,
            input_price_per_million: nil,
            deprecated?: true,
            capabilities: %Capabilities{vision: :yes, tools: :yes, json_schema: :no},
            notes: [:cost_not_reported, :json_schema_openrouter_only]
          }
        ],
        worked: [
          %{
            model: "google/gemini-flash",
            provider: "openrouter",
            calls: 12,
            # dollars
            avg_cost: Decimal.new("0.0015"),
            error_share: 0.25,
            avg_latency_ms: 840.0,
            cost_reported?: true,
            notes: []
          },
          %{
            model: "claude-sonnet",
            provider: nil,
            calls: 3,
            avg_cost: nil,
            error_share: 0.0,
            avg_latency_ms: 1200.0,
            cost_reported?: false,
            notes: []
          }
        ]
      },
      overrides
    )
  end

  defp render_picker(assigns) do
    render_component(
      &TaskModelPicker.picker/1,
      Map.merge(%{task: "test.photo", field: field(nil), recommendations: recs()}, assigns)
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp present?(html, selector), do: doc(html) |> LazyHTML.query(selector) |> Enum.any?()

  describe "the selector" do
    test "lists the enabled endpoints, each with its fitness" do
      fit = declared_endpoint("Fit EP", %{"vision" => "yes", "json_schema" => "yes"})
      unfit = declared_endpoint("Unfit EP", %{"vision" => "no", "json_schema" => "yes"})
      unknown = fixture_endpoint(name: "Unknown EP")
      off = declared_endpoint("Off EP", %{"vision" => "yes"}, %{enabled: false})

      html = render_picker(%{field: field(fit.uuid)})
      select = doc(html) |> LazyHTML.query("select")
      options = LazyHTML.query(select, "option")

      texts = Enum.map(options, &(&1 |> LazyHTML.text() |> String.trim()))
      assert Enum.any?(texts, &(&1 =~ "Fit EP" and &1 =~ "✓"))
      assert Enum.any?(texts, &(&1 =~ "Unfit EP" and &1 =~ "✗" and &1 =~ "no images"))
      assert Enum.any?(texts, &(&1 =~ "Unknown EP" and &1 =~ "?" and &1 =~ "not verified"))
      refute Enum.any?(texts, &(&1 =~ "Off EP"))

      values = Enum.flat_map(options, &LazyHTML.attribute(&1, "value"))
      assert fit.uuid in values and unfit.uuid in values and unknown.uuid in values
      refute off.uuid in values

      assert present?(html, "option[value='#{fit.uuid}'][selected]")
    end

    test "the field name is the consumer's" do
      html = render_picker(%{field: field(nil, "endpoint_uuid", :photo_settings)})
      assert present?(html, "select[name='photo_settings[endpoint_uuid]']")
    end

    test "the options and the chosen endpoint say what the model can do" do
      ep =
        declared_endpoint("Seer", %{"vision" => "yes", "tools" => "yes", "json_schema" => "yes"})

      html = render_picker(%{field: field(ep.uuid)})

      option = doc(html) |> LazyHTML.query("option[value='#{ep.uuid}']") |> LazyHTML.text()
      assert option =~ "images" and option =~ "tools"
      assert present?(html, "[data-task-model-picker] [data-capability=vision][data-state=yes]")
    end

    test "badges the chosen endpoint under the selector" do
      unfit = declared_endpoint("Unfit EP", %{"vision" => "no", "json_schema" => "yes"})

      html = render_picker(%{field: field(unfit.uuid)})

      assert present?(html, "[data-selected-fitness=unfit]")
      refute present?(html, "[data-selected-fitness=fit]")

      assert present?(render_picker(%{field: field(nil)}), "[data-selected-fitness]") == false
    end
  end

  describe "the recommendations panel" do
    test "is collapsed and lists the models that can do it and the ones that worked" do
      html = render_picker(%{})

      assert present?(html, "details[id$='-recommendations']:not([open])")

      assert present?(html, "[data-recommended-model='google/gemini-flash']")
      assert present?(html, "[data-recommended-model='claude-sonnet']")
      assert present?(html, "[data-worked-model='google/gemini-flash']")

      cheapest = doc(html) |> LazyHTML.query("[data-recommended-model='google/gemini-flash']")
      assert LazyHTML.text(cheapest) =~ "Gemini Flash"
      assert LazyHTML.text(cheapest) =~ "$0.0014"
      assert LazyHTML.text(cheapest) =~ "1,000,000"

      claude = doc(html) |> LazyHTML.query("[data-recommended-model='claude-sonnet']")
      assert LazyHTML.text(claude) =~ "price not known"

      assert present?(
               html,
               "[data-recommended-model='claude-sonnet'] [data-lifecycle=deprecated]"
             )

      assert present?(
               html,
               "[data-recommended-model='claude-sonnet'] [data-note=cost_not_reported]"
             )

      assert present?(
               html,
               "[data-recommended-model='claude-sonnet'] [data-note=json_schema_openrouter_only]"
             )

      assert present?(html, "[data-recommended-model='google/gemini-flash'] [data-note=alias]")

      worked = doc(html) |> LazyHTML.query("[data-worked-model='google/gemini-flash']")
      text = LazyHTML.text(worked)
      assert text =~ "12"
      assert text =~ "25%"
      assert text =~ "840"
      assert text =~ "$0.0015"
    end

    test "stays open when the page re-renders" do
      html = render_picker(%{})
      assert present?(html, "details[id$='-recommendations'][phx-mounted]")
    end

    test "shows the capability badges of each recommended model and a free one's caveat" do
      html = render_picker(%{})
      row = "[data-recommended-model='google/gemini-flash']"

      # No endpoint has the model yet: nothing to mark, so the hint only says so.
      assert [title] =
               doc(html)
               |> LazyHTML.query("#{row} [data-capability=json_schema][data-state=unknown]")
               |> LazyHTML.attribute("title")

      assert String.ends_with?(title, "Not verified")

      assert present?(html, "#{row} [data-capability=vision][data-state=yes]")
      assert present?(html, "#{row} [data-capability=tools]")
      assert present?(html, "#{row} [data-capability=json_schema][data-state=unknown]")
      assert present?(html, "#{row} [data-note=free]")

      claude = "[data-recommended-model='claude-sonnet']"
      refute present?(html, "#{claude} [data-capability=json_schema]")
    end

    test "names the operator of the models that worked" do
      html = render_picker(%{})
      worked = doc(html) |> LazyHTML.query("[data-worked-model='google/gemini-flash']")
      assert LazyHTML.text(worked) =~ "OpenRouter"
    end

    test "a rough estimate shows the input price per million tokens and says so" do
      rough =
        recs(%{
          estimate: :rough,
          tokens: nil,
          verified: [%{hd(recs().verified) | price_per_call: nil}],
          worked: []
        })

      html = render_picker(%{recommendations: rough})

      assert present?(html, "[data-estimate=rough]")
      assert LazyHTML.text(doc(html) |> LazyHTML.query("[data-recommended-model]")) =~ "$0.10"
      refute present?(html, "[data-worked-model]")
      assert present?(html, "[data-worked-empty]")
    end

    test "says so when nothing fits" do
      html = render_picker(%{recommendations: recs(%{verified: [], worked: []})})
      assert present?(html, "[data-recommended-empty]")
    end

    test "computes the recommendations itself when none are passed" do
      html = render_component(&TaskModelPicker.picker/1, %{task: "test.photo", field: field(nil)})
      assert present?(html, "[data-recommended-empty]")
      assert present?(html, "[data-worked-empty]")
    end

    test "ids are unique per instance" do
      a = render_picker(%{field: field(nil, "endpoint_uuid", :first)})
      b = render_picker(%{field: field(nil, "endpoint_uuid", :second)})

      ids = fn html ->
        doc(html) |> LazyHTML.query("[id]") |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
      end

      assert ids.(a) == Enum.uniq(ids.(a))
      assert ids.(a) -- ids.(b) == ids.(a)
    end
  end

  describe "translations" do
    test "the panel speaks the module's other locales" do
      on_exit(fn -> Gettext.put_locale(PhoenixKitAI.Gettext, "en") end)

      for {locale, expected} <- [
            {"ru",
             [
               "Умеют всё нужное (проверено)",
               "Должна уметь:",
               "Модели, использованные в этой задаче",
               "цена не известна",
               "бесплатная — лимиты"
             ]},
            {"et",
             [
               "Oskavad kõike vajalikku (kontrollitud)",
               "Selles ülesandes kasutatud mudelid",
               "hind pole teada"
             ]}
          ] do
        Gettext.put_locale(PhoenixKitAI.Gettext, locale)
        html = render_picker(%{scope: scope(["ai"])})

        for text <- expected, do: assert(html =~ text, "#{locale}: #{text}")
      end
    end
  end

  describe "capability badges component" do
    test "renders the endpoint form's badges on its own" do
      html =
        render_component(&CapabilityBadges.badges/1, %{
          capabilities: %Capabilities{vision: :yes, tools: :unknown, json_schema: :no}
        })

      assert present?(html, "[data-capability=vision][data-state=yes]")
      assert present?(html, "[data-capability=tools][data-state=unknown]")
      refute present?(html, "[data-capability=json_schema]")
    end
  end

  describe "the create button" do
    test "is hidden without ai.manage_endpoints" do
      for scope <- [nil, scope(["staff"]), scope([]), scope(["ai"])] do
        html = render_picker(%{scope: scope})

        refute present?(html, "[data-create-endpoint]"),
               "shown for #{inspect(scope && scope.cached_permissions)}"
      end

      refute present?(render_picker(%{}), "[data-create-endpoint]")
    end

    test "links to the endpoint form with the model, the integration and a name" do
      html = render_picker(%{scope: scope(["ai", "ai.manage_endpoints"])})

      link =
        doc(html)
        |> LazyHTML.query(
          "[data-recommended-model='google/gemini-flash'] a[data-create-endpoint]"
        )

      [href] = LazyHTML.attribute(link, "href")
      assert %URI{path: path, query: query} = URI.parse(href)
      assert path =~ "/admin/ai/endpoints/new"

      assert URI.decode_query(query) == %{
               "model" => "google/gemini-flash",
               "integration_uuid" => "0191-int",
               "source_endpoint_uuid" => "0191-source",
               "provider" => "openrouter",
               "name" => "Gemini Flash"
             }
    end

    test "is shown for a model with no known integration too, without one in the link" do
      html = render_picker(%{scope: scope(["ai", "ai.manage_endpoints"])})

      [href] =
        doc(html)
        |> LazyHTML.query("[data-recommended-model='claude-sonnet'] a[data-create-endpoint]")
        |> LazyHTML.attribute("href")

      refute URI.decode_query(URI.parse(href).query) |> Map.has_key?("integration_uuid")
    end

    test "the owner's wildcard grant counts" do
      html = render_picker(%{scope: scope(["*"])})
      assert present?(html, "a[data-create-endpoint]")
    end
  end
end
