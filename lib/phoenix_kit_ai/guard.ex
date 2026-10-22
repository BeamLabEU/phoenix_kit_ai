defmodule PhoenixKitAI.Guard do
  @moduledoc """
  The call-time check every provider-calling verb passes before its HTTP
  request: does the model behind the endpoint (or the call's `model:`
  override) have what the call and its task need.

  The needs of a call are its task's declared `needs` together with what
  the call itself shows (`implied_needs/2`):

  | verb | implied |
  |---|---|
  | `complete/3`, `ask/3`, `ask_with_prompt/4`, `complete_with_system_prompt/5` | `image_url` parts in the messages → `:vision`; `tools:` → `:tools`; `schema:` / `json:` → `:json` |
  | `describe_image/3` | `:vision`; `:json` with `schema:` / `json:` |
  | `extract_text/3`, `compare_images/4` | `:vision`, `:json` |
  | `embed/3`, `speak/3`, `generate_image/3`, `edit_image/4`, `process_image/4` | nothing (images given to a generation model are not vision) |

  A hard need (`:vision`, `:tools`, `:json_schema`) the model says no to
  refuses the call with `{:error, {:model_unfit, missing}}`. A need nobody
  knows about lets the call through, unless the module setting
  `ai_guard_verified_models_only` is on — then it refuses with
  `{:error, {:model_unverified, unclear}}`. `:json` is soft: a model without
  it gets the call (the schema is written into the prompt), and the usage
  row notes `guard_warnings: ["json"]`.

  With a hard `:tools` / `:json_schema` need, a call to OpenRouter asks it
  to route only to upstream providers that support every parameter sent
  (`provider: %{require_parameters: true}`): the catalogue's
  `supported_parameters` are a union over providers, so without it a fit
  model could still land on a provider that ignores the schema. The
  request parameters the model's catalogue entry does not list are then
  left out (the row notes them as `stripped_params`), since one of them
  would leave no provider at all. Without the model's parameter list in the
  cache (before the first catalogue read after a restart, or a model the
  catalogue lacks) the request goes as it did before: no flag, nothing left
  out.
  """

  require Logger

  alias PhoenixKitAI.{Capabilities, Endpoint, Tasks, TaskSpec}

  @verified_only_setting "ai_guard_verified_models_only"

  # Request options a `require_parameters` call may leave out, by the name
  # OpenRouter's `supported_parameters` uses. The ones that ARE the
  # requirement (`tools`, `response_format`) are never stripped, and neither
  # is `max_tokens`: without it the answer has no length cap, which costs
  # money — better the provider's refusal (`:no_provider_for_params`).
  @strippable %{
    temperature: "temperature",
    top_p: "top_p",
    top_k: "top_k",
    frequency_penalty: "frequency_penalty",
    presence_penalty: "presence_penalty",
    repetition_penalty: "repetition_penalty",
    stop: "stop",
    seed: "seed",
    tool_choice: "tool_choice",
    parallel_tool_calls: "parallel_tool_calls"
  }
  @reasoning_options [
    :reasoning_enabled,
    :reasoning_effort,
    :reasoning_max_tokens,
    :reasoning_exclude
  ]

  @type verb ::
          :complete
          | :embed
          | :speak
          | :generate_image
          | :edit_image
          | :process_image
          | :describe_image
          | :extract_text
          | :compare_images

  @type admission :: %{
          task: String.t() | nil,
          needs: [TaskSpec.need()],
          warnings: [String.t()],
          require_parameters: boolean(),
          supported_parameters: [String.t()] | nil,
          endpoint_uuid: String.t() | nil
        }

  @doc """
  What a call shows it needs, by verb (see the table above). `input` is the
  messages for `:complete`; other verbs ignore it.
  """
  @spec implied_needs(verb(), keyword(), term()) :: [TaskSpec.need()]
  def implied_needs(verb, opts, input \\ nil)

  def implied_needs(:complete, opts, messages) do
    []
    |> add_if(:vision, has_image_part?(messages))
    |> add_if(:tools, match?([_ | _], opts[:tools]))
    |> add_if(:json, json_requested?(opts))
  end

  def implied_needs(:describe_image, opts, _input),
    do: add_if([:vision], :json, json_requested?(opts))

  def implied_needs(verb, _opts, _input) when verb in [:extract_text, :compare_images],
    do: [:vision, :json]

  def implied_needs(_verb, _opts, _input), do: []

  @doc """
  The fitness part of the call-time check: `{:ok, admission}` when the
  model may take the call, `{:error, reason}` when it may not. `task` is
  the call's declaration (or nil); `implied` what the call shows.
  """
  @spec check(Endpoint.t(), keyword(), TaskSpec.t() | nil, [TaskSpec.need()]) ::
          {:ok, admission()} | {:error, term()}
  def check(%Endpoint{} = endpoint, opts, task, implied) do
    needs = Enum.uniq(task_needs(task) ++ implied)

    admission = %{
      task: task_key(opts),
      needs: needs,
      warnings: [],
      require_parameters: false,
      supported_parameters: nil,
      endpoint_uuid: endpoint.uuid
    }

    if needs == [] do
      {:ok, admission}
    else
      caps = Capabilities.for_endpoint(model_endpoint(endpoint, opts))

      with :ok <- check_fitness(caps, needs) do
        {:ok,
         %{
           admission
           | warnings: soft_warnings(caps, needs),
             require_parameters: require_parameters?(endpoint, needs, supported_parameters(caps)),
             supported_parameters: supported_parameters(caps)
         }}
      end
    end
  end

  defp check_fitness(caps, needs) do
    case Tasks.assess(caps, needs) do
      :fit ->
        :ok

      {:unfit, missing} ->
        {:error, {:model_unfit, missing}}

      {:unknown, unclear} ->
        if verified_only?(), do: {:error, {:model_unverified, unclear}}, else: :ok
    end
  end

  defp soft_warnings(caps, needs) do
    if :json in needs and Tasks.flag(caps, :json) == :no, do: ["json"], else: []
  end

  # Only with the model's own parameter list in hand: without it (before the
  # first catalogue read after a restart, or a model the catalogue lacks)
  # nothing could be left out, and a parameter of the endpoint's that no
  # provider takes would turn a call that works into a refusal.
  defp require_parameters?(_endpoint, _needs, nil), do: false

  defp require_parameters?(endpoint, needs, _params) do
    Enum.any?([:tools, :json_schema], &(&1 in needs)) and
      Capabilities.catalogue_kind(
        base_provider(endpoint.provider),
        Capabilities.resolved_base_url(endpoint)
      ) == :openrouter
  end

  defp supported_parameters(%Capabilities{supported_parameters: [_ | _] = params}),
    do: params

  defp supported_parameters(_caps), do: nil

  @doc """
  The call's request options for an admission that asks OpenRouter to
  require its parameters: `:require_parameters` set, and every option the
  model's catalogue entry does not list left out. Returns the options and
  the names left out. Without the flag (which is set only with a known
  parameter list) the options are returned as they are.
  """
  @spec require_parameters(keyword(), admission()) :: {keyword(), [String.t()]}
  def require_parameters(
        opts,
        %{require_parameters: true, supported_parameters: [_ | _] = params} = admission
      ) do
    {opts, stripped} =
      opts
      |> Keyword.put(:require_parameters, true)
      |> strip(params)

    Enum.each(stripped, &warn_stripped_once(admission[:endpoint_uuid], &1))
    {opts, stripped}
  end

  def require_parameters(opts, _admission), do: {opts, []}

  defp strip(opts, supported) do
    unsupported =
      for {key, name} <- @strippable,
          sent?(opts[key]),
          name not in supported,
          do: {key, name}

    reasoning? =
      Enum.any?(@reasoning_options, &sent?(opts[&1])) and "reasoning" not in supported

    drop = Keyword.keys(unsupported) ++ if(reasoning?, do: @reasoning_options, else: [])
    names = Enum.map(unsupported, &elem(&1, 1)) ++ if(reasoning?, do: ["reasoning"], else: [])

    {Keyword.drop(opts, drop), Enum.sort(names)}
  end

  # A legacy provider string may name a connection ("openrouter:work").
  defp base_provider(provider) when is_binary(provider), do: Endpoint.base_provider(provider)
  defp base_provider(provider), do: provider

  # What `Completion` leaves out of the body anyway is not "stripped".
  defp sent?(value), do: value not in [nil, []]

  # Once per endpoint and parameter per node, in the request cache's flags
  # table; the row's `stripped_params` records every time.
  defp warn_stripped_once(endpoint_uuid, name) do
    first? =
      try do
        :ets.insert_new(
          PhoenixKitAI.RequestCache.flags_table(),
          {{:stripped_param, endpoint_uuid, name}, true}
        )
      rescue
        ArgumentError -> false
      end

    if first? do
      Logger.warning(
        "[PhoenixKitAI] endpoint #{endpoint_uuid}: #{name} is left out of requests that need " <>
          "every parameter supported (the model's catalogue entry does not list it)"
      )
    end
  end

  @doc """
  What the guard adds to a call's usage row: the task, and the warnings and
  stripped parameters when there are any.
  """
  @spec row_metadata(admission() | nil, [String.t()]) :: map()
  def row_metadata(admission, stripped \\ [])

  def row_metadata(nil, _stripped), do: %{}

  def row_metadata(admission, stripped) do
    %{}
    |> put_present(:task, admission.task)
    |> put_present(:guard_warnings, admission.warnings)
    |> put_present(:stripped_params, stripped)
  end

  @doc "`%{task: key}` for a call that names a task, `%{}` otherwise — for a row written before any admission."
  @spec task_metadata(keyword()) :: map()
  def task_metadata(opts) do
    case task_key(opts) do
      nil -> %{}
      key -> %{task: key}
    end
  end

  @doc "Whether a call with an unknown capability is refused (module setting, default off)."
  @spec verified_only?() :: boolean()
  def verified_only? do
    PhoenixKit.Settings.get_boolean_setting(@verified_only_setting, false)
  rescue
    _ -> false
  end

  @doc "The module setting behind `verified_only?/0`."
  @spec verified_only_setting() :: String.t()
  def verified_only_setting, do: @verified_only_setting

  @doc false
  # The task key a call names, when it names one as a string.
  @spec task_key(keyword()) :: String.t() | nil
  def task_key(opts) do
    case opts[:task] do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp task_needs(%TaskSpec{needs: needs}), do: needs
  defp task_needs(_task), do: []

  # `describe_image(model:)` and the other `model:` overrides send another
  # model than the endpoint's; that model is the one checked.
  defp model_endpoint(endpoint, opts) do
    case opts[:model] do
      model when is_binary(model) and model != "" -> %{endpoint | model: model}
      _ -> endpoint
    end
  end

  defp json_requested?(opts), do: is_map(opts[:schema]) or opts[:json] == true

  defp has_image_part?(messages) when is_list(messages),
    do: Enum.any?(messages, &(&1 |> content() |> image_content?()))

  defp has_image_part?(_messages), do: false

  defp content(%{} = message), do: message[:content] || message["content"]
  defp content(_message), do: nil

  defp image_content?(parts) when is_list(parts) do
    Enum.any?(parts, fn
      %{} = part -> to_string(part[:type] || part["type"]) == "image_url"
      _ -> false
    end)
  end

  defp image_content?(_content), do: false

  defp add_if(list, need, true), do: list ++ [need]
  defp add_if(list, _need, _false), do: list

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
