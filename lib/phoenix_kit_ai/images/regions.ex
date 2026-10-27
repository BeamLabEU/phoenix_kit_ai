defmodule PhoenixKitAI.Images.Regions do
  @moduledoc """
  The located half of the vision verbs: the JSON Schemas and prompt lines
  that ask a model *where* something is, and the parsing that turns its
  answer into `PhoenixKitAI.Box` structs.

  Used by `PhoenixKitAI.detect_regions/4`, `PhoenixKitAI.describe_image/3`
  with `regions:`, `PhoenixKitAI.extract_text/3` with `boxes: true` and
  `PhoenixKitAI.check_statements/4`. Nothing here calls a provider.

  Every box is asked for as `box_2d`, `[ymin, xmin, ymax, xmax]` on a
  0–1000 grid of the image it is on, and read back in the format the
  answering model actually writes (`PhoenixKitAI.Box.format_for/2`). A box
  the model got wrong in shape (not four numbers, no area left) is dropped
  and counted, never guessed at.
  """

  alias PhoenixKitAI.Box

  @box_2d %{
    "type" => "array",
    "items" => %{"type" => "number"},
    "description" =>
      "[ymin, xmin, ymax, xmax] of the box on its image, each 0-1000 (0,0 = top-left corner)"
  }

  @doc "The JSON Schema fragment of one box."
  @spec box_schema() :: map()
  def box_schema, do: @box_2d

  @doc "The prompt line that tells a model how to write `box_2d`."
  @spec box_instruction() :: String.t()
  def box_instruction,
    do:
      "Write every `box_2d` as [ymin, xmin, ymax, xmax], integers on a 0-1000 grid of the image " <>
        "the thing is on (0,0 is the top-left corner, 1000,1000 the bottom-right), tight around " <>
        "the thing itself."

  # ── Regions ──────────────────────────────────────────────────────────

  @doc """
  The schema of a list of located things. `labels` (a list of strings)
  limits `label` to those words; `nil` or `[]` leaves it free.
  """
  @spec regions_schema([String.t()] | nil) :: map()
  def regions_schema(labels \\ nil) do
    label =
      case labels do
        [_ | _] -> %{"type" => "string", "enum" => labels}
        _ -> %{"type" => "string", "description" => "What the thing is, in a few words"}
      end

    %{
      "type" => "array",
      "description" => "Every requested thing visible in the images, one entry per instance",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "label" => label,
          "description" => %{
            "type" => "string",
            "description" => "One short sentence telling this instance apart from the others"
          },
          "box_2d" => @box_2d,
          "image" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Which image it is on, 1 = the first"
          },
          "confidence" => %{
            "type" => "number",
            "minimum" => 0,
            "maximum" => 1,
            "description" => "How sure you are that it is there and correctly placed"
          }
        },
        "required" => ["label", "description", "box_2d", "image", "confidence"],
        "additionalProperties" => false
      }
    }
  end

  @doc "The whole answer schema of `detect_regions/4`."
  @spec detect_schema([String.t()] | nil) :: map()
  def detect_schema(labels) do
    %{
      "type" => "object",
      "properties" => %{"regions" => regions_schema(labels)},
      "required" => ["regions"],
      "additionalProperties" => false
    }
  end

  @doc """
  `schema` with a `regions` property added (or a schema of its own with a
  `description` and `regions` when `schema` is nil), for `describe_image/3`
  with `regions:`.
  """
  @spec with_regions(map() | nil, [String.t()] | nil) :: map()
  def with_regions(nil, labels) do
    %{
      "type" => "object",
      "properties" => %{
        "description" => %{"type" => "string", "description" => "The answer to the question"},
        "regions" => regions_schema(labels)
      },
      "required" => ["description", "regions"],
      "additionalProperties" => false
    }
  end

  def with_regions(%{} = schema, labels) do
    schema
    |> Map.put_new("type", "object")
    |> Map.put_new("properties", %{})
    |> put_in(["properties", "regions"], regions_schema(labels))
    |> Map.update("required", ["regions"], &Enum.uniq(&1 ++ ["regions"]))
  end

  @doc """
  The prompt of a search for `labels` (a list of what to find, or `nil` for
  every notable thing) in `count` images.
  """
  @spec detect_prompt([String.t()] | nil, non_neg_integer(), String.t() | nil) :: String.t()
  def detect_prompt(labels, count, instructions) do
    what =
      case labels do
        [_ | _] ->
          "Find every visible instance of: " <>
            Enum.map_join(labels, ", ", &~s("#{&1}")) <>
            ". Use exactly one of those words as each instance's `label`."

        _ ->
          "Find the notable things visible in the image — people, animals, objects, text " <>
            "areas, logos — and label each in a few words."
      end

    [
      what,
      "List each instance separately, even when several look alike. Report only what you can " <>
        "actually see: an empty `regions` list is a correct answer when nothing matches. Never " <>
        "place a box on something you are guessing at.",
      box_instruction(),
      images_line(count),
      instructions
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc "The prompt lines `describe_image/3` adds for `regions:`."
  @spec describe_regions_line([String.t()] | nil) :: String.t()
  def describe_regions_line(labels) do
    what =
      case labels do
        [_ | _] -> "Also locate every visible instance of: " <> Enum.join(labels, ", ") <> "."
        _ -> "Also locate the things your answer mentions."
      end

    what <> " Put them in `regions`, one entry per instance. " <> box_instruction()
  end

  @doc """
  The located things in a model's `regions` list, each
  `%{label, description, box, image, confidence}` with `box` a
  `PhoenixKitAI.Box`, plus how many entries were dropped because their box
  or label was unusable. `image` is 1-based and kept inside `image_count`.
  """
  @spec parse_regions(term(), String.t() | nil, pos_integer(), keyword()) ::
          {[map()], non_neg_integer()}
  def parse_regions(list, model, image_count, opts \\ [])

  def parse_regions(list, model, image_count, opts) when is_list(list) do
    format = Box.format_for(model, opts)

    {kept, dropped} =
      Enum.reduce(list, {[], 0}, fn entry, {kept, dropped} ->
        case region(entry, format, image_count) do
          {:ok, region} -> {[region | kept], dropped}
          :error -> {kept, dropped + 1}
        end
      end)

    {Enum.reverse(kept), dropped}
  end

  def parse_regions(_other, _model, _image_count, _opts), do: {[], 0}

  defp region(%{"box_2d" => raw} = entry, format, image_count) do
    with label when is_binary(label) and label != "" <- entry["label"],
         {:ok, box} <- Box.new(raw, format) do
      {:ok,
       %{
         label: label,
         description: if(is_binary(entry["description"]), do: entry["description"]),
         box: box,
         image: image_index(entry["image"], image_count),
         confidence: confidence(entry["confidence"])
       }}
    else
      _ -> :error
    end
  end

  defp region(_entry, _format, _image_count), do: :error

  # ── Text blocks ──────────────────────────────────────────────────────

  @doc "`extract_text/3`'s schema with a `box_2d` on every block."
  @spec text_schema_with_boxes(map()) :: map()
  def text_schema_with_boxes(schema) do
    case get_in(schema, ["properties", "blocks", "items"]) do
      %{} = items ->
        items =
          items
          |> Map.put_new("properties", %{})
          |> put_in(["properties", "box_2d"], @box_2d)
          |> Map.update("required", ["box_2d"], &Enum.uniq(&1 ++ ["box_2d"]))

        put_in(schema, ["properties", "blocks", "items"], items)

      _ ->
        schema
    end
  end

  @doc "The prompt line `extract_text/3` adds for `boxes: true`."
  @spec text_boxes_line() :: String.t()
  def text_boxes_line,
    do: "Give every block a `box_2d` around its text on the image it is on. " <> box_instruction()

  @doc """
  The box of each raw block in `raw_blocks`, in order: a `PhoenixKitAI.Box`
  or `nil` when the block had none or an unusable one, plus the count of
  unusable ones.
  """
  @spec block_boxes(term(), String.t() | nil, keyword()) :: {[Box.t() | nil], non_neg_integer()}
  def block_boxes(raw_blocks, model, opts \\ [])

  def block_boxes(raw_blocks, model, opts) when is_list(raw_blocks) do
    format = Box.format_for(model, opts)

    raw_blocks
    |> Enum.filter(&is_map/1)
    |> Enum.map_reduce(0, fn block, bad ->
      case Box.new(block["box_2d"], format) do
        {:ok, box} -> {box, bad}
        :error -> {nil, if(Map.has_key?(block, "box_2d"), do: bad + 1, else: bad)}
      end
    end)
  end

  def block_boxes(_other, _model, _opts), do: {[], 0}

  # ── Statements ───────────────────────────────────────────────────────

  @statements_schema %{
    "type" => "object",
    "properties" => %{
      "results" => %{
        "type" => "array",
        "description" => "One entry per numbered statement, in order",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "n" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "The statement's number"
            },
            "verdict" => %{
              "type" => "string",
              "enum" => ["supported", "contradicted", "insufficient"]
            },
            "evidence" => %{
              "type" => "string",
              "description" =>
                "What the images show that decides it, in your own words; for insufficient, what is missing"
            },
            "image" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "The image that decides it, 1 = the first; 0 when none does"
            },
            "box_2d" => @box_2d
          },
          "required" => ["n", "verdict", "evidence", "image", "box_2d"],
          "additionalProperties" => false
        }
      }
    },
    "required" => ["results"],
    "additionalProperties" => false
  }

  @doc "The answer schema of `check_statements/4`."
  @spec statements_schema() :: map()
  def statements_schema, do: @statements_schema

  @doc "The prompt of `check_statements/4` for the numbered `texts`."
  @spec statements_prompt([String.t()], non_neg_integer(), String.t() | nil) :: String.t()
  def statements_prompt(texts, count, instructions) do
    [
      "You check statements against images. The images are the only authority: do not use " <>
        "anything you know about the subject from elsewhere.",
      "For each numbered statement decide:\n" <>
        "- supported: the images show what the statement says. Different wording, a summary, " <>
        "or a missing minor detail is still supported.\n" <>
        "- contradicted: the images show something that makes the statement false in a way " <>
        "that matters (a different person, object, action, number or outcome).\n" <>
        "- insufficient: the images neither show nor rule it out.",
      "Judge the substance, not the phrasing; do not reject a statement over a technicality. " <>
        "Give the image that decides it and a `box_2d` around the deciding detail; for " <>
        "insufficient, image 0 and box_2d [0, 0, 0, 0].",
      box_instruction(),
      images_line(count),
      instructions,
      "STATEMENTS:\n" <>
        (texts |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, i} -> "#{i}. #{t}" end))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  `check_statements/4`'s results from the model's answer: one per
  statement, in order. A statement the model skipped is `:insufficient`
  with `answered: false`.
  """
  @spec parse_statements(term(), [map()], String.t() | nil, pos_integer(), keyword()) :: [map()]
  def parse_statements(json, statements, model, image_count, opts \\ []) do
    format = Box.format_for(model, opts)

    by_n =
      case json do
        %{"results" => list} when is_list(list) ->
          for %{"n" => n} = r <- list, is_integer(n), into: %{}, do: {n, r}

        _ ->
          %{}
      end

    statements
    |> Enum.with_index(1)
    |> Enum.map(fn {statement, n} ->
      statement_result(statement, by_n[n], format, image_count)
    end)
  end

  defp statement_result(%{id: id, text: text}, nil, _format, _image_count) do
    %{
      id: id,
      statement: text,
      verdict: :insufficient,
      evidence: nil,
      image: nil,
      box: nil,
      answered: false
    }
  end

  defp statement_result(%{id: id, text: text}, answer, format, image_count) do
    verdict = verdict(answer["verdict"])

    image =
      if verdict == :insufficient, do: nil, else: image_index(answer["image"], image_count, nil)

    %{
      id: id,
      statement: text,
      verdict: verdict,
      evidence: if(is_binary(answer["evidence"]), do: answer["evidence"]),
      image: image,
      box: if(image, do: box_or_nil(answer["box_2d"], format)),
      answered: true
    }
  end

  defp box_or_nil(raw, format) do
    case Box.new(raw, format) do
      {:ok, box} -> box
      :error -> nil
    end
  end

  defp verdict("supported"), do: :supported
  defp verdict("contradicted"), do: :contradicted
  defp verdict(_other), do: :insufficient

  # ── Shared ───────────────────────────────────────────────────────────

  defp images_line(count) when count > 1,
    do: "There are #{count} images; `image` numbers them from 1 in the order given."

  defp images_line(_count), do: nil

  defp image_index(value, count, default \\ 1)
  defp image_index(n, count, _default) when is_integer(n) and n >= 1 and n <= count, do: n
  defp image_index(_n, 1, default) when default != nil, do: 1
  defp image_index(_n, _count, default), do: default

  defp confidence(c) when is_number(c) and c >= 0 and c <= 1, do: c / 1
  defp confidence(_c), do: nil
end
