defmodule PhoenixKitAI.Images.RegionsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Box
  alias PhoenixKitAI.Images.Regions

  describe "parse_regions/4" do
    test "keeps well-formed entries and counts the rest" do
      list = [
        %{
          "label" => "logo",
          "description" => "red logo",
          "box_2d" => [100, 200, 300, 400],
          "image" => 2,
          "confidence" => 0.9
        },
        %{
          "label" => "logo",
          "description" => "no area",
          "box_2d" => [100, 200, 100, 400],
          "image" => 1,
          "confidence" => 0.5
        },
        %{"label" => "", "box_2d" => [1, 1, 500, 500]},
        %{"label" => "price tag", "box_2d" => "nope"},
        "not a map"
      ]

      assert {[region], 4} = Regions.parse_regions(list, "google/gemini-3.8-flash", 2)
      assert %{label: "logo", description: "red logo", image: 2, confidence: 0.9} = region
      assert %Box{x0: 0.2, y0: 0.1, x1: 0.4, y1: 0.3} = region.box
    end

    test "reads the boxes the way the answering model writes them" do
      list = [
        %{
          "label" => "cat",
          "description" => "",
          "box_2d" => [100, 200, 300, 400],
          "image" => 1,
          "confidence" => 1
        }
      ]

      assert {[%{box: %Box{x0: 0.1, y0: 0.2}}], 0} =
               Regions.parse_regions(list, "qwen/qwen3-vl-30b-a3b", 1)

      assert {[%{box: %Box{x0: 0.2, y0: 0.1}}], 0} =
               Regions.parse_regions(list, "google/gemini-2.5-flash", 1)
    end

    test "with several images, a region on an image that does not exist is dropped, not moved" do
      list = [
        %{"label" => "cat", "box_2d" => [1, 1, 500, 500], "image" => 9, "confidence" => 0.5},
        %{"label" => "cat", "box_2d" => [1, 1, 500, 500], "image" => 2.0, "confidence" => 0.5},
        %{"label" => "cat", "box_2d" => [1, 1, 500, 500], "image" => 3, "confidence" => 7}
      ]

      assert {[%{image: 3, confidence: nil, description: nil}], 2} =
               Regions.parse_regions(list, nil, 3)
    end

    test "with one image, every region is on it" do
      list = [
        %{"label" => "cat", "box_2d" => [1, 1, 500, 500], "image" => 9, "confidence" => 0.5}
      ]

      assert {[%{image: 1}], 0} = Regions.parse_regions(list, nil, 1)
    end

    test "anything but a list is no regions" do
      assert {[], 0} = Regions.parse_regions(nil, nil, 1)
    end
  end

  describe "schemas" do
    test "labels become an enum" do
      assert %{"items" => %{"properties" => %{"label" => %{"enum" => ["a", "b"]}}}} =
               Regions.regions_schema(["a", "b"])

      assert %{"items" => %{"properties" => %{"label" => %{"type" => "string"} = free}}} =
               Regions.regions_schema(nil)

      refute Map.has_key?(free, "enum")
    end

    test "with_regions adds the property to a caller's schema and requires it" do
      schema = %{
        "type" => "object",
        "properties" => %{"colour" => %{"type" => "string"}},
        "required" => ["colour"]
      }

      out = Regions.with_regions(schema, nil)
      assert Map.has_key?(out["properties"], "regions")
      assert out["required"] == ["colour", "regions"]
    end

    test "text blocks get a box_2d" do
      schema = Regions.text_schema_with_boxes(PhoenixKitAI.Images.text_schema())
      items = schema["properties"]["blocks"]["items"]
      assert Map.has_key?(items["properties"], "box_2d")
      assert "box_2d" in items["required"]
    end
  end

  describe "block_boxes/3" do
    test "one entry per map block, nil where there is no usable box" do
      blocks = [
        %{"text" => "A", "box_2d" => [0, 0, 100, 100]},
        %{"text" => "B"},
        %{"text" => "C", "box_2d" => [5, 5, 5, 5]},
        "skip"
      ]

      assert {[%Box{}, nil, nil], 1} = Regions.block_boxes(blocks, nil)
    end
  end

  describe "parse_statements/5" do
    setup do
      %{
        statements: [
          %{id: :a, text: "red sofa"},
          %{id: :b, text: "two cats"},
          %{id: :c, text: "a lamp"}
        ]
      }
    end

    test "maps verdicts back to the caller's ids, skipped ones insufficient", %{statements: st} do
      json = %{
        "results" => [
          %{
            "n" => 1,
            "verdict" => "supported",
            "evidence" => "a red sofa",
            "image" => 1,
            "box_2d" => [100, 100, 500, 500]
          },
          %{
            "n" => 2,
            "verdict" => "contradicted",
            "evidence" => "one cat",
            "image" => 0,
            "box_2d" => [0, 0, 0, 0]
          }
        ]
      }

      assert [a, b, c] = Regions.parse_statements(json, st, "google/gemini-3.8-flash", 1)
      assert %{id: :a, verdict: :supported, image: 1, box: %Box{}, answered: true} = a
      assert %{id: :b, verdict: :contradicted, image: nil, box: nil} = b
      assert %{id: :c, verdict: :insufficient, answered: false, evidence: nil} = c
    end

    test "an unknown verdict is insufficient and loses its pointer", %{statements: st} do
      json = %{
        "results" => [
          %{
            "n" => 1,
            "verdict" => "maybe",
            "evidence" => "?",
            "image" => 1,
            "box_2d" => [1, 1, 500, 500]
          }
        ]
      }

      assert [%{verdict: :insufficient, image: nil, box: nil, answered: true} | _] =
               Regions.parse_statements(json, st, nil, 1)
    end

    test "a non-map answer leaves every statement unanswered", %{statements: st} do
      assert Enum.all?(Regions.parse_statements(nil, st, nil, 1), &(&1.answered == false))
    end
  end

  describe "prompts" do
    test "the detect prompt names the labels and says an empty list is fine" do
      prompt = Regions.detect_prompt(["logo", "price tag"], 2, "Ignore the background.")
      assert prompt =~ ~s("logo", "price tag")
      assert prompt =~ "empty `regions` list is a correct answer"
      assert prompt =~ "There are 2 images"
      assert prompt =~ "Ignore the background."
    end

    test "the statements prompt numbers the statements, warns against technicalities and against half-shown claims" do
      prompt = Regions.statements_prompt(["one", "two"], 1, nil)
      assert prompt =~ "1. one\n2. two"
      assert prompt =~ "technicality"
      assert prompt =~ "adds something the images do not show"
      refute prompt =~ "missing minor detail"
    end
  end
end
