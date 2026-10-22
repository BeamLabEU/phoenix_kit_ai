defmodule PhoenixKitAI.Capabilities do
  @moduledoc """
  What a model can do — images in, tools, a strict JSON schema, any JSON —
  as the provider's catalogue says, or as an admin declared it on the
  endpoint where the catalogue says nothing.

  ## Where the answers come from

    * **OpenRouter** (`GET /models`): `image` among
      `architecture.input_modalities` (or on the left side of the older
      `modality` string) → `vision`; `tools` in `supported_parameters` →
      `tools`; `structured_outputs` → `json_schema`; `response_format`
      without `structured_outputs` → `json` only. `supported_parameters` is
      the union over OpenRouter's upstream providers; the list itself is
      kept as `supported_parameters` (the call-time guard leaves out what it
      lacks when it asks OpenRouter to require every parameter). Neither it
      nor the model names, prices, output kind or `thinking_*` flags are in the snapshot: after a restart they
      are unknown until the first refresh.
    * **Anthropic** (native `GET /v1/models`, read by
      `OpenRouterClient.fetch_models/2`): `capabilities.image_input` →
      `vision` (`capabilities: null` leaves it `:unknown`), `max_input_tokens`
      → `context_length`, `lifecycle`. Chat goes through Anthropic's
      OpenAI-compatible layer, which ignores `response_format`, so
      `json_schema` is `:no` and `json` is `:yes` (the schema is written into
      the prompt instead); `tools` is `:yes`;
      `capabilities.thinking.types.{enabled,adaptive,disabled}` →
      `thinking_enabled` / `thinking_adaptive` / `thinking_disabled` (which
      `thinking: {type: …}` forms the model accepts; the documented
      catalogue rows show only `enabled` and `adaptive`, so
      `thinking_disabled` is expected to stay `:unknown`).
    * **Every other provider** — `:unknown`, unless declared.

  ## Declared capabilities

  An endpoint may carry `provider_settings["capabilities"]` —
  `%{"model" => id, "vision" => "yes", ...}` — for a model its catalogue says
  nothing about. The declaration counts only for the model it names
  (`PhoenixKitAI.Endpoint` drops it when the model changes) and only where
  the catalogue is `:unknown`: a catalogue `:no` against a declared `:yes` is
  a conflict (`conflicts/2`) and the catalogue wins.

  ## The cache

  This module is also the process `PhoenixKitAI.children/0` starts. It owns
  an ETS table keyed by `{resolved base URL, model}` holding the whole
  catalogue of every provider an endpoint points at, and a snapshot of the
  endpoints' own models in `phoenix_kit_ai_model_capabilities` (this
  module's migration chain), loaded into the table at start so a restart
  without network keeps the answers. Reads (`lookup/2`, `for_endpoint/1`) are
  ETS only, never network; a miss is `:unknown` and asks for a refresh in the
  background.

  Refreshes run every 6 hours, on `refresh/0`, after an endpoint's model or
  provider changes, and on a miss for a base URL whose catalogue has not been
  read this cycle (at most once a minute; a miss in a catalogue that was read
  is a model it does not have, and asks for nothing). They are single flight
  — callers arriving while one runs share it. A catalogue that cannot be read
  keeps what the cache had and is tried again on its own after 1, 5 and 30
  minutes, then at the next 6-hourly refresh, which starts the 1, 5, 30
  minute retries over if it fails too; an empty list counts as a failure,
  and a base URL whose endpoints have no API key is not retried.
  When a refresh changes what the cache holds,
  `{:capabilities_refreshed, base_urls}` is broadcast on `topic/0` with the
  base URLs that changed.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.ModelCapability
  alias PhoenixKitAI.OpenRouterClient
  alias PhoenixKitAI.Web.MessageShape

  @table __MODULE__
  @topic "phoenix_kit:ai:capabilities"
  @declarable [:vision, :tools, :json_schema]
  @anthropic_base_url "https://api.anthropic.com/v1"

  @refresh_interval :timer.hours(6)
  # A failed catalogue is tried again after these delays, then not before
  # the next scheduled refresh.
  @retry_backoff [:timer.minutes(1), :timer.minutes(5), :timer.minutes(30)]
  @miss_cooldown :timer.minutes(1)
  # The first refresh after boot waits a little, so it does not compete with
  # the rest of the application starting.
  @initial_refresh :timer.seconds(10)
  @call_timeout :timer.seconds(60)

  defstruct vision: :unknown,
            tools: :unknown,
            json_schema: :unknown,
            json: :unknown,
            context_length: nil,
            source: :catalogue,
            fetched_at: nil,
            lifecycle: nil,
            supported_parameters: nil,
            thinking_disabled: :unknown,
            thinking_enabled: :unknown,
            thinking_adaptive: :unknown,
            name: nil,
            prompt_price: nil,
            completion_price: nil,
            text_output: nil

  @type flag :: :yes | :no | :unknown
  @type t :: %__MODULE__{
          vision: flag(),
          tools: flag(),
          json_schema: flag(),
          json: flag(),
          context_length: pos_integer() | nil,
          source: :catalogue | :declared,
          fetched_at: DateTime.t() | nil,
          lifecycle: :active | :deprecated | :retired | nil,
          supported_parameters: [String.t()] | nil,
          thinking_disabled: flag(),
          thinking_enabled: flag(),
          thinking_adaptive: flag(),
          name: String.t() | nil,
          prompt_price: float() | nil,
          completion_price: float() | nil,
          text_output: boolean() | nil
        }

  # ===========================================
  # READS
  # ===========================================

  @doc "The PubSub topic refreshes are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the caller to `{:capabilities_refreshed, base_urls}`, sent after
  a refresh that changed what the cache holds, with the base URLs that
  changed.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@topic)

  @doc "The capabilities an admin can declare on an endpoint."
  @spec declarable() :: [:vision | :tools | :json_schema]
  def declarable, do: @declarable

  @doc """
  The catalogue's answer for `model` at `base_url`, from the cache only.
  `:unknown` when the cache does not have it (or is not running); a miss on
  a provider with a catalogue asks for a refresh in the background.
  """
  @spec lookup(String.t() | nil, String.t() | nil) :: t() | :unknown
  def lookup(base_url, model) when is_binary(base_url) and is_binary(model) do
    base_url = normalize_base_url(base_url)

    case :ets.lookup(@table, {base_url, model}) do
      [{_key, caps}] ->
        caps

      [] ->
        if catalogue_kind(nil, base_url), do: GenServer.cast(__MODULE__, {:miss, base_url})
        :unknown
    end
  rescue
    # No table: the process is not running.
    ArgumentError -> :unknown
  end

  def lookup(_base_url, _model), do: :unknown

  @doc """
  Every model the cache holds for `base_url` (the whole catalogue, not just
  the endpoints' models), as `{model_id, capabilities}`. `[]` when there is
  none or the cache is not running. Reads ETS only.
  """
  @spec catalogue(String.t() | nil) :: [{String.t(), t()}]
  def catalogue(base_url) when is_binary(base_url) do
    :ets.select(@table, [{{{normalize_base_url(base_url), :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  def catalogue(_base_url), do: []

  @doc """
  What the endpoint's model can do: the catalogue, with the endpoint's
  declaration filling what the catalogue does not know. `:unknown` when
  neither says anything.
  """
  @spec for_endpoint(Endpoint.t()) :: t() | :unknown
  def for_endpoint(%Endpoint{} = endpoint) do
    endpoint
    |> resolved_base_url()
    |> lookup(endpoint.model)
    |> merge(declared(endpoint))
  end

  @doc """
  The capabilities declared on the endpoint for its current model, as a map
  of the flags that say `:yes` or `:no`. A declaration naming another model
  counts for nothing.
  """
  @spec declared(Endpoint.t() | map()) :: %{optional(atom()) => :yes | :no}
  def declared(%{
        model: model,
        provider_settings: %{"capabilities" => %{"model" => model} = decl}
      })
      when is_binary(model) do
    for flag <- @declarable,
        value = parse_flag(decl[Atom.to_string(flag)]),
        value != :unknown,
        into: %{},
        do: {flag, value}
  end

  def declared(_endpoint), do: %{}

  @doc """
  Fills the flags the catalogue leaves `:unknown` from a declaration. The
  result's `source` is `:declared` when a declaration filled anything.
  """
  @spec merge(t() | :unknown, map()) :: t() | :unknown
  def merge(catalogue, declared) when declared == %{}, do: catalogue
  def merge(:unknown, declared), do: merge(%__MODULE__{}, declared)

  def merge(%__MODULE__{} = catalogue, declared) do
    case Enum.filter(declared, fn {flag, _value} -> Map.fetch!(catalogue, flag) == :unknown end) do
      [] -> catalogue
      filled -> struct(catalogue, [{:source, :declared} | filled])
    end
  end

  @doc "The flags declared `:yes` that the catalogue says `:no` to."
  @spec conflicts(t() | :unknown, map()) :: [atom()]
  def conflicts(%__MODULE__{} = catalogue, declared) do
    for flag <- @declarable,
        Map.get(declared, flag) == :yes,
        Map.fetch!(catalogue, flag) == :no,
        do: flag
  end

  def conflicts(_catalogue, _declared), do: []

  # ===========================================
  # CATALOGUES
  # ===========================================

  @doc """
  Which catalogue a provider has: `:openrouter`, `:anthropic`, or `nil` for
  none. Decided by the provider key or by the host of the base URL — not by
  the Integrations registry, which may not know the provider.
  """
  @spec catalogue_kind(String.t() | nil, String.t() | nil) :: :openrouter | :anthropic | nil
  def catalogue_kind(provider, base_url) do
    host = host(base_url)

    cond do
      provider == "anthropic" or host == "api.anthropic.com" -> :anthropic
      provider == "openrouter" or host == "openrouter.ai" -> :openrouter
      true -> nil
    end
  end

  @doc """
  The base URL the endpoint's requests go to: its own, or the provider's
  default when it has none. Trimmed, without a trailing slash — the key the
  cache and the snapshot use, so an empty and an explicit default URL are
  one entry. `nil` when there is neither.
  """
  @spec resolved_base_url(Endpoint.t() | map()) :: String.t() | nil
  def resolved_base_url(%{base_url: base_url, provider: provider}) do
    if is_binary(base_url) and String.trim(base_url) != "" do
      normalize_base_url(base_url)
    else
      default_base_url(provider)
    end
  end

  defp default_base_url(provider) when is_binary(provider) do
    case Endpoint.default_base_url(provider) do
      url when is_binary(url) and url != "" -> normalize_base_url(url)
      _ when provider == "anthropic" -> @anthropic_base_url
      _ -> nil
    end
  end

  defp default_base_url(_provider), do: nil

  defp normalize_base_url(url), do: url |> String.trim() |> String.trim_trailing("/")

  defp host(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp host(_url), do: nil

  @doc "Reads an OpenRouter `/models` row (or an `AIModel` built from one)."
  @spec from_openrouter(AIModel.t() | map()) :: t()
  def from_openrouter(%AIModel{} = model) do
    model.architecture
    |> openrouter(model.supported_parameters, model.context_length)
    |> with_listing(model.name, model.pricing, model.architecture)
  end

  def from_openrouter(model) when is_map(model) do
    model["architecture"]
    |> openrouter(model["supported_parameters"], model["context_length"])
    |> with_listing(model["name"], model["pricing"], model["architecture"])
  end

  # What the recommendations list shows and ranks by: the model's name, its
  # dollars-per-token prices (nil where the catalogue gives none or a
  # negative "varies" marker) and whether it answers in text.
  defp with_listing(caps, name, pricing, architecture) do
    pricing = if is_map(pricing), do: pricing, else: %{}

    %{
      caps
      | name: if(is_binary(name) and name != "", do: name),
        prompt_price: price(pricing["prompt"]),
        completion_price: price(pricing["completion"]),
        text_output: text_output(architecture)
    }
  end

  defp price(value) when is_number(value) and value >= 0, do: value * 1.0

  defp price(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0 -> float
      _ -> nil
    end
  end

  defp price(_value), do: nil

  defp text_output(%{"output_modalities" => outputs}) when is_list(outputs),
    do: "text" in outputs

  defp text_output(%{"modality" => modality}) when is_binary(modality) and modality != "" do
    modality |> String.split("->") |> List.last() |> String.contains?("text")
  end

  defp text_output(_architecture), do: nil

  defp openrouter(architecture, params, context_length) do
    %__MODULE__{
      vision: openrouter_vision(architecture),
      tools: param_flag(params, ["tools"]),
      json_schema: param_flag(params, ["structured_outputs"]),
      json: param_flag(params, ["structured_outputs", "response_format"]),
      context_length: positive_integer(context_length),
      supported_parameters: if(is_list(params), do: params)
    }
  end

  defp openrouter_vision(%{"input_modalities" => inputs}) when is_list(inputs),
    do: yes_no("image" in inputs)

  defp openrouter_vision(%{"modality" => modality}) when is_binary(modality) and modality != "" do
    modality |> String.split("->") |> hd() |> String.contains?("image") |> yes_no()
  end

  defp openrouter_vision(_architecture), do: :unknown

  defp param_flag(params, wanted) when is_list(params),
    do: yes_no(Enum.any?(wanted, &(&1 in params)))

  defp param_flag(_params, _wanted), do: :unknown

  @doc "Reads an Anthropic `/v1/models` row."
  @spec from_anthropic(map()) :: t()
  def from_anthropic(row) when is_map(row) do
    %__MODULE__{
      vision: anthropic_vision(row["capabilities"]),
      tools: :yes,
      json_schema: :no,
      json: :yes,
      context_length: positive_integer(row["max_input_tokens"]),
      lifecycle: lifecycle(row["lifecycle"]),
      name:
        if(is_binary(row["display_name"]) and row["display_name"] != "", do: row["display_name"]),
      text_output: true,
      thinking_disabled: thinking_type(row["capabilities"], "disabled"),
      thinking_enabled: thinking_type(row["capabilities"], "enabled"),
      thinking_adaptive: thinking_type(row["capabilities"], "adaptive")
    }
  end

  # Which `thinking: {type: …}` forms a model accepts, from
  # `capabilities.thinking.types.<type>.supported`; a catalogue that does not
  # say leaves it `:unknown`, and a form that is not `:yes` is not sent.
  # Anthropic's documented examples list only `enabled` and `adaptive`, so
  # `disabled` is expected to stay `:unknown` until a catalogue shows it.
  defp thinking_type(%{"thinking" => %{"types" => %{} = types}}, type) do
    case types[type] do
      %{"supported" => supported} when is_boolean(supported) -> yes_no(supported)
      _ -> :unknown
    end
  end

  defp thinking_type(_capabilities, _type), do: :unknown

  defp anthropic_vision(%{"image_input" => %{"supported" => supported}})
       when is_boolean(supported),
       do: yes_no(supported)

  defp anthropic_vision(_capabilities), do: :unknown

  defp yes_no(true), do: :yes
  defp yes_no(false), do: :no

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp lifecycle("active"), do: :active
  defp lifecycle("deprecated"), do: :deprecated
  defp lifecycle("retired"), do: :retired
  defp lifecycle(_value), do: nil

  defp parse_flag("yes"), do: :yes
  defp parse_flag("no"), do: :no
  defp parse_flag(_value), do: :unknown

  # ===========================================
  # REFRESH
  # ===========================================

  @doc """
  Refreshes the cache from the catalogues now and returns when done — or
  joins a refresh already running. `{:error, reason}` when a catalogue could
  not be read; what the cache had for it stays.
  """
  @spec refresh(timeout()) :: :ok | {:error, term()}
  def refresh(timeout \\ @call_timeout) do
    GenServer.call(__MODULE__, :refresh, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Asks for a refresh after an endpoint's model or provider changed. Unlike a
  miss, it is not satisfied by a refresh that started before the change: one
  running now is followed by another. A no-op when the process is not
  running.
  """
  @spec refresh_after_change() :: :ok
  def refresh_after_change, do: GenServer.cast(__MODULE__, :refresh_after_change)

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      # The refresh in flight: a `%Task{}`, reading every catalogue
      # (`scope: :all`) or only the listed base URLs (a retry).
      task: nil,
      scope: :all,
      waiters: [],
      # A full refresh asked for while one could not serve it, and the
      # `refresh/0` callers waiting for that one.
      pending: false,
      pending_waiters: [],
      last_started: nil,
      timer: nil,
      retry_timer: nil,
      # base URL (or `:all`, a refresh that could not run) => {attempts, due}
      failures: %{},
      # Base URLs a miss does not ask about again until the next scheduled
      # refresh: read this cycle, or already asked about.
      settled: MapSet.new(),
      task_supervisor: Keyword.get(opts, :task_supervisor, PhoenixKit.TaskSupervisor),
      refresh_interval: Keyword.get(opts, :refresh_interval, @refresh_interval),
      retry_backoff: Keyword.get(opts, :retry_backoff, @retry_backoff),
      miss_cooldown: Keyword.get(opts, :miss_cooldown, @miss_cooldown)
    }

    {:ok, state,
     {:continue, {:load_snapshot, Keyword.get(opts, :initial_refresh, @initial_refresh)}}}
  end

  @impl true
  def handle_continue({:load_snapshot, initial_refresh}, state) do
    load_snapshot()
    {:noreply, schedule(state, initial_refresh)}
  end

  # A caller joins a refresh that reads every catalogue; a retry of some is
  # followed by a full one, which answers it.
  @impl true
  def handle_call(:refresh, from, %{task: nil} = state),
    do: {:noreply, start_refresh(%{state | waiters: [from | state.waiters]}, :all)}

  def handle_call(:refresh, from, %{scope: :all} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:refresh, from, state),
    do: {:noreply, %{state | pending: true, pending_waiters: [from | state.pending_waiters]}}

  # A miss asks for a refresh only for a base URL this cycle has not settled.
  # A catalogue that was read lists every model it has, so a miss there is a
  # model it does not have; one waiting on a retry has its own schedule; and
  # one a miss already asked about (no endpoint points at it, say) is not
  # asked about again until the next scheduled refresh.
  @impl true
  def handle_cast({:miss, base_url}, %{task: nil} = state) do
    if settled?(state, base_url) or cooling_down?(state) do
      {:noreply, state}
    else
      {:noreply, start_refresh(%{state | settled: MapSet.put(state.settled, base_url)}, :all)}
    end
  end

  def handle_cast({:miss, _base_url}, state), do: {:noreply, state}

  def handle_cast(:refresh_after_change, %{task: nil} = state),
    do: {:noreply, start_refresh(state, :all)}

  def handle_cast(:refresh_after_change, state), do: {:noreply, %{state | pending: true}}

  # The scheduled refresh starts a new cycle: what misses settled is
  # forgotten, so a model that has appeared since is found, and failures
  # start counting again, so a catalogue that fails now gets the quick
  # retries even if an earlier outage used them up.
  @impl true
  def handle_info(:tick, state) do
    state = %{state | timer: nil, settled: MapSet.new(), failures: %{}}

    if state.task,
      do: {:noreply, %{state | pending: true}},
      else: {:noreply, start_refresh(state, :all)}
  end

  # Retries the catalogues whose back-off is over — all of them when the
  # last refresh could not run at all. With a refresh in flight the retry
  # waits: its end schedules the next one.
  def handle_info(:retry, %{task: nil} = state) do
    state = %{state | retry_timer: nil}
    now = now()
    due = for {key, {_attempts, at}} <- state.failures, is_integer(at) and at <= now, do: key

    cond do
      due == [] -> {:noreply, schedule_retry(state)}
      :all in due -> {:noreply, start_refresh(state, :all)}
      true -> {:noreply, start_refresh(state, due)}
    end
  end

  def handle_info(:retry, state), do: {:noreply, %{state | retry_timer: nil}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_refresh(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning(
      "[PhoenixKitAI.Capabilities] refresh crashed: #{MessageShape.describe(reason)}"
    )

    {:noreply, finish_refresh(state, {:error, :refresh_crashed})}
  end

  def handle_info(msg, state) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Capabilities] unhandled handle_info: #{MessageShape.describe(msg)}"
    end)

    {:noreply, state}
  end

  defp settled?(state, base_url) do
    MapSet.member?(state.settled, base_url) or Map.has_key?(state.failures, base_url) or
      Map.has_key?(state.failures, :all)
  end

  defp cooling_down?(%{last_started: nil}), do: false

  defp cooling_down?(%{last_started: started, miss_cooldown: cooldown}),
    do: now() - started < cooldown

  defp start_refresh(state, scope) do
    state =
      if scope == :all do
        %{
          state
          | pending: false,
            waiters: state.waiters ++ state.pending_waiters,
            pending_waiters: []
        }
      else
        state
      end

    state = %{state | scope: scope, last_started: now()}

    case spawn_refresh(state.task_supervisor, scope) do
      {:ok, task} -> %{state | task: task}
      {:error, reason} -> finish_refresh(state, {:error, reason})
    end
  end

  # The task supervisor may be down or restarting; the refresh then counts
  # as failed and is retried, instead of taking this process down.
  defp spawn_refresh(supervisor, scope) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fn -> read_catalogues(scope) end)}
  catch
    :exit, reason ->
      Logger.warning(
        "[PhoenixKitAI.Capabilities] refresh not started: #{MessageShape.describe(reason)}"
      )

      {:error, :task_supervisor_down}
  end

  defp finish_refresh(state, result) do
    {ok, errors, reply} =
      case result do
        %{ok: ok, errors: []} ->
          {ok, [], :ok}

        %{ok: ok, errors: errors} ->
          {ok, errors, {:error, {:catalogue_unavailable, base_urls(errors)}}}

        {:error, reason} = error ->
          {[], [{:all, reason}], error}
      end

    changed = for {base_url, catalogue} <- ok, put_catalogue(base_url, catalogue), do: base_url

    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    if changed != [], do: PubSub.broadcast(@topic, {:capabilities_refreshed, changed})

    unretried = for {base_url, :no_api_key} <- errors, do: base_url

    state = %{
      state
      | task: nil,
        waiters: [],
        failures: next_failures(state, result, errors),
        settled: MapSet.union(state.settled, MapSet.new(base_urls(ok) ++ unretried))
    }

    # A retry leaves the 6-hourly cycle as it is.
    state = if state.scope == :all, do: schedule(state, state.refresh_interval), else: state
    state = schedule_retry(state)

    if state.pending, do: start_refresh(state, :all), else: state
  end

  # What still fails after this run, each with its count of failed attempts
  # in a row this cycle and when to try again: the back-off steps, then
  # nothing before the next scheduled refresh (which resets the count). A full run that read the endpoints says what
  # fails now; a retry settles the base URLs it retried. A missing API key is
  # not retried — saving the endpoint asks for a refresh.
  defp next_failures(state, result, errors) do
    previous = state.failures

    kept =
      case {state.scope, result} do
        {:all, %{}} -> %{}
        {:all, {:error, _reason}} -> previous
        {scope, _result} -> Map.drop(previous, scope)
      end

    Enum.reduce(errors, kept, fn
      {_key, :no_api_key}, acc ->
        acc

      {key, _reason}, acc ->
        attempts =
          case previous do
            %{^key => {count, _due}} -> count + 1
            _ -> 1
          end

        Map.put(acc, key, {attempts, retry_due(state, attempts)})
    end)
  end

  defp retry_due(state, attempts) do
    case Enum.at(state.retry_backoff, attempts - 1) do
      delay when is_integer(delay) and delay < state.refresh_interval -> now() + delay
      _ -> nil
    end
  end

  defp schedule_retry(state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)

    case for({_key, {_attempts, at}} <- state.failures, is_integer(at), do: at) do
      [] ->
        %{state | retry_timer: nil}

      dues ->
        %{state | retry_timer: Process.send_after(self(), :retry, max(Enum.min(dues) - now(), 0))}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp base_urls(results), do: Enum.map(results, &elem(&1, 0))

  # New entries first, then the ones the catalogue no longer has, so a read
  # in between never misses a model that is still there. Returns whether
  # anything a reader sees changed (`fetched_at` aside).
  defp put_catalogue(base_url, catalogue) do
    before =
      @table
      |> :ets.select([{{{base_url, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Map.new(fn {model, caps} -> {model, %{caps | fetched_at: nil}} end)

    :ets.insert(@table, Enum.map(catalogue, fn {model, caps} -> {{base_url, model}, caps} end))

    before
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(catalogue, &1))
    |> Enum.each(&:ets.delete(@table, {base_url, &1}))

    before != Map.new(catalogue, fn {model, caps} -> {model, %{caps | fetched_at: nil}} end)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case delay do
      delay when is_integer(delay) and delay >= 0 ->
        %{state | timer: Process.send_after(self(), :tick, delay)}

      _never ->
        %{state | timer: nil}
    end
  end

  # ===========================================
  # CATALOGUE READ AND SNAPSHOT (in the refresh task)
  # ===========================================

  # Reads the catalogue of every provider an endpoint points at, one fetch
  # per base URL, and snapshots the endpoints' own models. Returns the
  # catalogues read and the base URLs that failed. Anything raised is caught
  # here: a task's crash report would carry its stack arguments, an API key
  # among them.
  defp read_catalogues(scope) do
    do_read_catalogues(scope)
  rescue
    _ -> {:error, :refresh_failed}
  catch
    _kind, _reason -> {:error, :refresh_failed}
  end

  defp do_read_catalogues(scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Oldest first (UUIDv7), so the order keys are tried in is stable.
    from(e in Endpoint, order_by: e.uuid)
    |> repo().all()
    |> Enum.flat_map(&catalogue_source/1)
    |> Enum.filter(fn {base_url, _kind, _endpoint} -> scope == :all or base_url in scope end)
    |> Enum.group_by(fn {base_url, _kind, _endpoint} -> base_url end)
    |> Enum.reduce(%{ok: [], errors: []}, fn {base_url, sources}, acc ->
      {_base_url, kind, _endpoint} = hd(sources)
      endpoints = Enum.map(sources, fn {_base_url, _kind, endpoint} -> endpoint end)

      case fetch_catalogue(kind, base_url, endpoints, now) do
        {:ok, catalogue} ->
          write_snapshot(base_url, endpoints, catalogue, now)
          %{acc | ok: [{base_url, catalogue} | acc.ok]}

        {:error, reason} ->
          Logger.warning(
            "[PhoenixKitAI.Capabilities] catalogue at #{host(base_url)} not read: " <>
              MessageShape.describe(reason)
          )

          %{acc | errors: [{base_url, reason} | acc.errors]}
      end
    end)
  end

  defp catalogue_source(%Endpoint{model: model} = endpoint)
       when is_binary(model) and model != "" do
    base_url = resolved_base_url(endpoint)

    case base_url && catalogue_kind(endpoint.provider, base_url) do
      nil -> []
      kind -> [{base_url, kind, endpoint}]
    end
  end

  defp catalogue_source(_endpoint), do: []

  # Tries the distinct keys of the endpoints at this base URL in turn while
  # the provider rejects them (a revoked key on one endpoint does not hide a
  # good one on another). An empty list is a failure, not "no models": it
  # would otherwise wipe the cache and the snapshot of this base URL.
  defp fetch_catalogue(kind, base_url, endpoints, now) do
    endpoints
    |> Stream.map(&present_key(OpenRouterClient.resolve_api_key(&1)))
    |> Stream.reject(&is_nil/1)
    |> Stream.uniq()
    |> Enum.reduce_while({:error, :no_api_key}, fn api_key, _acc ->
      case OpenRouterClient.fetch_models(api_key,
             base_url: base_url,
             fallback_provider: Atom.to_string(kind),
             model_type: :all
           ) do
        {:error, :invalid_api_key} = rejected -> {:cont, rejected}
        result -> {:halt, result}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, :empty_catalogue}

      {:ok, models} ->
        {:ok, Map.new(models, &{&1.id, %{(&1.capabilities || %__MODULE__{}) | fetched_at: now}})}

      error ->
        error
    end
  end

  defp present_key(key) when is_binary(key) and key != "", do: key
  defp present_key(_key), do: nil

  # Upserts the endpoints' models the catalogue has, and drops the rows of
  # this base URL whose model the catalogue no longer lists. A failed write
  # is logged; the cache is still updated from the fetch.
  defp write_snapshot(base_url, endpoints, catalogue, now) do
    rows =
      for model <- endpoints |> Enum.map(& &1.model) |> Enum.uniq(),
          caps = catalogue[model],
          caps != nil,
          do: snapshot_row(base_url, model, caps, now)

    repo().insert_all(ModelCapability, rows,
      on_conflict:
        {:replace,
         [
           :vision,
           :tools,
           :json_schema,
           :json,
           :context_length,
           :lifecycle,
           :fetched_at,
           :updated_at
         ]},
      conflict_target: [:base_url, :model]
    )

    listed = Map.keys(catalogue)

    repo().delete_all(
      from(c in ModelCapability, where: c.base_url == ^base_url and c.model not in ^listed)
    )
  rescue
    e ->
      Logger.warning(
        "[PhoenixKitAI.Capabilities] snapshot not written: #{MessageShape.describe(e)}"
      )
  end

  defp snapshot_row(base_url, model, caps, now) do
    %{
      base_url: base_url,
      model: model,
      vision: Atom.to_string(caps.vision),
      tools: Atom.to_string(caps.tools),
      json_schema: Atom.to_string(caps.json_schema),
      json: Atom.to_string(caps.json),
      context_length: caps.context_length,
      lifecycle: caps.lifecycle && Atom.to_string(caps.lifecycle),
      fetched_at: caps.fetched_at || now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp load_snapshot do
    entries =
      for row <- repo().all(ModelCapability) do
        {{row.base_url, row.model},
         %__MODULE__{
           vision: parse_flag(row.vision),
           tools: parse_flag(row.tools),
           json_schema: parse_flag(row.json_schema),
           json: parse_flag(row.json),
           context_length: row.context_length,
           lifecycle: lifecycle(row.lifecycle),
           fetched_at: row.fetched_at
         }}
      end

    :ets.insert(@table, entries)
  rescue
    e ->
      Logger.warning(
        "[PhoenixKitAI.Capabilities] snapshot not loaded: #{MessageShape.describe(e)}"
      )
  catch
    :exit, reason ->
      Logger.warning(
        "[PhoenixKitAI.Capabilities] snapshot not loaded: #{MessageShape.describe(reason)}"
      )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
