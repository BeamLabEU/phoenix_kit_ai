defmodule PhoenixKitAI.Images.Operations do
  @moduledoc """
  The named image operations `PhoenixKitAI.Images.process/4` composes
  into one edit prompt.

  An operation is a prompt template plus, optionally, parameters it
  needs, request options it implies (a transparent cutout wants
  `background: "transparent"` and a PNG), a fallback template for when
  those options are not available on the model, presets for a
  parameter, and whether it needs reference images after the subject.

  ## Built-ins

  | operation | parameters | notes |
  |---|---|---|
  | `:instruction` | `text` | free text; a bare string in the list means this |
  | `:clean_background` | `color` (default `"white"`) | plain studio backdrop |
  | `:blur_background` | | shallow depth of field |
  | `:remove_background` | | transparent PNG; falls back to plain white |
  | `:replace_background` | `with` | described new background |
  | `:remove_reflections` | | glare and specular highlights |
  | `:remove_objects` | `what` | remove and fill |
  | `:enhance` | | exposure, white balance, sharpness |
  | `:upscale` | `resolution` (default `"2K"`) | asks for a bigger output |
  | `:relight` | `light` (preset atom or text) | `:day`, `:evening`, `:night`, `:studio`, `:golden_hour`, `:overcast` |
  | `:recolor` | `what`, `color` | one element's colour |
  | `:straighten` | | level horizon, vertical verticals |
  | `:crop_to_subject` | | tight crop, even margins |
  | `:restyle` | | needs reference images; borrows their materials and mood |

  ## Extending

  A host adds or overrides operations in config:

      config :phoenix_kit_ai, image_operations: %{
        product_shot: %{
          description: "Catalogue product shot",
          prompt: "Place the product on a seamless white sweep with soft studio light.",
          options: %{aspect_ratio: "1:1"}
        }
      }

  And an admin can override any operation's wording without a deploy:
  a saved prompt named `Image op <name>` — its slug, derived from the
  name, is `image-op-<name>` with dashes, e.g. a prompt called
  "Image op remove background" — replaces the built-in template; its
  `{{Variables}}` are filled from the operation's parameters.
  """

  alias PhoenixKitAI.Prompt

  @type name :: atom()
  @type params :: %{optional(atom()) => term()}
  @type spec :: %{
          required(:prompt) => String.t(),
          optional(:description) => String.t(),
          optional(:params) => [atom()],
          optional(:defaults) => params(),
          optional(:options) => map(),
          optional(:fallback_prompt) => String.t(),
          optional(:presets) => %{optional(atom()) => String.t()},
          optional(:references) => :none | :optional | :required
        }

  @relight_presets %{
    day:
      "bright midday: strong natural daylight through the windows, soft daylight shadows, every artificial light switched off",
    evening:
      "early evening: dusk outside with a warm low sun or blue-hour sky, the room's own lights switched on and warm",
    night:
      "night: dark outside, the scene lit only by its own lights — warm pools of light and darker corners",
    studio: "even, soft studio lighting with gentle shadows and no colour cast",
    golden_hour: "late golden-hour sunlight, warm and low, with long soft shadows",
    overcast: "soft, diffuse overcast daylight with no hard shadows"
  }

  @builtin %{
    instruction: %{
      description: "Free-form instruction",
      prompt: "{{text}}",
      params: [:text]
    },
    clean_background: %{
      description: "Plain studio background",
      prompt:
        "Replace the background with a clean, plain, evenly lit {{color}} studio backdrop, keeping a soft natural contact shadow under the subject.",
      params: [:color],
      defaults: %{color: "white"}
    },
    blur_background: %{
      description: "Blur the background",
      prompt:
        "Keep the subject perfectly sharp and blur the background softly, as a shallow depth of field would, without changing what is in it."
    },
    remove_background: %{
      description: "Cut out on a transparent background",
      prompt:
        "Cut the subject out cleanly along its true edges and make the background fully transparent.",
      options: %{background: "transparent", output_format: "png"},
      fallback_prompt:
        "Cut the subject out cleanly along its true edges and place it on a plain, pure white background."
    },
    replace_background: %{
      description: "Replace the background",
      prompt:
        "Replace the background with {{with}}. Match the lighting, perspective and scale so the subject looks naturally placed.",
      params: [:with]
    },
    remove_reflections: %{
      description: "Remove glare and reflections",
      prompt:
        "Remove glare, reflections and specular highlights from the subject's surfaces and packaging so the print, colours and texture underneath read clearly and evenly."
    },
    remove_objects: %{
      description: "Remove something",
      prompt:
        "Remove {{what}} from the image and fill the space naturally with the surrounding background.",
      params: [:what]
    },
    enhance: %{
      description: "Enhance the photo",
      prompt:
        "Improve the photograph's exposure, white balance, contrast and sharpness; remove noise and colour casts. Keep it realistic and true to the original colours."
    },
    upscale: %{
      description: "Upscale",
      prompt:
        "Reproduce this image at a higher resolution with more fine detail and no artefacts. Change nothing else.",
      params: [:resolution],
      defaults: %{resolution: "2K"},
      options: %{resolution: "2K"}
    },
    relight: %{
      description: "Change the lighting or time of day",
      prompt:
        "Change only the lighting and the time of day: {{light}}. Keep the room, camera, materials and every object exactly as they are.",
      params: [:light],
      presets: @relight_presets
    },
    recolor: %{
      description: "Recolour one element",
      prompt:
        "Change the colour of {{what}} to {{color}}; keep its material, texture, shape and everything else unchanged.",
      params: [:what, :color]
    },
    straighten: %{
      description: "Straighten",
      prompt:
        "Straighten the image so vertical edges are vertical and the horizon is level, cropping as little as possible."
    },
    crop_to_subject: %{
      description: "Crop to the subject",
      prompt: "Crop tightly to the subject with even margins on all sides."
    },
    restyle: %{
      description: "Restyle after reference images",
      prompt:
        "Image 1 is the subject. Every image after it is a style reference only: take its materials, colours, finish, lighting mood and overall palette and apply them to image 1. Do not copy the references' layout, objects, camera or room.",
      references: :required
    }
  }

  @doc "Every operation: built-ins under the host's `:image_operations`."
  @spec all() :: %{name() => spec()}
  def all do
    case Application.get_env(:phoenix_kit_ai, :image_operations, %{}) do
      extra when is_map(extra) -> Map.merge(@builtin, normalize_specs(extra))
      _ -> @builtin
    end
  end

  @doc "Operation names, built-ins first."
  @spec names() :: [name()]
  def names, do: Map.keys(@builtin) ++ (all() |> Map.keys() |> Kernel.--(Map.keys(@builtin)))

  @doc "One operation's spec."
  @spec fetch(name()) :: {:ok, spec()} | :error
  def fetch(name) when is_atom(name), do: Map.fetch(all(), name)
  def fetch(_name), do: :error

  @doc """
  Turns the caller's list into `[{name, params}]`.

  Accepts atoms (`:enhance`), tuples with keyword or map parameters
  (`{:relight, light: :night}`), bare strings (a free-form instruction),
  and `{:custom, "text"}`. Unknown names and missing parameters are
  errors before anything is sent.
  """
  @spec normalize([term()]) ::
          {:ok, [{name(), params()}]}
          | {:error, {:unknown_operation, term()} | {:missing_parameter, name(), atom()}}
  def normalize(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn op, {:ok, acc} ->
      case normalize_one(op) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  def normalize(operation), do: normalize([operation])

  defp normalize_one(text) when is_binary(text), do: normalize_one({:instruction, %{text: text}})

  defp normalize_one({:custom, text}) when is_binary(text),
    do: normalize_one({:instruction, %{text: text}})

  defp normalize_one(name) when is_atom(name), do: normalize_one({name, %{}})

  defp normalize_one({name, params}) when is_atom(name) and (is_list(params) or is_map(params)) do
    params = Map.new(params, fn {k, v} -> {to_atom(k), v} end)

    with {:ok, spec} <- fetch_or_error(name),
         params = Map.merge(Map.get(spec, :defaults, %{}), params),
         :ok <- check_params(name, spec, params) do
      {:ok, {name, params}}
    end
  end

  defp normalize_one(other), do: {:error, {:unknown_operation, other}}

  defp fetch_or_error(name) do
    case fetch(name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_operation, name}}
    end
  end

  defp check_params(name, spec, params) do
    spec
    |> Map.get(:params, [])
    |> Enum.find(fn key -> blank?(Map.get(params, key)) end)
    |> case do
      nil -> :ok
      key -> {:error, {:missing_parameter, name, key}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc "The request options the operations imply (later operations win)."
  @spec options([{name(), params()}]) :: map()
  def options(pairs) do
    Enum.reduce(pairs, %{}, fn {name, params}, acc ->
      spec_options =
        case fetch(name) do
          {:ok, spec} -> Map.get(spec, :options, %{})
          :error -> %{}
        end

      # A parameter that is also a request option (upscale's resolution,
      # say) overrides the spec's default for it.
      param_options =
        params |> Map.take(Map.keys(spec_options)) |> Map.reject(fn {_k, v} -> blank?(v) end)

      acc |> Map.merge(spec_options) |> Map.merge(param_options)
    end)
  end

  @doc "Whether any operation in the list needs reference images."
  @spec references_required?([{name(), params()}]) :: boolean()
  def references_required?(pairs) do
    Enum.any?(pairs, fn {name, _} ->
      match?({:ok, %{references: :required}}, fetch(name))
    end)
  end

  @doc """
  The sentence(s) for one operation. `fallback: true` picks the
  operation's fallback wording (its implied options were not available).
  A saved prompt whose slug is `image-op-<name>` (a prompt named
  "Image op <name>") overrides the template unless
  `prompt_overrides: false`.
  """
  @spec render(name(), params(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(name, params, opts \\ []) do
    with {:ok, spec} <- fetch_or_error(name) do
      params = resolve_presets(spec, params)

      template =
        override_template(name, opts) ||
          if(Keyword.get(opts, :fallback, false), do: spec[:fallback_prompt], else: nil) ||
          spec.prompt

      {:ok, fill(template, params)}
    end
  end

  defp resolve_presets(%{presets: presets}, params) when is_map(presets) do
    Map.new(params, fn
      {key, value} when is_atom(value) -> {key, Map.get(presets, value, Atom.to_string(value))}
      pair -> pair
    end)
  end

  defp resolve_presets(_spec, params), do: params

  defp override_template(name, opts) do
    if Keyword.get(opts, :prompt_overrides, true) do
      slug = "image-op-" <> (name |> Atom.to_string() |> String.replace("_", "-"))

      case safe_prompt(slug) do
        %Prompt{enabled: true, content: content} when is_binary(content) and content != "" ->
          content

        _ ->
          nil
      end
    end
  end

  # Prompt lookup must never take an edit down with it (no DB in a
  # unit test, a pool that is shutting down…).
  defp safe_prompt(slug) do
    PhoenixKitAI.get_prompt_by_slug(slug)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc false
  # `{{name}}` and `{{Name}}` both fill from the `:name` parameter.
  def fill(template, params) do
    Regex.replace(~r/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/, template, fn whole, key ->
      case lookup(params, key) do
        nil -> whole
        value -> to_string(value)
      end
    end)
  end

  defp lookup(params, key) do
    Enum.find_value(params, fn {k, v} ->
      if String.downcase(Atom.to_string(k)) == String.downcase(key), do: v
    end)
  end

  # Config may arrive with string keys and string parameter names
  # (runtime.exs from env, say); everything internal is atoms.
  defp normalize_specs(extra) do
    Map.new(extra, fn {name, spec} ->
      spec =
        spec
        |> Map.new(fn {k, v} -> {to_atom(k), v} end)
        |> Map.update(:params, [], fn params -> Enum.map(List.wrap(params), &to_atom/1) end)
        |> Map.update(:defaults, %{}, &atom_keys/1)
        |> Map.update(:options, %{}, &atom_keys/1)
        |> Map.update(:presets, %{}, &atom_keys/1)

      {to_atom(name), spec}
    end)
  end

  defp atom_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_atom(k), v} end)
  defp atom_keys(_other), do: %{}

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)
end
