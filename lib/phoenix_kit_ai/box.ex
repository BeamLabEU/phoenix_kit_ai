defmodule PhoenixKitAI.Box do
  @moduledoc """
  A rectangle on an image, the one shape every region-returning verb hands
  back (`detect_regions/4`, `describe_image/3` with `regions:`,
  `extract_text/3` with `boxes: true`, `check_statements/4`).

  Coordinates are fractions of the image the model was given, `0.0..1.0`,
  measured from the top-left corner: `x0`/`y0` is the top-left corner of the
  box, `x1`/`y1` the bottom-right, with `x0 < x1` and `y0 < y1`. Core's
  `PhoenixKit.Modules.Storage.FocalPoint` uses the same frame, so a box's
  `center/1` is a focal point as it is. `to_pixels/3` turns a box into a pixel
  rectangle for a crop.

  ## Model formats

  Models do not agree on how they write a box, and a prompt does not decide
  it: the field test behind this module asked every model for
  `[ymin, xmin, ymax, xmax]` on a 0–1000 grid, and Qwen-VL answered
  `[xmin, ymin, xmax, ymax]` on every page. So the conversion is chosen by
  the model that answered, never guessed from the numbers:

  * `:yx_1000` — `[ymin, xmin, ymax, xmax]`, 0–1000 (Gemini's native form,
    and what the prompts ask for; the default)
  * `:xy_1000` — `[xmin, ymin, xmax, ymax]`, 0–1000 (Qwen-VL)
  * `:xy_fraction` — `[xmin, ymin, xmax, ymax]`, 0–1
  * `:yx_fraction` — `[ymin, xmin, ymax, xmax]`, 0–1

  `format_for/1` picks one for a model id: a call's `box_format:` wins, then
  `config :phoenix_kit_ai, box_formats: %{"some/model-prefix" => :xy_1000}`
  (longest matching prefix), then the built-in table, then `:yx_1000`.
  """

  require Logger

  @enforce_keys [:x0, :y0, :x1, :y1]
  defstruct [:x0, :y0, :x1, :y1]

  @type t :: %__MODULE__{x0: float(), y0: float(), x1: float(), y1: float()}
  @type format :: :yx_1000 | :xy_1000 | :xy_fraction | :yx_fraction

  @formats [:yx_1000, :xy_1000, :xy_fraction, :yx_fraction]

  # Models whose answers do not follow the `[ymin, xmin, ymax, xmax]` the
  # prompts ask for. Matched as prefixes of the model id that answered.
  @builtin_formats %{
    "qwen/qwen2.5-vl" => :xy_1000,
    "qwen/qwen3-vl" => :xy_1000,
    "qwen/qwen-vl" => :xy_1000
  }

  # Below this area (a fraction of the image) a box is noise, not a region.
  @min_area 1.0e-6

  @doc "The formats `new/2` reads."
  @spec formats() :: [format()]
  def formats, do: @formats

  @doc """
  A box from four numbers in `format`. `{:ok, box}` or `:error` when the
  value is not four numbers or leaves nothing inside the image.

  Values outside the grid are clamped to it, a reversed pair is put in
  order, and a box that keeps no area after that is refused.

      iex> {:ok, box} = PhoenixKitAI.Box.new([100, 200, 500, 600], :yx_1000)
      iex> {box.x0, box.y0, box.x1, box.y1}
      {0.2, 0.1, 0.6, 0.5}
  """
  @spec new(term(), format()) :: {:ok, t()} | :error
  def new([a, b, c, d] = values, format) when format in @formats do
    if Enum.all?(values, &is_number/1) do
      scale = if format in [:yx_1000, :xy_1000], do: 1000, else: 1
      [a, b, c, d] = Enum.map([a, b, c, d], &clamp(&1 / scale))

      {x0, y0, x1, y1} =
        if format in [:yx_1000, :yx_fraction], do: {b, a, d, c}, else: {a, b, c, d}

      box = %__MODULE__{
        x0: min(x0, x1),
        y0: min(y0, y1),
        x1: max(x0, x1),
        y1: max(y0, y1)
      }

      if area(box) > @min_area, do: {:ok, box}, else: :error
    else
      :error
    end
  end

  def new(_value, _format), do: :error

  @doc """
  A box from a model's answer, in the format `format_for/2` picks for the
  model that answered. `:error` like `new/2`.
  """
  @spec from_model(term(), String.t() | nil, keyword()) :: {:ok, t()} | :error
  def from_model(value, model, opts \\ []), do: new(value, format_for(model, opts))

  @doc """
  The format a model writes its boxes in: the call's `box_format:`, then the
  `:box_formats` config (longest matching prefix of the model id), then the
  built-in table, then `:yx_1000`. An unknown format in config or on a call
  is ignored with a warning.
  """
  @spec format_for(String.t() | nil, keyword()) :: format()
  def format_for(model, opts \\ []) do
    case valid_format(opts[:box_format], :call) do
      nil -> configured_format(model) || :yx_1000
      format -> format
    end
  end

  defp configured_format(model) when is_binary(model) do
    configured =
      case Application.get_env(:phoenix_kit_ai, :box_formats, %{}) do
        map when is_map(map) -> map
        _ -> %{}
      end

    model = String.downcase(model)

    [configured, @builtin_formats]
    |> Enum.find_value(fn table ->
      table
      |> Enum.filter(fn {prefix, _} ->
        is_binary(prefix) and String.starts_with?(model, String.downcase(prefix))
      end)
      |> Enum.max_by(fn {prefix, _} -> String.length(prefix) end, fn -> nil end)
      |> case do
        nil -> nil
        {_prefix, format} -> valid_format(format, :config)
      end
    end)
  end

  defp configured_format(_model), do: nil

  defp valid_format(nil, _where), do: nil
  defp valid_format(format, _where) when format in @formats, do: format

  defp valid_format(other, where) do
    Logger.warning(
      "[PhoenixKitAI.Box] unknown box format #{inspect(other)} (#{where}) — expected one of #{inspect(@formats)}"
    )

    nil
  end

  @doc "The box's area as a fraction of the image (`0.0..1.0`)."
  @spec area(t()) :: float()
  def area(%__MODULE__{x0: x0, y0: y0, x1: x1, y1: y1}), do: (x1 - x0) * (y1 - y0)

  @doc "The box's center, `{x, y}` — a focal point in core Storage's frame."
  @spec center(t()) :: {float(), float()}
  def center(%__MODULE__{x0: x0, y0: y0, x1: x1, y1: y1}), do: {(x0 + x1) / 2, (y0 + y1) / 2}

  @doc "Intersection over union of two boxes, `0.0..1.0`."
  @spec iou(t(), t()) :: float()
  def iou(%__MODULE__{} = a, %__MODULE__{} = b) do
    ix = max(0.0, min(a.x1, b.x1) - max(a.x0, b.x0))
    iy = max(0.0, min(a.y1, b.y1) - max(a.y0, b.y0))
    inter = ix * iy
    union = area(a) + area(b) - inter
    if union > 0, do: inter / union, else: 0.0
  end

  @doc """
  The box as a pixel rectangle `%{x: left, y: top, width: w, height: h}` on an
  image of `width` × `height` pixels, padded on every side by `pad:` (a
  fraction of the box's own size, default `0`) and kept inside the image.
  Integers, at least one pixel wide and high.
  """
  @spec to_pixels(t(), pos_integer(), pos_integer(), keyword()) :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer()
        }
  def to_pixels(%__MODULE__{} = box, width, height, opts \\ [])
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    pad = Keyword.get(opts, :pad, 0)
    pw = (box.x1 - box.x0) * pad
    ph = (box.y1 - box.y0) * pad

    left = (clamp(box.x0 - pw) * width) |> floor()
    top = (clamp(box.y0 - ph) * height) |> floor()
    right = (clamp(box.x1 + pw) * width) |> ceil()
    bottom = (clamp(box.y1 + ph) * height) |> ceil()

    left = min(left, width - 1)
    top = min(top, height - 1)

    %{x: left, y: top, width: max(1, right - left), height: max(1, bottom - top)}
  end

  @doc "The box as a plain map with string keys, for JSON (`x0`, `y0`, `x1`, `y1`)."
  @spec to_map(t()) :: %{String.t() => float()}
  def to_map(%__MODULE__{x0: x0, y0: y0, x1: x1, y1: y1}),
    do: %{"x0" => x0, "y0" => y0, "x1" => x1, "y1" => y1}

  @doc "A box back from `to_map/1`'s shape (string or atom keys). `:error` when it is not one."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{} = map) do
    values =
      Enum.map([{"x0", :x0}, {"y0", :y0}, {"x1", :x1}, {"y1", :y1}], fn {s, a} ->
        Map.get(map, s, Map.get(map, a))
      end)

    new(values, :xy_fraction)
  end

  def from_map(_other), do: :error

  defp clamp(v) when v < 0, do: 0.0
  defp clamp(v) when v > 1, do: 1.0
  defp clamp(v), do: v / 1
end
