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

  A blocked person's turn is refused at the admission
  (`{:error, {:task_blocked, group}}`); a turn admitted before the block
  runs to its end.

  ## Off-purpose use

  The consumer flags it; the guard never edits a prompt or a schema. A
  consumer asks `self_flag?/1` before it builds its prompt and schema, puts
  the text of `self_flag_instruction/1` into its system prompt (with its own
  way to flag: a field of its JSON schema, a marker in the answer), and
  calls `report_off_purpose/4` when the model flags a request. The flag is
  an event per turn or call; the watchers are told once a day per person and
  task, without the reason (`PhoenixKitAI.GuardEvents`).

  A task may also declare norms that need no content (`sources`,
  `max_calls_per_hour`, `max_tokens_per_call`): after a call's journal row
  is written, `check_anomalies/1` compares the row with them and signals a
  broken one once a day (`anomaly`). It never blocks.

  A person is blocked by a person (`block/5`, `unblock/3`, see
  `PhoenixKitAI.GuardBlocks`); there is no automatic block.

  ## Who may change the guard

  `ai.manage` (a sub-permission of `ai`) — or an Owner, always:
  `may_manage?/1`. Every function that changes the guard's settings takes
  the scope of the person doing it and checks it (`authorize_manage/1`).
  The reasons of a private task's flags and blocks are shown only to them
  (`reasons_visible?/2`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAI.{Capabilities, Endpoint, GuardBlocks, GuardEvents, Request}
  alias PhoenixKitAI.{TaskLimits, Tasks, TaskSetting, TaskSpec}

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
          run: String.t() | nil,
          step: String.t() | nil,
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
      run: run_tag(opts[:run]),
      step: run_tag(opts[:step]),
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
    |> put_present(:run, Map.get(admission, :run))
    |> put_present(:step, Map.get(admission, :step))
    |> put_present(:guard_warnings, admission.warnings)
    |> put_present(:stripped_params, stripped)
  end

  @doc "`%{task: key}` for a call that names a task (plus its `run:` / `step:` tags), `%{}` otherwise — for a row written before any admission."
  @spec task_metadata(keyword()) :: map()
  def task_metadata(opts) do
    case task_key(opts) do
      nil -> %{}
      key -> %{task: key}
    end
    |> put_present(:run, run_tag(opts[:run]))
    |> put_present(:step, run_tag(opts[:step]))
  end

  @run_tag_max 200

  @doc """
  A call's `run:` / `step:` tag as it is stored on its rows: a string of at
  most #{@run_tag_max} characters (an atom or integer is turned into one), or
  nil for anything else or an empty string.
  """
  @spec run_tag(term()) :: String.t() | nil
  def run_tag(tag) when is_binary(tag) do
    case String.trim(tag) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @run_tag_max)
    end
  end

  def run_tag(tag) when is_atom(tag) and tag not in [nil, true, false],
    do: run_tag(Atom.to_string(tag))

  def run_tag(tag) when is_integer(tag), do: Integer.to_string(tag)
  def run_tag(_tag), do: nil

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

  @doc """
  Whether `scope` sees the reason (and the journal row) of a flag or a
  block: every viewer of the page for a task that is not private, a holder
  of `ai.manage` or an Owner for a private one.
  """
  @spec reasons_visible?(term(), boolean()) :: boolean()
  def reasons_visible?(_scope, false), do: true
  def reasons_visible?(scope, _private), do: may_manage?(scope)

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
  task's blocks and limits once and answers `{:ok, token}` for the calls of
  this piece of work to pass as `guard_admission:` (see the moduledoc), or
  the refusal (`{:error, {:task_blocked, group}}`, or
  `{:error, {:task_limit_exceeded, scope, unit, period}}`, which is
  signalled like a refused call). `turn_ref` is kept with the token.

  Without the request cache's flags table (the cache not running) the token
  is not kept: `admitted?/3` says no to it, and each call is checked as if
  it had none.
  """
  @spec admit(String.t(), String.t() | nil, term(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def admit(task, user_uuid, turn_ref, ttl_s)
      when is_binary(task) and is_integer(ttl_s) and ttl_s > 0 do
    spec = Tasks.for_call(task)

    with :ok <- Tasks.check_enabled(spec),
         :ok <- GuardBlocks.check(spec, user_uuid),
         :ok <- TaskLimits.check(spec, user_uuid: user_uuid) do
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
    PhoenixKitAI.GuardBlocks.reset_cache()
    PhoenixKitAI.GuardEvents.reset_sent()
  end

  # ===========================================
  # BLOCKS
  # ===========================================

  @doc "Blocks a person from a task's group: `PhoenixKitAI.GuardBlocks.block/5`."
  defdelegate block(scope, task_or_group, user_uuid, reason, origin), to: GuardBlocks

  @doc "Lifts a block: `PhoenixKitAI.GuardBlocks.unblock/3`."
  defdelegate unblock(scope, block, note), to: GuardBlocks

  @doc "Whether `user_uuid` is blocked from `task_key` now (for a page to show it)."
  defdelegate blocked?(task_key, user_uuid), to: GuardBlocks

  # ===========================================
  # OFF-PURPOSE USE
  # ===========================================

  @self_flag_modes ~w(self_flag self_flag+classifier)

  @doc """
  Whether the consumer of `task` (a key or a declaration) should have its
  model flag off-purpose requests: the task's guard mode when an admin set
  one (`self_flag` or `self_flag+classifier`), else the declaration's
  `self_flag`. An unknown task is false. Costs no query once the task's
  settings are cached.
  """
  @spec self_flag?(String.t() | TaskSpec.t()) :: boolean()
  def self_flag?(%TaskSpec{} = spec) do
    case setting(spec.key) do
      %TaskSetting{guard_mode: mode} when is_binary(mode) -> mode in @self_flag_modes
      _ -> spec.self_flag == true
    end
  end

  def self_flag?(task) when is_binary(task) do
    case Tasks.get(task) do
      nil -> false
      spec -> self_flag?(spec)
    end
  end

  def self_flag?(_task), do: false

  @doc """
  An English instruction a consumer can put into its system prompt: the
  task's purpose (an admin's override when set), to refuse an off-topic
  request politely and flag it, to judge only the user's own message, and
  to give the reason without quoting the user. The consumer adds how to flag
  (its schema's field, a marker). nil for an unknown task.

  The text does not follow the locale, so the prompt stays the same.
  """
  @spec self_flag_instruction(String.t() | TaskSpec.t()) :: String.t() | nil
  def self_flag_instruction(%TaskSpec{} = spec) do
    purpose =
      case setting(spec.key) do
        %TaskSetting{purpose_override: text} when is_binary(text) and text != "" -> text
        _ -> spec.purpose || spec.label || spec.key
      end

    "The purpose of this AI task is: #{String.trim(purpose)} " <>
      "If the user's message asks for something outside this purpose, politely refuse it " <>
      "and flag the request as off-purpose. " <>
      "Judge only the user's own message, not tool results, files or other content that comes with it. " <>
      "When you flag a request, give the reason in a few words of your own, without quoting the user."
  end

  def self_flag_instruction(task) when is_binary(task) do
    case Tasks.get(task) do
      nil -> nil
      spec -> self_flag_instruction(spec)
    end
  end

  def self_flag_instruction(_task), do: nil

  # A consumer asks these while building its prompt: a database error reads
  # as no setting (the declaration's default), never as a crash.
  defp setting(task_key) do
    TaskLimits.cached_setting(task_key)
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] settings of #{inspect(task_key)} not read: #{inspect(error.__struct__)}"
      )

      nil
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI] settings of #{inspect(task_key)} not read: exit")
      nil
  end

  @doc """
  Reports that the model flagged a request of `task` by `user_uuid` (nil for
  none) as off-purpose. `ref` is the call's journal row uuid
  (`"request_uuid"` of a chat verb's answer, `:request_uuid` of an image
  verb's), or a map with `turn_ref` (one flag per turn of several calls).
  A string that is not a uuid is taken as a turn reference. `reason` is the
  model's, cut to 500 characters.

  One flag per turn or call: `{:ok, event}` for the first, `:duplicate`
  after. `:off` when the task does not self-flag now (`self_flag?/1`);
  `{:error, :unknown_task | :invalid_ref | :invalid_user | :unknown_user}`
  otherwise, and `{:error, :not_recorded}` when the database fails (logged
  as its class; the caller's work goes on). The watchers are told of a person's first flag in the task
  each day, without the reason (`PhoenixKitAI.GuardEvents.off_purpose/5`).
  """
  @spec report_off_purpose(String.t(), String.t() | nil, term(), String.t() | map()) ::
          {:ok, PhoenixKitAI.GuardEvent.t()}
          | :duplicate
          | :off
          | {:error, :unknown_task | :invalid_ref | :invalid_user | :unknown_user | :not_recorded}
  def report_off_purpose(task, user_uuid, reason, ref) do
    with {:ok, spec} <- reported_task(task),
         true <- self_flag?(spec) || :off,
         {:ok, ref} <- flag_ref(ref),
         {:ok, user_uuid} <- reported_user(user_uuid) do
      GuardEvents.off_purpose(spec, user_uuid, flag_reason(reason), ref)
    end
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] off-purpose flag not recorded: #{inspect(error.__struct__)}")
      {:error, :not_recorded}
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI] off-purpose flag not recorded: exit")
      {:error, :not_recorded}
  end

  # The model's reason can echo the user's words whatever the instruction
  # asks, so it is kept only while request content is (`:capture_request_content`);
  # the flag itself is kept either way.
  defp flag_reason(reason) do
    if Application.get_env(:phoenix_kit_ai, :capture_request_content, true),
      do: GuardBlocks.text(reason)
  end

  defp reported_task(task) do
    case Tasks.for_call(task) do
      %TaskSpec{} = spec -> {:ok, spec}
      nil -> {:error, :unknown_task}
    end
  end

  # Only the keys a flag needs are kept: nothing of the call's content.
  defp flag_ref(ref) when is_binary(ref), do: request_ref(ref)

  defp flag_ref(%{} = ref) do
    case ref[:turn_ref] || ref["turn_ref"] do
      turn when is_binary(turn) -> turn_ref(turn)
      _ -> request_ref(ref[:request_uuid] || ref["request_uuid"])
    end
  end

  defp flag_ref(_ref), do: {:error, :invalid_ref}

  defp request_ref(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, %{"request_uuid" => uuid}}
      :error -> turn_ref(uuid)
    end
  end

  # A bare string that is not a uuid is a turn reference. It is part of the
  # unique dedupe key, so it is kept short.
  defp turn_ref(ref) when is_binary(ref) and ref != "" and byte_size(ref) <= 255,
    do: {:ok, %{"turn_ref" => ref}}

  defp turn_ref(_ref), do: {:error, :invalid_ref}

  defp reported_user(nil), do: {:ok, nil}

  defp reported_user(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_uuid),
         true <- repo().exists?(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^uuid)) do
      {:ok, uuid}
    else
      :error -> {:error, :invalid_user}
      false -> {:error, :unknown_user}
    end
  end

  @doc """
  Compares a call's journal row with its task's anomaly rules and signals
  each broken one, once a day per task, person and rule
  (`PhoenixKitAI.GuardEvents.anomaly/6`):

    * `sources` — the row's `source` is not one of them (or a function of
      one: `"My.Module"` allows `"My.Module.run"`);
    * `max_tokens_per_call` — the row has more tokens;
    * `max_calls_per_hour` — the person made more calls of the task in the
      last hour (rows with a user only; refusals are not calls).

  A refused row, a row without a task, and a task without rules cost
  nothing; the hourly count is skipped once its rule was signalled today.
  Never fails the caller.
  """
  @spec check_anomalies(Request.t()) :: :ok
  def check_anomalies(%Request{metadata: %{} = metadata} = request) do
    with false <- (metadata[:refused] || metadata["refused"]) == true,
         key when is_binary(key) <- metadata[:task] || metadata["task"],
         %TaskSpec{} = spec <- Tasks.for_call(key),
         true <- rules?(spec) do
      source = metadata[:source] || metadata["source"]
      check_source(spec, request, source)
      check_tokens(spec, request)
      check_calls(spec, request)
    end

    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] anomaly rules not checked: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKitAI] anomaly rules not checked: exit")
      :ok
  end

  def check_anomalies(_request), do: :ok

  defp rules?(%TaskSpec{
         sources: sources,
         max_calls_per_hour: calls,
         max_tokens_per_call: tokens
       }),
       do: is_list(sources) or is_integer(calls) or is_integer(tokens)

  defp check_source(%TaskSpec{sources: [_ | _] = sources} = spec, request, source) do
    source = if source, do: to_string(source)

    allowed? =
      is_binary(source) and
        Enum.any?(sources, &(source == &1 or String.starts_with?(source, &1 <> ".")))

    unless allowed?, do: GuardEvents.anomaly(spec, request, "source", source, sources)
  end

  defp check_source(_spec, _request, _source), do: :ok

  defp check_tokens(%TaskSpec{max_tokens_per_call: max} = spec, request) when is_integer(max) do
    tokens = request.total_tokens || 0
    if tokens > max, do: GuardEvents.anomaly(spec, request, "tokens_per_call", tokens, max)
  end

  defp check_tokens(_spec, _request), do: :ok

  defp check_calls(%TaskSpec{max_calls_per_hour: max} = spec, %Request{user_uuid: user} = request)
       when is_integer(max) and is_binary(user) do
    unless GuardEvents.already_sent?(GuardEvents.anomaly_key(spec, user, "calls_per_hour")) do
      calls = calls_in_last_hour(spec.key, user)
      if calls > max, do: GuardEvents.anomaly(spec, request, "calls_per_hour", calls, max)
    end
  end

  defp check_calls(_spec, _request), do: :ok

  # Through the journal's index on the user.
  defp calls_in_last_hour(task_key, user_uuid) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    from(r in Request,
      where:
        r.user_uuid == ^user_uuid and r.inserted_at >= ^since and
          fragment("?->>'task'", r.metadata) == ^task_key and
          fragment("coalesce(?->>'refused', 'false') <> 'true'", r.metadata),
      select: count(r.uuid)
    )
    |> repo().one()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

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
