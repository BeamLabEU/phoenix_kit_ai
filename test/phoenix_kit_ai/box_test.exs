defmodule PhoenixKitAI.BoxTest do
  use ExUnit.Case, async: false

  alias PhoenixKitAI.Box

  doctest PhoenixKitAI.Box

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :box_formats) end)
    :ok
  end

  describe "new/2" do
    test "reads [ymin, xmin, ymax, xmax] on the 0-1000 grid" do
      assert {:ok, %Box{x0: 0.2, y0: 0.1, x1: 0.6, y1: 0.5}} =
               Box.new([100, 200, 500, 600], :yx_1000)
    end

    test "reads [xmin, ymin, xmax, ymax] on the 0-1000 grid" do
      assert {:ok, %Box{x0: 0.1, y0: 0.2, x1: 0.5, y1: 0.6}} =
               Box.new([100, 200, 500, 600], :xy_1000)
    end

    test "reads fractions in both orders" do
      assert {:ok, %Box{x0: 0.1, y0: 0.2}} = Box.new([0.1, 0.2, 0.5, 0.6], :xy_fraction)
      assert {:ok, %Box{x0: 0.2, y0: 0.1}} = Box.new([0.1, 0.2, 0.5, 0.6], :yx_fraction)
    end

    test "clamps to the image and orders a reversed pair" do
      assert {:ok, %Box{x0: +0.0, y0: +0.0, x1: 1.0, y1: 0.5}} =
               Box.new([500, 1200, -40, -10], :yx_1000)
    end

    test "refuses a box with no area, the wrong shape or non-numbers" do
      assert :error = Box.new([0, 0, 0, 0], :yx_1000)
      assert :error = Box.new([100, 100, 100, 900], :yx_1000)
      assert :error = Box.new([1, 2, 3], :yx_1000)
      assert :error = Box.new(["1", 2, 3, 4], :yx_1000)
      assert :error = Box.new(nil, :yx_1000)
      assert :error = Box.new([1, 2, 3, 4], :pixels)
      assert :error = Box.new([:erlang.bsl(1, 2000), 0, 1, 2], :yx_1000)
    end

    test "the smallest cell of the 0-1000 grid is a box" do
      assert {:ok, %Box{}} = Box.new([100, 100, 101, 101], :yx_1000)
    end
  end

  describe "format_for/2" do
    test "the default is what the prompts ask for" do
      assert Box.format_for("google/gemini-3.8-flash") == :yx_1000
      assert Box.format_for(nil) == :yx_1000
    end

    test "Qwen-VL writes x first" do
      assert Box.format_for("qwen/qwen3-vl-235b-a22b-instruct") == :xy_1000
      assert Box.format_for("Qwen/Qwen2.5-VL-72B-Instruct") == :xy_1000
    end

    test "a vendor prefix, none, or several do not hide the family" do
      assert Box.format_for("qwen3-vl-235b-a22b-instruct-2507") == :xy_1000
      assert Box.format_for("novita/qwen/qwen3-vl-235b-a22b-instruct-2507") == :xy_1000
      assert Box.format_for("acme/new-vl") == :yx_1000
    end

    test "an unknown format in config does not hide a valid shorter prefix" do
      Application.put_env(:phoenix_kit_ai, :box_formats, %{
        "qwen/qwen3-vl-235b" => :nope,
        "qwen/" => :xy_fraction
      })

      assert Box.format_for("qwen/qwen3-vl-235b-a22b") == :xy_fraction
    end

    test "config wins over the built-in table, the longest prefix first" do
      Application.put_env(:phoenix_kit_ai, :box_formats, %{
        "qwen/" => :yx_1000,
        "qwen/qwen3-vl" => :xy_fraction
      })

      assert Box.format_for("qwen/qwen3-vl-8b") == :xy_fraction
      assert Box.format_for("qwen/qwen2.5-vl") == :yx_1000
    end

    test "a call's box_format wins; an unknown one is ignored" do
      assert Box.format_for("qwen/qwen3-vl-8b", box_format: :yx_1000) == :yx_1000
      assert Box.format_for("qwen/qwen3-vl-8b", box_format: :bogus) == :xy_1000
    end
  end

  describe "geometry" do
    setup do
      {:ok, a} = Box.new([0, 0, 0.5, 0.5], :xy_fraction)
      {:ok, b} = Box.new([0.25, 0.25, 0.75, 0.75], :xy_fraction)
      %{a: a, b: b}
    end

    test "area, center and iou", %{a: a, b: b} do
      assert Box.area(a) == 0.25
      assert Box.center(b) == {0.5, 0.5}
      assert_in_delta Box.iou(a, b), 0.0625 / (0.25 + 0.25 - 0.0625), 1.0e-9
      assert Box.iou(a, a) == 1.0
    end

    test "to_pixels pads inside the image", %{a: a, b: b} do
      assert Box.to_pixels(a, 1000, 800) == %{x: 0, y: 0, width: 500, height: 400}
      assert Box.to_pixels(b, 100, 100, pad: 0.1) == %{x: 20, y: 20, width: 60, height: 60}
      assert Box.to_pixels(a, 1000, 800, pad: 5) == %{x: 0, y: 0, width: 1000, height: 800}
    end

    test "to_map and from_map round-trip", %{b: b} do
      assert {:ok, ^b} = b |> Box.to_map() |> Box.from_map()
      assert {:ok, ^b} = Box.from_map(%{x0: 0.25, y0: 0.25, x1: 0.75, y1: 0.75})
      assert :error = Box.from_map(%{"x0" => 0.1})
    end
  end
end
