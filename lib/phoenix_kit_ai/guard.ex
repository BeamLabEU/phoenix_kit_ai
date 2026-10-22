defmodule PhoenixKitAI.Guard do
  @moduledoc """
  The call-time check every provider-calling verb passes before its HTTP
  request: does the model behind the endpoint (or the call's `model:`
  override) have what the call and its task need.

  The needs of a call are its task's declared `needs` together with what
  the call itself shows (`implied_needs/2`):

  | verb | implied |
  |---|---|
  | `complete/3`, `ask/3`, `ask_with_prompt/4`, `complete_with_system_prompt/5` | `image_url` parts in the messages → `:vision`; `file` parts → `:file_input` (string or atom keys either way); `tools:` → `:tools`; `schema:` / `json:` → `:json` |
  | `describe_image/3` | `:vision`; `:json` with `schema:` / `json:` |
  | `extract_text/3`, `compare_images/4` | `:vision`, `:json` |
  | `generate_image/3`, `edit_image/4`, `process_image/4` | `:image_output` (images given to a generation model are not vision) |
  | `embed/3`, `speak/3` | nothing |

  The model checked is the one the verb sends: a `model:` override of the
  vision and image verbs, the endpoint's model otherwise.

  A hard need (`:vision`, `:file_input`, `:image_output`, `:tools`,
  `:json_schema`) the model says no to
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

  ## Admission for a whole turn

  A caller that makes several calls for one piece of work (an assistant's
  turn) asks once, with `admit/4`: the task's limits are checked then, and
  the answer is an admission token kept on this node for `ttl_s` seconds.
  Its calls pass `guard_admission: token` and skip the limit check — so the
  work that started under the limits runs to its end — but each is still
  checked for fitness, and for `PhoenixKitAI.Budget`. A token is honoured
  only for the task and user it was issued for, and only before it expires;
  any other token is ignored and the call is checked as usual.

  ## Who may change the guard

  `ai.manage` (a sub-permission of `ai`) — or an Owner, always:
  `may_manage?/1`. Every function that changes the guard's settings takes
  the scope of the person doing it and checks it (`authorize_manage/1`).
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Capabilities, Endpoint, TaskLimits, Tasks, TaskSpec}

  @verified_only_setting "ai_guard_verified_models_only"
  @manage "ai.manage"

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
    |> add_if(:vision, has_part?(messages, "image_url"))
    |> add_if(:file_input, has_part?(messages, "file"))
    |> add_if(:tools, match?([_ | _], opts[:tools]))
    |> add_if(:json, json_requested?(opts))
  end

  def implied_needs(:describe_image, opts, _input),
    do: add_if([:vision], :json, json_requested?(opts))

  def implied_needs(verb, _opts, _input) when verb in [:extract_text, :compare_images],
    do: [:vision, :json]

  def implied_needs(verb, _opts, _input)
      when verb in [:generate_image, :edit_image, :process_image],
      do: [:image_output]

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

  @doc """
  Turns "only verified models" on or off. Needs `ai.manage`; written to the
  Activity log.
  """
  @spec set_verified_only(term(), boolean()) :: {:ok, term()} | {:error, term()}
  def set_verified_only(scope, on?) when is_boolean(on?) do
    with :ok <- authorize_manage(scope),
         {:ok, setting} = result <-
           PhoenixKit.Settings.update_boolean_setting_with_module(
             @verified_only_setting,
             on?,
             "ai"
           ) do
      PhoenixKit.Activity.log("ai", "guard.verified_only_changed",
        actor_uuid: actor_uuid(scope),
        resource_type: "setting",
        resource_uuid: setting.uuid,
        metadata: %{"enabled" => on?}
      )

      result
    end
  end

  # ===========================================
  # RIGHTS
  # ===========================================

  @doc "The permission that changes the guard."
  @spec manage_permission() :: String.t()
  def manage_permission, do: @manage

  @doc "Whether `scope` may change the guard: an Owner, or a holder of `ai.manage`."
  @spec may_manage?(term()) :: boolean()
  def may_manage?(%Scope{} = scope), do: Scope.owner?(scope) or Scope.can?(scope, @manage)
  def may_manage?(_scope), do: false

  @doc false
  @spec authorize_manage(term()) :: :ok | {:error, :forbidden}
  def authorize_manage(scope), do: if(may_manage?(scope), do: :ok, else: {:error, :forbidden})

  @doc false
  @spec actor_uuid(term()) :: String.t() | nil
  def actor_uuid(%{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  def actor_uuid(_scope), do: nil

  # ===========================================
  # ADMISSION
  # ===========================================

  @doc """
  Admits `user_uuid` (nil for none) to `task` for `ttl_s` seconds: checks the
  task's limits once and answers `{:ok, token}` for the calls of this piece
  of work to pass as `guard_admission:` (see the moduledoc), or the refusal
  (`{:error, {:task_limit_exceeded, scope, unit, period}}`), which is
  signalled like a refused call. `turn_ref` is kept with the token.

  Without the request cache's flags table (the cache not running) the token
  is not kept: `admitted?/3` says no to it, and each call is checked as if
  it had none.
  """
  @spec admit(String.t(), String.t() | nil, term(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def admit(task, user_uuid, turn_ref, ttl_s)
      when is_binary(task) and is_integer(ttl_s) and ttl_s > 0 do
    with :ok <- TaskLimits.check(Tasks.for_call(task), user_uuid: user_uuid) do
      token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      keep_admission(token, {task, user_uuid, turn_ref, now_ms() + ttl_s * 1000})
      {:ok, token}
    end
  end

  defp keep_admission(token, entry) do
    purge_admissions(now_ms())
    :ets.insert(PhoenixKitAI.RequestCache.flags_table(), {{:guard_admission, token}, entry})
  rescue
    ArgumentError -> false
  end

  @doc """
  Whether `token` is an admission this node issued for `task` and
  `user_uuid` that has not expired.
  """
  @spec admitted?(term(), term(), term()) :: boolean()
  def admitted?(token, task, user_uuid) when is_binary(token) and is_binary(task) do
    case :ets.lookup(PhoenixKitAI.RequestCache.flags_table(), {:guard_admission, token}) do
      [{_key, {^task, ^user_uuid, _turn_ref, expires_at}}] -> now_ms() < expires_at
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def admitted?(_token, _task, _user_uuid), do: false

  defp purge_admissions(now) do
    :ets.select_delete(PhoenixKitAI.RequestCache.flags_table(), [
      {{{:guard_admission, :_}, {:_, :_, :_, :"$1"}}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  # Forgets what this node keeps of the guard — cached limits, keys of the
  # events already written. Tests call it: the database is rolled back, the
  # node's tables are not.
  @spec reset_caches() :: :ok
  def reset_caches do
    PhoenixKitAI.TaskLimits.reset_cache()
    PhoenixKitAI.GuardEvents.reset_sent()
  end

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

  defp has_part?(messages, type) when is_list(messages),
    do: Enum.any?(messages, &(&1 |> content() |> part_of_type?(type)))

  defp has_part?(_messages, _type), do: false

  defp content(%{} = message), do: message[:content] || message["content"]
  defp content(_message), do: nil

  defp part_of_type?(parts, type) when is_list(parts) do
    Enum.any?(parts, fn
      %{} = part -> to_string(part[:type] || part["type"]) == type
      _ -> false
    end)
  end

  defp part_of_type?(_content, _type), do: false

  defp add_if(list, need, true), do: list ++ [need]
  defp add_if(list, _need, _false), do: list

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
