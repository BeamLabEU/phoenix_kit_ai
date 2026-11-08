defmodule PhoenixKitAI.Web.Components.Dictate do
  @moduledoc """
  Turns speech into text on a page: a recording button that gives the page the
  words.

  Core's audio recorder makes the recording and knows nothing about AI. This
  component takes it, sends it to `PhoenixKitAI.transcribe/3` off the LiveView
  process and hands over the text, so a page needs no upload, no `start_async` and
  no error messages of its own.

      <.live_component
        module={PhoenixKitAI.Web.Components.Dictate}
        id="inquiry-voice"
        endpoint="Wood Matrix"
        model="google/gemini-2.5-flash"
        instructions={MyApp.Voice.instructions()}
        label={gettext("Say it instead")}
        busy={@reading}
        user_uuid={@user_uuid}
        source="MyApp.Voice"
      />

      def handle_info({:dictated, "inquiry-voice", text}, socket), do: ...

  ## Attributes

    * `id` — required; the name in the messages below
    * `endpoint` — a uuid, a name or an `%PhoenixKitAI.Endpoint{}`
    * `label` — the recorder's button
    * `busy` — the page's own reason to hold the recorder back, added to the
      component's (it records one clip at a time)
    * `max_seconds` — the longest recording, default 180
    * `into` — the DOM id of a `<textarea>` or `<input>` that gets the words, then
      an `input` event, so the form's `phx-change` runs as if the person typed them
    * `mode` — how `into` takes them: `:append` (default; after a newline, or a
      space in an `<input>`, when the field has text), `:replace`, or `:at_cursor`
      (where the cursor last was: the start of a field nobody clicked in)
    * `show_error` — `false` sends the page `{:dictation_failed, id, reason}` and
      shows nothing; see below

  Any other attribute is an option of `PhoenixKitAI.transcribe/3`, passed as it
  is: `model`, `instructions`, `language`, `user_uuid`, `task`, `source`, `run`,
  `step`, and so on. The task is `"ai.dictation"` unless `task` names the host's
  own. On any attribute `nil` means not given.

  ## What the page gets

  `{:dictated, id, text}`, with `text` trimmed and never empty, also when `into`
  took it. A LiveView that defines `handle_info/2` needs a clause for it (or a
  catch-all), or the message crashes the page.

  A failure is shown under the button, translated. It is not a flash:
  `put_flash/3` in a live component stays in the component and never reaches the
  page's flash group. With `show_error={false}` nothing is shown and the page gets
  `{:dictation_failed, id, reason}` instead, which needs a clause like the one
  above, so it is never sent to a page that did not ask for it; `message/1` gives
  such a page the same words. `reason` is `:no_speech`, `:no_endpoint`, `:busy`,
  `:task_failed`, the recorder's (`:denied`, `:unavailable`, `:unreadable`,
  `:too_large`, `:failed`), or `transcribe/3`'s, without the model's words where it
  carried them.

  ## The recorder

  `PhoenixKitWeb.Components.Core.AudioRecorder`, looked up when the page renders
  because this module also runs on a core from before it: there the component shows
  nothing to record with, like the recorder itself where a browser cannot record. It
  delivers here through `target`, since a live component has no `handle_info/2`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitAI.Gettext

  require Logger

  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Web.MessageShape

  @recorder PhoenixKitWeb.Components.Core.AudioRecorder
  @task "ai.dictation"
  @source inspect(__MODULE__)

  @defaults %{
    endpoint: nil,
    label: nil,
    busy: false,
    max_seconds: 180,
    into: nil,
    mode: :append,
    show_error: true
  }

  @own [:id | Map.keys(@defaults)]

  @recorder_errors [:denied, :unavailable, :unreadable, :too_large, :failed]

  # Errors that carry the model's answer, which is the person's words.
  @with_words [:no_json_in_response, :output_truncated, :content_policy]

  @impl true
  def mount(socket), do: {:ok, socket |> assign(@defaults) |> assign(writing?: false, error: nil)}

  @impl true
  def update(%{audio_recorded: {_id, clip}}, socket), do: {:ok, write_down(socket, clip)}
  def update(%{audio_recorder_error: {_id, reason}}, socket), do: {:ok, fail(socket, reason)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(own(assigns))
     |> assign(:options, options(assigns))}
  end

  @impl true
  def handle_async(:transcribe, {:ok, {:ok, text}}, socket),
    do: {:noreply, socket |> assign(writing?: false, error: nil) |> deliver(text)}

  def handle_async(:transcribe, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(:writing?, false) |> fail(reason)}

  def handle_async(:transcribe, {:exit, reason}, socket) do
    Logger.warning("[#{@source}] transcribe task exited: #{MessageShape.describe_exit(reason)}")
    {:noreply, socket |> assign(:writing?, false) |> fail(:task_failed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={dom_id(@id)} phx-hook={@into && "PhoenixKitAIDictate"} class="flex flex-col gap-1">
      <.recorder
        id={@id}
        format={:wav_16k}
        max_seconds={@max_seconds}
        label={@label || gettext("Dictate")}
        busy={@busy or @writing?}
        errors={if @show_error, do: :inline, else: :notify}
        target={@myself}
      />
      <div role="status" class="text-sm">
        <span :if={@writing?} class="flex items-center gap-2">
          <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
          {gettext("Writing down what you said…")}
        </span>
        <span :if={@error} class="text-error">{@error}</span>
      </div>
    </div>
    """
  end

  @doc """
  What to tell the person about `reason`, the third element of
  `{:dictation_failed, id, reason}`. A reason it does not know gets the general
  message.
  """
  @spec message(term()) :: String.t()
  def message(:no_speech) do
    gettext("We couldn't hear anything. Please try again, a little closer to the microphone.")
  end

  def message(reason) when reason in @recorder_errors, do: recorder_module().error_message(reason)

  def message(:busy), do: gettext("Still writing down the last recording. Please wait a moment.")

  def message(:output_truncated), do: too_long_message()
  def message({:audio_too_large, _bytes, _max}), do: too_long_message()

  def message({:model_unfit, _missing}) do
    gettext("This endpoint's model can't hear. Set an audio model for it.")
  end

  def message({:model_unverified, _unclear}) do
    gettext("Nobody has verified that this endpoint's model can hear. Set an audio model for it.")
  end

  def message({:budget_exceeded, _scope}), do: limit_message()
  def message({:task_limit_exceeded, _scope, _unit, _period}), do: limit_message()

  def message({tag, _detail}) when tag in [:task_blocked, :task_disabled] do
    gettext("Dictation isn't available right now.")
  end

  def message(reason)
      when reason in [
             :no_endpoint,
             :endpoint_not_found,
             :endpoint_disabled,
             :endpoint_no_model,
             :invalid_endpoint_identifier
           ] do
    gettext("No AI endpoint is set up for dictation.")
  end

  def message(_reason), do: gettext("We couldn't write that down. Please try again.")

  defp too_long_message, do: gettext("That recording is too long. Please try a shorter one.")

  defp limit_message do
    gettext("The AI usage limit has been reached. Please try again later.")
  end

  # `start_async/3` under a name already running leaves the first task going and
  # drops its result: a billed clip whose words nobody gets.
  defp write_down(%{assigns: %{writing?: true}} = socket, _clip), do: fail(socket, :busy)

  defp write_down(socket, clip) do
    %{endpoint: endpoint, options: options} = socket.assigns
    audio = Map.take(clip, [:data, :format])

    socket
    |> assign(writing?: true, error: nil)
    |> start_async(:transcribe, fn -> transcribe(endpoint, audio, options) end)
  end

  defp transcribe(endpoint, audio, options) do
    with {:ok, endpoint} <- resolve(endpoint),
         {:ok, %{text: text}} <- PhoenixKitAI.transcribe(endpoint, audio, options) do
      case String.trim(text) do
        "" -> {:error, :no_speech}
        text -> {:ok, text}
      end
    end
  end

  defp resolve(%Endpoint{} = endpoint), do: {:ok, endpoint}
  defp resolve(endpoint) when endpoint in [nil, ""], do: {:error, :no_endpoint}

  # `Ecto.UUID.cast/1` also takes any 16 bytes as a raw uuid: a name of that length.
  defp resolve(endpoint) when is_binary(endpoint) do
    case Ecto.UUID.cast(endpoint) do
      {:ok, uuid} when byte_size(endpoint) == 36 -> PhoenixKitAI.resolve_endpoint(uuid)
      _name -> PhoenixKitAI.resolve_endpoint_by_name(endpoint)
    end
  end

  defp resolve(_endpoint), do: {:error, :invalid_endpoint_identifier}

  defp deliver(socket, text) do
    %{id: id, into: into, mode: mode} = socket.assigns
    send(self(), {:dictated, id, text})

    if into do
      payload = %{into: into, mode: mode, text: text}
      push_event(socket, "phoenix_kit_ai:dictated:#{dom_id(id)}", payload)
    else
      socket
    end
  end

  defp fail(%{assigns: %{show_error: false, id: id}} = socket, reason) do
    send(self(), {:dictation_failed, id, without_words(reason)})
    socket
  end

  defp fail(socket, reason), do: assign(socket, :error, reason |> without_words() |> message())

  defp without_words({tag, text}) when tag in @with_words and is_binary(text), do: tag
  defp without_words(reason), do: reason

  # `nil` is not given, also when it replaces a value: `busy={@reading}` on a page
  # that has not set it yet, or has set it back.
  defp own(assigns) do
    assigns
    |> Map.take(@own)
    |> Map.new(fn {key, value} -> {key, if(is_nil(value), do: @defaults[key], else: value)} end)
  end

  defp options(assigns) do
    assigns
    |> Map.drop([:inner_block | @own])
    |> Enum.reject(fn {_option, value} -> is_nil(value) end)
    |> Keyword.put_new(:task, @task)
    |> Keyword.put_new(:source, @source)
  end

  defp dom_id(id), do: "#{id}-dictate"

  @doc false
  # Core's `<.audio_recorder>` where the running core has it (3.4 on), else
  # nothing. Public for the Playground, which records with it too.
  def recorder(assigns) do
    if recorder_available?() do
      recorder_module().audio_recorder(assigns)
    else
      ~H""
    end
  end

  @doc false
  @spec recorder_available?() :: boolean()
  def recorder_available?, do: Code.ensure_loaded?(recorder_module())

  defp recorder_module, do: Application.get_env(:phoenix_kit_ai, :audio_recorder, @recorder)
end
