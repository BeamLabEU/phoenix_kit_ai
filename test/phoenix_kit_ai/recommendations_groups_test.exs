defmodule PhoenixKitAI.RecommendationsGroupsTest do
  @moduledoc """
  Recommendations by capability first, price second: the filters (images,
  documents, image generation; the task's needs by default), the groups
  «verified» (every need the model has, by its catalogue) and «possible»
  (no need it lacks, one at least nobody verified), and the models that
  look experimental (preview, beta, exp, a free variant, an alias, no
  price) kept apart. Catalogues are injected; no network.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAI.{Capabilities, Recommendations}
  alias PhoenixKitAI.Test.FakeAITasks

  @openrouter "https://openrouter.ai/api/v1"
  @anthropic "https://api.anthropic.com/v1"

  setup do
    :ok = ModuleRegistry.register(FakeAITasks)

    on_exit(fn ->
      :persistent_term.erase({PhoenixKitAI.Tasks, :registry})
      ModuleRegistry.unregister(FakeAITasks)
    end)

    :ok
  end

  defp caps(attrs) do
    struct(
      %Capabilities{
        vision: :yes,
        file_input: :no,
        image_output: :no,
        tools: :yes,
        json_schema: :yes,
        json: :yes,
        text_output: true,
        prompt_price: 1.0e-7,
        completion_price: 1.0e-7
      },
      attrs
    )
  end

  defp source(models, attrs \\ []) do
    Map.merge(
      %{base_url: @openrouter, kind: :openrouter, integration_uuid: nil, models: models},
      Map.new(attrs)
    )
  end

  defp ids(rows), do: Enum.map(rows, & &1.model)

  describe "the filters" do
    test "start from the task's needs among images, documents and image generation" do
      assert Recommendations.filterable() == [:vision, :file_input, :image_output]

      assert %{filters: [:vision]} = Recommendations.ranked("test.photo", catalogue: [])
      assert %{filters: [:file_input]} = Recommendations.ranked("test.documents", catalogue: [])
      assert %{filters: []} = Recommendations.ranked("test.plain", catalogue: [])
    end

    test "replace the task's own capability needs; its other needs stay" do
      # test.photo needs vision and a JSON schema.
      catalogue = [
        source([
          {"v/reader", caps(vision: :no, file_input: :yes)},
          {"v/reader-no-schema", caps(vision: :no, file_input: :yes, json_schema: :no)},
          {"v/looker", caps(vision: :yes)}
        ])
      ]

      assert %{verified: verified} =
               Recommendations.ranked("test.photo", catalogue: catalogue, filters: [:file_input])

      assert ids(verified) == ["v/reader"]
    end

    test "image generation lets in models that answer only in images" do
      catalogue = [
        source([
          {"v/painter", caps(image_output: :yes, text_output: false)},
          {"v/writer", caps(image_output: :no)}
        ])
      ]

      assert %{verified: [%{model: "v/painter"}]} =
               Recommendations.ranked("test.plain",
                 catalogue: catalogue,
                 filters: [:image_output]
               )

      # Without it an image-only model is no text model and is left out.
      assert %{verified: [%{model: "v/writer"}]} =
               Recommendations.ranked("test.plain", catalogue: catalogue)
    end
  end

  describe "the groups" do
    test "verified, possible, and nothing for a model that lacks a need" do
      catalogue = [
        source([
          {"v/sees", caps(vision: :yes)},
          {"v/maybe", caps(vision: :unknown)},
          {"v/blind", caps(vision: :no)}
        ])
      ]

      assert %{verified: verified, possible: possible} =
               Recommendations.ranked("test.sized", catalogue: catalogue)

      assert ids(verified) == ["v/sees"]
      assert [%{model: "v/maybe", unverified: [:vision]}] = possible
      assert hd(verified).unverified == []
    end

    test "a provider without prices lands where its capabilities put it" do
      catalogue = [
        source([{"claude-sonnet", caps(prompt_price: nil, completion_price: nil)}],
          base_url: @anthropic,
          kind: :anthropic
        ),
        source([{"mistral-small", caps(vision: :unknown, prompt_price: nil)}],
          base_url: "https://api.mistral.ai/v1",
          kind: :mistral
        )
      ]

      assert %{verified: [%{model: "claude-sonnet"}], possible: [%{model: "mistral-small"}]} =
               Recommendations.ranked("test.sized", catalogue: catalogue)
    end

    test "inside a group the price comes second: cheapest first" do
      catalogue = [
        source([
          {"v/dear", caps(prompt_price: 3.0e-6, completion_price: 1.5e-5)},
          {"v/cheap", caps(prompt_price: 1.0e-7, completion_price: 4.0e-7)},
          {"v/dear-maybe", caps(vision: :unknown, prompt_price: 3.0e-6)},
          {"v/cheap-maybe", caps(vision: :unknown, prompt_price: 1.0e-8)}
        ])
      ]

      assert %{verified: verified, possible: possible} =
               Recommendations.ranked("test.sized", catalogue: catalogue)

      assert ids(verified) == ["v/cheap", "v/dear"]
      assert ids(possible) == ["v/cheap-maybe", "v/dear-maybe"]
    end
  end

  describe "experimental models" do
    test "previews, betas, exp, free variants, aliases and unpriced models are kept apart" do
      catalogue = [
        source([
          {"v/stable", caps([])},
          {"v/model-preview-09-2025", caps([])},
          {"v/model-beta", caps([])},
          {"v/gemini-exp-1206", caps([])},
          {"v/model:free", caps(prompt_price: 0.0, completion_price: 0.0)},
          {"~v/model-latest", caps([])},
          {"v/other-latest", caps([])},
          {"v/varies", caps(prompt_price: nil, completion_price: nil)},
          {"v/expert", caps([])}
        ])
      ]

      assert %{verified: verified, experimental: experimental} =
               Recommendations.ranked("test.sized", catalogue: catalogue, limit: 10)

      assert Enum.sort(ids(verified)) == ["v/expert", "v/stable"]

      assert Enum.sort(ids(experimental)) ==
               Enum.sort([
                 "v/model-preview-09-2025",
                 "v/model-beta",
                 "v/gemini-exp-1206",
                 "v/model:free",
                 "~v/model-latest",
                 "v/other-latest",
                 "v/varies"
               ])
    end

    test "an unverified experimental model says what is not verified" do
      catalogue = [source([{"v/thing-preview", caps(vision: :unknown)}])]

      assert %{experimental: [%{model: "v/thing-preview", unverified: [:vision]}], possible: []} =
               Recommendations.ranked("test.sized", catalogue: catalogue)
    end

    test "at most one free model among them" do
      catalogue = [
        source([
          {"v/a:free", caps(prompt_price: 0.0, completion_price: 0.0)},
          {"v/b:free", caps(prompt_price: 0.0, completion_price: 0.0)},
          {"v/c-preview", caps([])}
        ])
      ]

      assert %{experimental: experimental} =
               Recommendations.ranked("test.sized", catalogue: catalogue)

      assert ids(experimental) == ["v/a:free", "v/c-preview"]
    end

    test "a catalogue that lists no prices does not make its models experimental" do
      catalogue = [
        source([{"claude-opus-5", caps(prompt_price: nil, completion_price: nil)}],
          base_url: @anthropic,
          kind: :anthropic
        )
      ]

      assert %{verified: [%{model: "claude-opus-5"}], experimental: []} =
               Recommendations.ranked("test.sized", catalogue: catalogue)
    end
  end

  describe "refilter/2" do
    test "regroups for other filters from the catalogue the recommendations were built on" do
      catalogue = [
        source([
          {"v/sees", caps(vision: :yes, file_input: :no)},
          {"v/reads", caps(vision: :no, file_input: :yes)}
        ])
      ]

      recs = Recommendations.for_task("test.sized", catalogue: catalogue)
      assert %{filters: [:vision], verified: [%{model: "v/sees"}]} = recs
      # The catalogue is not kept in the result (a panel's state holds it).
      refute Map.has_key?(recs, :catalogue)

      assert %{filters: [:file_input], verified: [%{model: "v/reads"}]} =
               refiltered = Recommendations.refilter(recs, [:file_input], catalogue: catalogue)

      # The journal part and the estimate are kept.
      assert refiltered.worked == recs.worked
      assert refiltered.estimate == recs.estimate

      assert %{filters: [], verified: both} =
               Recommendations.refilter(recs, [], catalogue: catalogue)

      assert Enum.sort(ids(both)) == ["v/reads", "v/sees"]
    end

    test "ignores anything that is not a filterable capability" do
      recs = Recommendations.for_task("test.sized", catalogue: [])
      assert %{filters: [:image_output]} = Recommendations.refilter(recs, [:image_output, :tools])
    end
  end
end
