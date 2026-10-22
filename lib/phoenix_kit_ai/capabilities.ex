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
      the union over OpenRouter's upstream providers.
    * **Anthropic** (native `GET /v1/models`, read by
      `OpenRouterClient.fetch_models/2`): `capabilities.image_input` →
      `vision` (`capabilities: null` leaves it `:unknown`), `max_input_tokens`
      → `context_length`, `lifecycle`. Chat goes through Anthropic's
      OpenAI-compatible layer, which ignores `response_format`, so
      `json_schema` is `:no` and `json` is `:yes` (the schema is written into
      the prompt instead); `tools` is `:yes`.
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
  provider changes, and on a miss (at most once a minute). They are single
  flight — callers arriving while one runs share it — and a failed one keeps
  what the cache had and is tried again a minute later. After each refresh
  `{:capabilities_refreshed, base_urls}` is broadcast on `topic/0`.
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
  @retry_interval :timer.minutes(1)
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
            lifecycle: nil

  @type flag :: :yes | :no | :unknown
  @type t :: %__MODULE__{
          vision: flag(),
          tools: flag(),
          json_schema: flag(),
          json: flag(),
          context_length: pos_integer() | nil,
          source: :catalogue | :declared,
          fetched_at: DateTime.t() | nil,
          lifecycle: :active | :deprecated | :retired | nil
        }

  # ===========================================
  # READS
  # ===========================================

  @doc "The PubSub topic refreshes are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the caller to `{:capabilities_refreshed, base_urls}`, sent after
  each refresh with the base URLs whose catalogue was read.
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
        if catalogue_kind(nil, base_url), do: GenServer.cast(__MODULE__, :miss)
        :unknown
    end
  rescue
    # No table: the process is not running.
    ArgumentError -> :unknown
  end

  def lookup(_base_url, _model), do: :unknown

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
    openrouter(model.architecture, model.supported_parameters, model.context_length)
  end

  def from_openrouter(model) when is_map(model) do
    openrouter(model["architecture"], model["supported_parameters"], model["context_length"])
  end

  defp openrouter(architecture, params, context_length) do
    %__MODULE__{
      vision: openrouter_vision(architecture),
      tools: param_flag(params, ["tools"]),
      json_schema: param_flag(params, ["structured_outputs"]),
      json: param_flag(params, ["structured_outputs", "response_format"]),
      context_length: positive_integer(context_length)
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
      lifecycle: lifecycle(row["lifecycle"])
    }
  end

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
      task: nil,
      waiters: [],
      pending: false,
      last_started: nil,
      timer: nil,
      refresh_interval: Keyword.get(opts, :refresh_interval, @refresh_interval),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
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

  @impl true
  def handle_call(:refresh, from, state) do
    {:noreply, state |> Map.update!(:waiters, &[from | &1]) |> start_refresh()}
  end

  @impl true
  def handle_cast(:miss, %{task: nil} = state) do
    if cooling_down?(state), do: {:noreply, state}, else: {:noreply, start_refresh(state)}
  end

  def handle_cast(:miss, state), do: {:noreply, state}

  def handle_cast(:refresh_after_change, %{task: nil} = state),
    do: {:noreply, start_refresh(state)}

  def handle_cast(:refresh_after_change, state), do: {:noreply, %{state | pending: true}}

  @impl true
  def handle_info(:tick, state), do: {:noreply, start_refresh(%{state | timer: nil})}

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_refresh(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
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

  defp cooling_down?(%{last_started: nil}), do: false

  defp cooling_down?(%{last_started: started, miss_cooldown: cooldown}),
    do: System.monotonic_time(:millisecond) - started < cooldown

  defp start_refresh(%{task: nil} = state) do
    task = Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, &read_catalogues/0)
    %{state | task: task.ref, pending: false, last_started: System.monotonic_time(:millisecond)}
  end

  defp start_refresh(state), do: state

  defp finish_refresh(state, result) do
    {ok, reply} =
      case result do
        %{ok: ok, errors: []} -> {ok, :ok}
        %{ok: ok, errors: errors} -> {ok, {:error, {:catalogue_unavailable, base_urls(errors)}}}
        {:error, _reason} = error -> {[], error}
      end

    Enum.each(ok, fn {base_url, catalogue} -> put_catalogue(base_url, catalogue) end)
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    PubSub.broadcast(@topic, {:capabilities_refreshed, base_urls(ok)})

    next = if reply == :ok, do: state.refresh_interval, else: state.retry_interval
    state = schedule(%{state | task: nil, waiters: []}, next)

    if state.pending, do: start_refresh(state), else: state
  end

  defp base_urls(results), do: Enum.map(results, &elem(&1, 0))

  # New entries first, then the ones the catalogue no longer has, so a read
  # in between never misses a model that is still there.
  defp put_catalogue(base_url, catalogue) do
    :ets.insert(@table, Enum.map(catalogue, fn {model, caps} -> {{base_url, model}, caps} end))

    @table
    |> :ets.select([{{{base_url, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.reject(&Map.has_key?(catalogue, &1))
    |> Enum.each(&:ets.delete(@table, {base_url, &1}))
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
  defp read_catalogues do
    do_read_catalogues()
  rescue
    _ -> {:error, :refresh_failed}
  catch
    _kind, _reason -> {:error, :refresh_failed}
  end

  defp do_read_catalogues do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().all(Endpoint)
    |> Enum.flat_map(&catalogue_source/1)
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

  defp fetch_catalogue(kind, base_url, endpoints, now) do
    case Enum.find_value(endpoints, &present_key(OpenRouterClient.resolve_api_key(&1))) do
      nil ->
        {:error, :no_api_key}

      api_key ->
        with {:ok, models} <-
               OpenRouterClient.fetch_models(api_key,
                 base_url: base_url,
                 fallback_provider: Atom.to_string(kind),
                 model_type: :all
               ) do
          {:ok,
           Map.new(models, &{&1.id, %{(&1.capabilities || %__MODULE__{}) | fetched_at: now}})}
        end
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
