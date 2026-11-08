defmodule PhoenixKitAI.Web.Playground do
  @moduledoc """
  LiveView for testing AI endpoints and prompts.

  Provides an interactive playground where admins can:
  - Select an endpoint and optionally a prompt
  - Fill in prompt variables
  - Send requests and see AI responses
  - Type freeform messages when no prompt is selected, or dictate them
  - Write down a recording (`PhoenixKitAI.transcribe/3`): record or pick a
    clip, run it again with another model, language, path or instructions,
    and compare the answers
  - Edit and describe images, and try xAI's realtime voice
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitAI.Gettext

  require Logger

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Guard
  alias PhoenixKitAI.OpenRouterClient
  alias PhoenixKitAI.Prompt
  alias PhoenixKitAI.Realtime.Session
  alias PhoenixKitAI.RequestLog
  alias PhoenixKitAI.Transcription
  alias PhoenixKitAI.Web.Components.Dictate
  alias PhoenixKitAI.Web.MessageShape

  # Speech to text: the recorder's id (its messages name it), how many
  # answers are kept to compare, and the largest clip played back on the
  # page (it goes to the browser as a data URL: about two minutes of the
  # recorder's 16 kHz WAV).
  @stt_recorder "playground-stt-recorder"
  @stt_kept_results 5
  @stt_playable_bytes 4_000_000
  @stt_accept ~w(audio/* .wav .mp3 .oga .opus .aac .webm .mp4)

  # Fallback shown until the live `GET /v1/tts/voices` fetch resolves (or
  # if it fails) — xAI's 5 built-in voices. Any custom/cloned voices on
  # the account only show up once the live fetch succeeds.
  @default_voice_options [
    {"Ara", "ara"},
    {"Eve", "eve"},
    {"Leo", "leo"},
    {"Rex", "rex"},
    {"Sal", "sal"}
  ]

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries here — `mount/3` runs twice. The `enabled?` check
    # and the endpoints/prompts load both happen in `handle_params/3`
    # so neither pays the 2× cost.
    socket =
      socket
      |> assign(:project_title, nil)
      |> assign(:current_path, Routes.path("/admin/ai/playground"))
      |> assign(:page_section, gettext("AI"))
      |> assign(:page_section_path, PhoenixKitAI.Routes.ai_path())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, gettext("Playground"))
      |> assign(:page_subtitle, gettext("Test endpoints and prompts interactively"))
      |> assign(:endpoints, [])
      |> assign(:prompts, [])
      |> assign(:enabled_check_done, false)
      |> assign(:selected_endpoint_uuid, nil)
      |> assign(:selected_endpoint, nil)
      |> assign(:selected_prompt_uuid, nil)
      |> assign(:selected_prompt, nil)
      |> assign(:variable_values, %{})
      |> assign(:edited_content, nil)
      |> assign(:edited_variables, [])
      |> assign(:freeform_system, "")
      |> assign(:freeform_message, "")
      |> assign(:response_text, nil)
      |> assign(:response_usage, nil)
      |> assign(:response_error, nil)
      |> assign(:sending, false)
      |> assign(:voice_text, "")
      |> assign(:voice_status, :idle)
      |> assign(:voice_error, nil)
      |> assign(:voice_session_pid, nil)
      |> assign(:voice_monitor_ref, nil)
      |> assign(:voice_options, @default_voice_options)
      |> assign(:voice_selected, "eve")
      |> assign(:edit_prompt, "")
      |> assign(:edit_result, nil)
      |> assign(:edit_error, nil)
      |> assign(:editing, false)
      |> assign(:edit_operations, [])
      |> assign(:edit_options, %{})
      |> assign(:edit_model, "")
      |> assign(:edit_verify, false)
      |> assign(:image_models, [])
      |> assign(:image_models_error, nil)
      |> assign(:image_models_loading, false)
      |> assign(:edit_capabilities, nil)
      |> assign(:describe_result, nil)
      |> assign(:describing, false)
      |> assign(:edit_inputs, [])
      |> allow_upload(:edit_images,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 2,
        max_file_size: 8_000_000,
        auto_upload: true
      )
      |> assign(:stt_audio, nil)
      |> assign(:stt_audio_src, nil)
      |> assign(:stt_model, "")
      |> assign(:stt_language, "")
      |> assign(:stt_instructions, "")
      |> assign(:stt_transport, "")
      |> assign(:stt_models, [])
      |> assign(:stt_hint, nil)
      |> assign(:stt_running, false)
      |> assign(:stt_error, nil)
      |> assign(:stt_results, [])
      |> assign(:recorder_available, Dictate.recorder_available?())
      |> assign_stt_hint()
      |> allow_upload(:stt_file,
        accept: @stt_accept,
        max_entries: 1,
        max_file_size: Transcription.max_bytes(),
        auto_upload: true,
        progress: &stt_upload_progress/3
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if socket.assigns.enabled_check_done do
      {:noreply, socket}
    else
      handle_initial_params(socket)
    end
  end

  defp handle_initial_params(socket) do
    if AI.enabled?() do
      {endpoints, _total} = AI.list_endpoints(enabled: true, page: 1, page_size: 100)
      prompts = AI.list_prompts(enabled: true)

      socket =
        socket
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:endpoints, endpoints)
        |> assign(:prompts, prompts)
        |> assign(:enabled_check_done, true)

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("AI module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  # ===========================================
  # EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("change", params, socket) do
    socket = apply_form_changes(socket, params)
    {:noreply, socket}
  end

  # The call runs in a task (`start_async`), like every other provider call
  # here, so the page keeps answering while the model thinks. A second send
  # while one is running is ignored: `start_async` under the same name would
  # drop the first, paid answer.
  @impl true
  def handle_event("send", _params, socket) do
    cond do
      is_nil(socket.assigns.selected_endpoint_uuid) ->
        {:noreply, put_flash(socket, :error, gettext("Please select an endpoint"))}

      socket.assigns.sending ->
        {:noreply, socket}

      true ->
        request = chat_request(socket.assigns)

        {:noreply,
         socket
         |> assign(:sending, true)
         |> assign(:response_text, nil)
         |> assign(:response_usage, nil)
         |> assign(:response_error, nil)
         |> start_async(:chat, fn -> execute_request(request) end)}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    socket =
      socket
      |> assign(:response_text, nil)
      |> assign(:response_usage, nil)
      |> assign(:response_error, nil)
      |> assign(:freeform_message, "")
      |> assign(:freeform_system, "")

    {:noreply, socket}
  end

  # ===========================================
  # STREAMING VOICE (xAI REALTIME)
  # ===========================================

  # ── Image edit (PhoenixKitAI.process_image/4, describe_image/3) ──────
  #
  # Its own form: uploads need phx-change on the form that holds the file
  # input, and HTML forbids nesting it in the main one.

  @impl true
  def handle_event("edit_change", params, socket) do
    {:noreply, apply_edit_params(socket, params)}
  end

  # Provider calls never run in the LiveView process: the listing, an
  # edit and a describe each go through start_async, so the page keeps
  # answering (upload removal, endpoint switch, the chat card) meanwhile.
  @impl true
  def handle_event("load_image_models", _params, socket) do
    case socket.assigns.selected_endpoint_uuid do
      nil ->
        {:noreply, assign(socket, :image_models_error, gettext("Please select an endpoint"))}

      uuid ->
        {:noreply,
         socket
         |> assign(:image_models_loading, true)
         |> assign(:image_models_error, nil)
         |> start_async(:image_models, fn -> {uuid, AI.image_models(uuid)} end)}
    end
  end

  @impl true
  def handle_event("edit_clear_inputs", _params, socket) do
    {:noreply, assign(socket, :edit_inputs, [])}
  end

  # The Describe button submits the same form with `action=describe`
  # (the submitter's name/value ride along), so both verbs share the
  # form state and the upload entries.
  @impl true
  def handle_event("edit_send", %{"action" => "describe"} = params, socket),
    do: handle_event("describe_send", params, socket)

  @impl true
  def handle_event("describe_send", params, socket) do
    socket = apply_edit_params(socket, params)

    cond do
      is_nil(socket.assigns.selected_endpoint_uuid) ->
        {:noreply, assign(socket, :edit_error, gettext("Please select an endpoint"))}

      not images_ready?(socket) ->
        {:noreply, assign(socket, :edit_error, gettext("Please add at least one image"))}

      true ->
        {images, socket} = take_images(socket)
        uuid = socket.assigns.selected_endpoint_uuid

        opts =
          [source: "PhoenixKitAI.Web.Playground"]
          |> Keyword.merge(call_opts(socket.assigns))
          |> maybe_opt(:prompt, socket.assigns.edit_prompt)
          |> maybe_opt(:model, socket.assigns.edit_model)

        {:noreply,
         socket
         |> assign(:describing, true)
         |> assign(:edit_error, nil)
         |> assign(:describe_result, nil)
         |> start_async(:describe, fn -> AI.describe_image(uuid, images, opts) end)}
    end
  end

  @impl true
  def handle_event("edit_remove", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :edit_images, ref)}
  end

  @impl true
  def handle_event("edit_send", params, socket) do
    socket = apply_edit_params(socket, params)

    cond do
      is_nil(socket.assigns.selected_endpoint_uuid) ->
        {:noreply, assign(socket, :edit_error, gettext("Please select an endpoint"))}

      not images_ready?(socket) ->
        {:noreply, assign(socket, :edit_error, gettext("Please add at least one image"))}

      edit_operations(socket.assigns) == [] ->
        {:noreply,
         assign(socket, :edit_error, gettext("Pick an operation or write an instruction"))}

      true ->
        {images, socket} = take_images(socket)
        uuid = socket.assigns.selected_endpoint_uuid
        operations = edit_operations(socket.assigns)
        opts = edit_process_opts(socket.assigns)

        {:noreply,
         socket
         |> assign(:editing, true)
         |> assign(:edit_error, nil)
         |> assign(:edit_result, nil)
         |> start_async(:edit, fn -> AI.process_image(uuid, images, operations, opts) end)}
    end
  end

  @impl true
  def handle_event("voice_change", params, socket) do
    socket =
      socket
      |> maybe_update_voice_text(params)
      |> maybe_update_voice_selected(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_voice", _params, socket) do
    if PhoenixKitAI.enabled?(),
      do: start_voice(socket),
      else: {:noreply, ai_off(socket)}
  end

  @impl true
  def handle_event("speak_voice", %{"text" => text}, socket) do
    speak_voice(socket, text)
  end

  @impl true
  def handle_event("stop_voice", _params, socket) do
    if pid = socket.assigns.voice_session_pid, do: Session.close(pid)
    {:noreply, socket}
  end

  # ── Speech to text (PhoenixKitAI.transcribe/3) ──────────────────────────
  #
  # One clip at a time, recorded here (core's recorder) or picked as a file.
  # It stays until it is removed or replaced, so the same words can be run
  # through other models, languages, paths and instructions; the last answers
  # are listed to compare. The settings are the Dictate button's too.

  @impl true
  def handle_event("stt_change", params, socket) do
    {:noreply, apply_stt_params(socket, params)}
  end

  @impl true
  def handle_event("stt_send", params, socket) do
    socket = apply_stt_params(socket, params)

    cond do
      is_nil(socket.assigns.selected_endpoint) ->
        {:noreply, assign(socket, :stt_error, gettext("Please select an endpoint"))}

      is_nil(socket.assigns.stt_audio) ->
        {:noreply, assign(socket, :stt_error, gettext("Record something or pick a file first"))}

      true ->
        {:noreply, run_transcription(socket)}
    end
  end

  @impl true
  def handle_event("stt_remove_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :stt_file, ref)}
  end

  @impl true
  def handle_event("stt_clear_audio", _params, socket) do
    {:noreply, socket |> assign(:stt_audio, nil) |> assign(:stt_audio_src, nil)}
  end

  @impl true
  def handle_event("stt_clear_results", _params, socket) do
    {:noreply, assign(socket, :stt_results, [])}
  end

  # The words of one answer as the chat message, to send them on. A chosen
  # prompt template is left for the freeform message, which is where they go.
  @impl true
  def handle_event("stt_use_text", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.stt_results, &(Integer.to_string(&1.id) == id)) do
      %{text: text} when text != "" ->
        socket =
          if socket.assigns.selected_prompt, do: apply_prompt_selection(socket, nil), else: socket

        {:noreply,
         socket
         |> assign(:freeform_message, text)
         |> put_flash(:info, gettext("The words are in the chat message above."))}

      _ ->
        {:noreply, socket}
    end
  end

  defp start_voice(socket) do
    case socket.assigns.selected_endpoint do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Please select an endpoint"))}

      endpoint ->
        if Endpoint.realtime_voice_capable?(endpoint.provider) do
          {:noreply, start_voice_session(socket, endpoint)}
        else
          {:noreply,
           put_flash(socket, :error, gettext("Selected endpoint does not support realtime voice"))}
        end
    end
  end

  defp speak_voice(socket, text) do
    cond do
      not PhoenixKitAI.enabled?() ->
        {:noreply, ai_off(socket)}

      socket.assigns.voice_status == :connected and socket.assigns.voice_session_pid ->
        Session.send_text(socket.assigns.voice_session_pid, text)
        Session.finish(socket.assigns.voice_session_pid)
        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  # Off is off: the realtime voice session runs no AI task, so the module
  # switch is checked here (and again by the session on every send). An
  # open session is closed; its `:DOWN` resets the panel to idle.
  defp ai_off(socket) do
    if pid = socket.assigns.voice_session_pid, do: Session.close(pid)
    put_flash(socket, :error, gettext("The AI module is switched off."))
  end

  defp start_voice_session(socket, endpoint) do
    api_key = OpenRouterClient.resolve_api_key(endpoint)

    # sample_rate is explicit (not left to Xai.Realtime's own default) since
    # the XaiVoiceStream JS hook decodes raw PCM and must agree with it.
    #
    # `:realtime_module` is empty in production and only set in tests
    # (`Application.put_env(:phoenix_kit_ai, :realtime_module, Mock)`) —
    # same test-seam convention as `Completion.http_post/3`'s `:req_options`.
    spec = {
      Session,
      live_view_pid: self(),
      api_key: api_key,
      voice: socket.assigns.voice_selected,
      codec: "pcm",
      sample_rate: 24_000,
      realtime_module: Application.get_env(:phoenix_kit_ai, :realtime_module, Xai.Realtime)
    }

    case DynamicSupervisor.start_child(PhoenixKitAI.Realtime.Supervisor, spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        socket
        |> assign(:voice_session_pid, pid)
        |> assign(:voice_monitor_ref, ref)
        |> assign(:voice_status, :connected)
        |> assign(:voice_error, nil)

      {:error, reason} ->
        Logger.warning(
          "[PhoenixKitAI.Web.Playground] failed to start xAI realtime voice session: " <>
            MessageShape.describe(reason)
        )

        socket
        |> assign(:voice_status, :error)
        |> assign(:voice_error, gettext("Could not connect to xAI realtime voice"))
    end
  end

  defp maybe_update_voice_text(socket, %{"text" => text}), do: assign(socket, :voice_text, text)
  defp maybe_update_voice_text(socket, _params), do: socket

  # Voice is fixed for the lifetime of a connection (baked into the
  # WebSocket URL at connect time — see Xai.Realtime.connect_tts/1), so
  # changing it only matters while not yet connected; the template
  # disables the select once `@voice_status == :connected`.
  defp maybe_update_voice_selected(socket, %{"voice" => voice}) when voice != "" do
    assign(socket, :voice_selected, voice)
  end

  defp maybe_update_voice_selected(socket, _params), do: socket

  # Form change helpers

  defp apply_form_changes(socket, params) do
    socket
    |> maybe_update_endpoint(params)
    |> maybe_update_prompt(params)
    |> maybe_update_content(params)
    |> maybe_update_variables(params)
    |> maybe_update_freeform(params)
  end

  defp maybe_update_endpoint(socket, %{"endpoint_uuid" => uuid}) do
    uuid = if uuid == "", do: nil, else: uuid

    # Guard on change: this whole form shares one `phx-change`, so this runs
    # on every keystroke elsewhere in the form too, not just when the
    # endpoint select itself changes.
    if uuid == socket.assigns.selected_endpoint_uuid do
      socket
    else
      endpoint = Enum.find(socket.assigns.endpoints, &(&1.uuid == uuid))

      socket
      |> maybe_close_voice_session()
      |> assign(:selected_endpoint_uuid, uuid)
      |> assign(:selected_endpoint, endpoint)
      |> assign(:voice_options, @default_voice_options)
      |> assign(:voice_selected, "eve")
      |> assign(:image_models, [])
      |> assign(:image_models_error, nil)
      |> assign(:edit_capabilities, nil)
      |> assign(:edit_model, "")
      |> assign(:edit_options, %{})
      |> assign(:edit_result, nil)
      |> assign(:describe_result, nil)
      # A's model override would name a model B may not have; the clip, the
      # other settings and the answers (each names its endpoint) stay, so
      # two endpoints can be compared on one recording.
      |> assign(:stt_model, "")
      |> assign(:stt_models, hearing_models(endpoint))
      |> assign_stt_hint()
      |> maybe_fetch_xai_voices(endpoint)
    end
  end

  defp maybe_update_endpoint(socket, _), do: socket

  # Switching to a different endpoint mid-stream would otherwise leak the
  # xAI WebSocket connection — the panel disappears from view, but nothing
  # else would ever call `Session.close/1` for it.
  defp maybe_close_voice_session(%{assigns: %{voice_session_pid: pid}} = socket)
       when is_pid(pid) do
    Session.close(pid)
    socket
  end

  defp maybe_close_voice_session(socket), do: socket

  # Live-fetches xAI's voice catalogue (built-ins + any custom/cloned
  # voices on the account) so the dropdown isn't stuck on the hardcoded
  # built-in fallback. Deferred via `send(self(), ...)` rather than called
  # inline — this runs inside the shared `phx-change="change"` handler,
  # and an HTTP round trip has no business blocking every keystroke in
  # the rest of the form.
  defp maybe_fetch_xai_voices(socket, %{provider: provider, uuid: uuid}) do
    if Endpoint.realtime_voice_capable?(provider) do
      send(self(), {:fetch_xai_voices, uuid})
    end

    socket
  end

  defp maybe_fetch_xai_voices(socket, _endpoint), do: socket

  defp maybe_update_prompt(socket, %{"prompt_uuid" => uuid}) do
    uuid = if uuid == "", do: nil, else: uuid

    # Only re-initialize when the prompt actually changes
    if uuid == socket.assigns.selected_prompt_uuid do
      socket
    else
      apply_prompt_selection(socket, uuid)
    end
  end

  defp maybe_update_prompt(socket, _), do: socket

  defp apply_prompt_selection(socket, uuid) do
    prompt = uuid && Enum.find(socket.assigns.prompts, &(&1.uuid == uuid))
    edited_content = if prompt, do: prompt.content, else: nil
    variables = if prompt, do: Prompt.extract_variables(edited_content || ""), else: []
    variable_values = if prompt, do: Map.new(variables, fn var -> {var, ""} end), else: %{}

    socket
    |> assign(:selected_prompt_uuid, uuid)
    |> assign(:selected_prompt, prompt)
    |> assign(:edited_content, edited_content)
    |> assign(:edited_variables, variables)
    |> assign(:variable_values, variable_values)
    |> assign(:response_text, nil)
    |> assign(:response_usage, nil)
    |> assign(:response_error, nil)
  end

  defp maybe_update_content(socket, %{"edited_content" => content}) do
    new_vars = Prompt.extract_variables(content)
    old_vars = socket.assigns.edited_variables

    # Preserve existing variable values, add empty for new ones
    variable_values =
      if new_vars != old_vars do
        Map.new(new_vars, fn var ->
          {var, Map.get(socket.assigns.variable_values, var, "")}
        end)
      else
        socket.assigns.variable_values
      end

    socket
    |> assign(:edited_content, content)
    |> assign(:edited_variables, new_vars)
    |> assign(:variable_values, variable_values)
  end

  defp maybe_update_content(socket, _), do: socket

  defp maybe_update_variables(socket, %{"variables" => variables}) when is_map(variables) do
    assign(socket, :variable_values, Map.merge(socket.assigns.variable_values, variables))
  end

  defp maybe_update_variables(socket, _), do: socket

  defp maybe_update_freeform(socket, params) do
    socket
    |> then(fn s ->
      case Map.get(params, "message") do
        nil -> s
        msg -> assign(s, :freeform_message, msg)
      end
    end)
    |> then(fn s ->
      case Map.get(params, "system") do
        nil -> s
        sys -> assign(s, :freeform_system, sys)
      end
    end)
  end

  # A clip from the recorder: kept as the card's clip and written down at
  # once (the recorder's own Send is the person's go). Errors are the
  # recorder's to show (`errors: :inline`), so there is no error message.
  @impl true
  def handle_info({:audio_recorded, @stt_recorder, clip}, socket) do
    case clip |> Map.take([:data, :format]) |> Transcription.normalize() do
      {:ok, _audio} = read ->
        socket = put_clip(read, socket, gettext("Recording"))

        if socket.assigns.selected_endpoint,
          do: {:noreply, run_transcription(socket)},
          else: {:noreply, socket}

      # Not the earlier clip in its place: that one was not what was just said.
      {:error, _reason} = error ->
        {:noreply, put_clip(error, socket, nil)}
    end
  end

  # The Dictate button under the chat message: its `into` already put the
  # words in the field, and the field's `input` event brings them here.
  @impl true
  def handle_info({:dictated, "playground-dictate", _text}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:xai_audio_chunk, chunk}, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.Playground] xai audio chunk received: #{byte_size(chunk)} bytes"
    end)

    {:noreply, push_event(socket, "xai-audio-chunk", %{data: Base.encode64(chunk)})}
  end

  @impl true
  def handle_info({:xai_realtime_event, %{"type" => "error", "message" => message}}, socket) do
    {:noreply, socket |> assign(:voice_status, :error) |> assign(:voice_error, message)}
  end

  # Every other realtime event (acks, "text.done" echoes, unrecognized
  # shapes) — logged rather than silently dropped, since this is the only
  # visibility into whether xAI's realtime endpoint is responding at all.
  # By its type only: a "text.done" echo carries the words typed to speak.
  @impl true
  def handle_info({:xai_realtime_event, event}, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.Playground] xai realtime event: #{realtime_event_type(event)}"
    end)

    {:noreply, socket}
  end

  # Stale-fetch guard: if the operator picked a different endpoint between
  # `send/2` and this message arriving, `uuid` no longer matches — drop it
  # rather than repopulating the voice list for the wrong endpoint.
  #
  # The message names the endpoint only; the key is resolved here so a
  # credential never sits in the mailbox.
  @impl true
  def handle_info({:fetch_xai_voices, uuid}, socket) do
    with true <- socket.assigns.selected_endpoint_uuid == uuid,
         %Endpoint{} = endpoint <- AI.get_endpoint(uuid),
         api_key when is_binary(api_key) and api_key != "" <-
           OpenRouterClient.resolve_api_key(endpoint),
         {:ok, [_ | _] = voices} <- OpenRouterClient.fetch_xai_voices(api_key) do
      options = Enum.map(voices, &{&1.name, &1.voice_id})
      {:noreply, assign(socket, :voice_options, options)}
    else
      # Keep the built-in fallback list already assigned — better
      # than an empty dropdown.
      _ -> {:noreply, socket}
    end
  end

  # The realtime session ended — either the user clicked "Disconnect"
  # (`Session.close/1`, reason `:normal`) or the connection died on its own
  # (xai's own reconnect/backoff gave up). Either way, reset to idle/error.
  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{assigns: %{voice_monitor_ref: ref, voice_session_pid: pid}} = socket
      ) do
    socket =
      socket
      |> assign(:voice_session_pid, nil)
      |> assign(:voice_monitor_ref, nil)
      |> assign(:voice_status, if(reason == :normal, do: :idle, else: :error))

    {:noreply, socket}
  end

  # Catch-all for unmatched messages (PubSub from other modules, late
  # replies after navigation, etc.). Log at :debug per the workspace
  # sync precedent — never silently swallow a message we didn't expect.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.Playground] unhandled handle_info: #{MessageShape.describe(msg)}"
    end)

    {:noreply, socket}
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp realtime_event_type(%{"type" => type}) when is_binary(type), do: inspect(type)
  defp realtime_event_type(event), do: MessageShape.describe(event)

  # What the chat call needs, taken from the assigns before the task starts,
  # so the task does not copy the whole socket state (a kept clip included).
  defp chat_request(assigns) do
    prompt = assigns.selected_prompt

    %{
      endpoint_uuid: assigns.selected_endpoint_uuid,
      # Use edited content (user may have modified the template)
      prompt: prompt && %{prompt | content: assigns.edited_content || prompt.content},
      variable_values: assigns.variable_values,
      message: assigns.freeform_message,
      system: assigns.freeform_system,
      call_opts: call_opts(assigns)
    }
  end

  defp execute_request(%{prompt: %Prompt{} = prompt} = request),
    do:
      execute_prompt_request(
        request.endpoint_uuid,
        prompt,
        request.variable_values,
        request.call_opts
      )

  defp execute_request(request),
    do:
      execute_freeform_request(
        request.endpoint_uuid,
        request.message,
        request.system,
        request.call_opts
      )

  defp execute_prompt_request(endpoint_uuid, prompt, variable_values, call_opts) do
    with {:ok, rendered_content} <- Prompt.render(prompt, variable_values),
         {:ok, rendered_system} <- Prompt.render_system_prompt(prompt, variable_values) do
      opts =
        [
          source: "Playground",
          prompt_uuid: prompt.uuid,
          prompt_name: prompt.name
        ]
        |> Keyword.merge(call_opts)
        |> maybe_add_system(rendered_system)

      case AI.ask(endpoint_uuid, rendered_content, opts) do
        {:ok, response} ->
          AI.increment_prompt_usage(prompt.uuid)
          {:ok, extract_text(response), response_usage(response, endpoint_uuid)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_freeform_request(endpoint_uuid, message, system, call_opts) do
    opts =
      [source: "Playground"]
      |> Keyword.merge(call_opts)
      |> maybe_add_system(if(String.trim(system) == "", do: nil, else: system))

    with :ok <- if(String.trim(message) == "", do: {:error, :empty_input}, else: :ok),
         {:ok, response} <- AI.ask(endpoint_uuid, message, opts) do
      {:ok, extract_text(response), response_usage(response, endpoint_uuid)}
    end
  end

  # The provider's `usage.cost` is one source of a call's cost (OpenRouter's).
  # The others — a catalogue price, one entered on the endpoint, Anthropic's
  # built-in rates — are only in the usage row the call wrote
  # (`PhoenixKitAI.CallCost`), so that row is read when the answer has none,
  # and only if it is a row of the endpoint the call went to. With an
  # asynchronous usage log (`request_log_mode: :async`) the row may only be
  # queued yet, so it is waited for once, two seconds at most. No row or no
  # price: no cost, as for an answer without one. With the request cache on, a
  # repeat shows "$0.00" (the cache hit's row has cost 0), while an OpenRouter
  # answer keeps the `usage.cost` of the original one.
  @doc false
  @spec response_usage(map(), String.t()) :: map()
  def response_usage(response, endpoint_uuid) do
    case Completion.extract_usage(response) do
      %{cost: nil} = usage ->
        %{usage | cost: logged_cost(response["request_uuid"], endpoint_uuid)}

      usage ->
        usage
    end
  end

  defp logged_cost(uuid, endpoint_uuid) when is_binary(uuid) do
    case logged_row(uuid) do
      %{cost: cost, endpoint_uuid: ^endpoint_uuid} -> cost
      _ -> nil
    end
  end

  defp logged_cost(_uuid, _endpoint_uuid), do: nil

  # The row is there when the verb returns, unless the usage log is
  # asynchronous: the answer then names a row that is only queued. When it is
  # not there yet, wait once for the queue to be written and read again. A log
  # written by the caller itself is already there. Queue capacity only decides
  # how a NEW row is written: a full queue can still hold this call's row.
  defp logged_row(uuid) do
    case AI.get_request(uuid) do
      nil -> if RequestLog.async_mode?(), do: flush_then_get(uuid)
      row -> row
    end
  end

  # A timeout or a dead writer still gets one more read: the insert comes
  # before the sinks, so the row may be there already.
  defp flush_then_get(uuid) do
    RequestLog.flush(2_000)
    AI.get_request(uuid)
  catch
    :exit, _reason -> AI.get_request(uuid)
  end

  defp maybe_add_system(opts, nil), do: opts
  defp maybe_add_system(opts, system), do: Keyword.put(opts, :system, system)

  defp extract_text(response) do
    case Completion.extract_content(response) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> gettext("(No content in response)")
    end
  end

  # The model list names the endpoint it was read for and is dropped once the
  # endpoint changed: A's models in B's select would send B a model it does not
  # have. An edit or a description is a paid answer, so it is shown whichever
  # endpoint is selected by then, under the model that gave it. None of the tasks
  # is cancelled on a change, because killing a paid call would lose its usage row.
  @impl true
  def handle_async(:image_models, {:ok, {uuid, result}}, socket) do
    socket = assign(socket, :image_models_loading, false)

    if socket.assigns.selected_endpoint_uuid == uuid,
      do: image_models_loaded(result, socket),
      else: {:noreply, socket}
  end

  def handle_async(:edit, {:ok, result}, socket),
    do: edit_finished(result, assign(socket, :editing, false))

  def handle_async(:describe, {:ok, result}, socket),
    do: describe_finished(result, assign(socket, :describing, false))

  def handle_async(:chat, {:ok, result}, socket),
    do: {:noreply, socket |> assign(:sending, false) |> chat_finished(result)}

  def handle_async(:transcribe, {:ok, {run, result}}, socket),
    do: {:noreply, socket |> assign(:stt_running, false) |> transcription_finished(run, result)}

  def handle_async(:chat, {:exit, reason}, socket) do
    log_task_exit(:chat, reason)

    {:noreply,
     socket |> assign(:sending, false) |> assign(:response_error, task_failed_message())}
  end

  def handle_async(:transcribe, {:exit, reason}, socket) do
    log_task_exit(:transcribe, reason)
    {:noreply, socket |> assign(:stt_running, false) |> assign(:stt_error, task_failed_message())}
  end

  # One clause per task: each resets only its own busy flag, so a crashed
  # model listing does not re-enable the buttons of an edit still running.
  def handle_async(:image_models, {:exit, reason}, socket) do
    log_task_exit(:image_models, reason)

    {:noreply,
     socket
     |> assign(:image_models_loading, false)
     |> assign(:image_models_error, task_failed_message())}
  end

  def handle_async(:edit, {:exit, reason}, socket) do
    log_task_exit(:edit, reason)
    {:noreply, socket |> assign(:editing, false) |> assign(:edit_error, task_failed_message())}
  end

  def handle_async(:describe, {:exit, reason}, socket) do
    log_task_exit(:describe, reason)
    {:noreply, socket |> assign(:describing, false) |> assign(:edit_error, task_failed_message())}
  end

  defp image_models_loaded({:ok, models}, socket) do
    {:noreply,
     socket
     |> assign(:image_models, models)
     |> assign(:image_models_error, nil)
     |> assign_edit_capabilities()}
  end

  defp image_models_loaded({:error, :not_supported}, socket) do
    {:noreply,
     assign(socket, :image_models_error, gettext("This provider publishes no image model list"))}
  end

  defp image_models_loaded({:error, reason}, socket),
    do: {:noreply, assign(socket, :image_models_error, PhoenixKitAI.Errors.message(reason))}

  defp edit_finished({:ok, %{images: [image | _]} = response}, socket) do
    {:noreply,
     socket
     |> assign(:edit_result, %{
       src: image_src(image),
       text: Map.get(response, :text),
       prompt: Map.get(response, :prompt),
       warnings: Map.get(response, :warnings, []),
       model: Map.get(response, :model),
       verification: Map.get(response, :verification)
     })}
  end

  defp edit_finished({:ok, _}, socket),
    do: {:noreply, assign(socket, :edit_error, gettext("The model returned no image"))}

  defp edit_finished({:error, reason}, socket),
    do: {:noreply, assign(socket, :edit_error, PhoenixKitAI.Errors.message(reason))}

  defp describe_finished({:ok, %{text: text, model: model}}, socket),
    do: {:noreply, assign(socket, :describe_result, %{text: text, model: model})}

  defp describe_finished({:error, reason}, socket),
    do: {:noreply, assign(socket, :edit_error, PhoenixKitAI.Errors.message(reason))}

  defp chat_finished(socket, {:ok, text, usage}) do
    socket
    |> assign(:response_text, text)
    |> assign(:response_usage, usage)
    |> assign(:response_error, nil)
  end

  defp chat_finished(socket, {:error, reason}),
    do: assign(socket, :response_error, PhoenixKitAI.Errors.message(reason))

  # The shape of the exit only: an exception's message, or a raw exit
  # reason's arguments, can carry the prompt, the image or the recording.
  defp log_task_exit(task, reason) do
    Logger.warning(
      "[PhoenixKitAI.Web.Playground] #{task} task exited: #{MessageShape.describe_exit(reason)}"
    )
  end

  defp task_failed_message, do: gettext("Something went wrong on our side. Please try again.")

  # ── Image edit form state ──────────────────────────────────────────────

  # The image-edit form posts the free text, the checked operations
  # (`ops[]`), the option selects (`opt[<name>]`), the model override and
  # the verify checkbox. A checkbox that is unchecked is simply absent, so
  # the whole state is rebuilt from what arrived.
  defp apply_edit_params(socket, params) do
    socket
    |> assign(:edit_prompt, Map.get(params, "edit_prompt", socket.assigns.edit_prompt))
    |> assign(:edit_operations, params |> Map.get("ops", []) |> List.wrap())
    |> assign(:edit_options, edit_option_params(params["opt"]))
    |> assign(:edit_model, Map.get(params, "edit_model", socket.assigns.edit_model))
    |> assign(:edit_verify, Map.get(params, "verify") in ["true", "on"])
    |> assign_edit_capabilities()
  end

  # Uploads are consumed once and their bytes kept on the socket (until
  # "Clear" or a new pick), so Describe and Edit can both run on one pick
  # and any call can be re-run with other operations without picking again.
  defp images_ready?(socket) do
    socket.assigns.edit_inputs != [] or
      Enum.any?(socket.assigns.uploads.edit_images.entries, & &1.done?)
  end

  defp take_images(socket) do
    fresh =
      consume_uploaded_entries(socket, :edit_images, fn %{path: path}, entry ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, %{data: bytes, content_type: image_type(entry)}}
          {:error, _} -> {:ok, nil}
        end
      end)
      |> Enum.reject(&is_nil/1)

    images = if fresh == [], do: socket.assigns.edit_inputs, else: fresh
    {images, assign(socket, :edit_inputs, images)}
  end

  # Checked operations first, the free text (if any) as a final instruction.
  defp edit_operations(assigns) do
    known = AI.image_operations()

    checked =
      for name <- assigns.edit_operations,
          op = Enum.find(Map.keys(known), &(Atom.to_string(&1) == name)),
          do: op

    case String.trim(assigns.edit_prompt || "") do
      "" -> checked
      text -> checked ++ [{:instruction, text: text}]
    end
  end

  defp edit_process_opts(assigns) do
    allowed = Map.new(PhoenixKitAI.Images.request_options(), &{Atom.to_string(&1), &1})

    options =
      for {key, value} <- assigns.edit_options,
          atom = Map.get(allowed, key),
          do: {atom, value}

    options
    |> Keyword.put(:source, "PhoenixKitAI.Web.Playground")
    |> Keyword.merge(call_opts(assigns))
    |> Keyword.put(:verify, assigns.edit_verify)
    |> maybe_opt(:model, assigns.edit_model)
  end

  # Every Playground call is the `ai.playground` task, made by the signed-in
  # user, so per-user caps and the task's rules apply to it.
  defp call_opts(assigns) do
    [task: "ai.playground"]
    |> then(fn opts ->
      case PhoenixKitWeb.Actor.uuid(assigns) do
        nil -> opts
        user_uuid -> Keyword.put(opts, :user_uuid, user_uuid)
      end
    end)
  end

  defp edit_option_params(opt) when is_map(opt),
    do: Map.reject(opt, fn {_k, v} -> v in [nil, ""] end)

  defp edit_option_params(_opt), do: %{}

  defp maybe_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, String.trim(value))

  # The capability entry for the model the card will use, or nil. Kept as
  # an assign, recomputed when the listing, the override or the endpoint
  # changes, so the template never hands the whole assigns map to a
  # function (which would switch off change tracking for the card).
  defp assign_edit_capabilities(socket),
    do: assign(socket, :edit_capabilities, edit_capabilities(socket.assigns))

  defp edit_capabilities(%{image_models: []}), do: nil

  defp edit_capabilities(%{
         image_models: models,
         edit_model: override,
         selected_endpoint: endpoint
       }) do
    id = if override in [nil, ""], do: endpoint && endpoint.model, else: override
    Enum.find(models, &(&1.id == id))
  end

  # ── Speech to text state ───────────────────────────────────────────────

  defp apply_stt_params(socket, params) do
    socket
    |> assign(:stt_model, Map.get(params, "stt_model", socket.assigns.stt_model))
    |> assign(:stt_language, Map.get(params, "stt_language", socket.assigns.stt_language))
    |> assign(
      :stt_instructions,
      Map.get(params, "stt_instructions", socket.assigns.stt_instructions)
    )
    |> assign(:stt_transport, stt_transport_param(params, socket.assigns.stt_transport))
    |> assign_stt_hint()
  end

  defp stt_transport_param(%{"stt_transport" => value}, _current)
       when value in ["", "chat", "transcriptions"],
       do: value

  defp stt_transport_param(_params, current), do: current

  # A second clip while one is being written down waits for the button: a
  # `start_async` under the running name would drop the first, paid answer.
  defp run_transcription(%{assigns: %{stt_running: true}} = socket), do: socket

  defp run_transcription(socket) do
    %{selected_endpoint: endpoint, stt_audio: audio} = socket.assigns
    opts = stt_opts(socket.assigns)

    run = %{
      endpoint_name: endpoint.name,
      clip: audio.name,
      language_hint: opts[:language],
      instructions?: opts[:instructions] != nil
    }

    input = %{data: audio.data, format: audio.format}

    socket
    |> assign(:stt_running, true)
    |> assign(:stt_error, nil)
    |> start_async(:transcribe, fn ->
      started = System.monotonic_time(:millisecond)
      result = AI.transcribe(endpoint, input, opts)
      {Map.put(run, :elapsed_ms, System.monotonic_time(:millisecond) - started), result}
    end)
  end

  # The card's settings as `transcribe/3` options, every Playground call's
  # task and user included. The Dictate button takes the same ones.
  defp stt_opts(assigns) do
    [source: "PhoenixKitAI.Web.Playground"]
    |> Keyword.merge(call_opts(assigns))
    |> maybe_opt(:model, assigns.stt_model)
    |> maybe_opt(:language, assigns.stt_language)
    |> maybe_opt(:instructions, assigns.stt_instructions)
    |> put_transport(assigns.stt_transport)
  end

  defp put_transport(opts, "chat"), do: Keyword.put(opts, :transport, :chat)
  defp put_transport(opts, "transcriptions"), do: Keyword.put(opts, :transport, :transcriptions)
  defp put_transport(opts, _auto), do: opts

  # The Dictate button's attributes (they are `transcribe/3` options): the
  # card's model, language, instructions and path. Kept as an assign, so the
  # template hands the component a map rather than the whole assigns.
  defp dictate_opts(assigns) do
    assigns
    |> stt_opts()
    |> Keyword.drop([:source])
    |> Map.new()
    |> Map.put(:source, "PhoenixKitAI.Web.Playground.Dictate")
  end

  defp transcription_finished(socket, run, {:ok, result}) do
    entry =
      result
      |> Map.take([:text, :language, :model, :transport, :duration, :cost, :request_uuid])
      |> Map.merge(run)
      |> Map.put(:id, System.unique_integer([:positive]))

    socket
    |> assign(:stt_error, nil)
    |> assign(:stt_results, Enum.take([entry | socket.assigns.stt_results], @stt_kept_results))
  end

  defp transcription_finished(socket, _run, {:error, reason}),
    do: assign(socket, :stt_error, PhoenixKitAI.Errors.message(reason))

  # A picked file is read as soon as it is up, so a recording and a file
  # are one clip to the rest of the card. The format comes from the bytes;
  # the file's extension only where they do not say it.
  defp stt_upload_progress(:stt_file, %{done?: true} = entry, socket) do
    read = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read(path)} end)

    result =
      with {:ok, bytes} <- read do
        case Transcription.normalize(bytes) do
          {:error, :unknown_audio_format} ->
            Transcription.normalize(bytes,
              format: entry.client_name |> Path.extname() |> String.trim_leading(".")
            )

          normalized ->
            normalized
        end
      end

    {:noreply, put_clip(result, socket, entry.client_name)}
  end

  defp stt_upload_progress(:stt_file, _entry, socket), do: {:noreply, socket}

  defp put_clip({:ok, audio}, socket, name) do
    socket
    |> assign(:stt_audio, Map.put(audio, :name, name))
    |> assign(:stt_audio_src, playable_src(audio))
    |> assign(:stt_error, nil)
  end

  defp put_clip({:error, reason}, socket, _name),
    do: assign(socket, :stt_error, PhoenixKitAI.Errors.message(reason))

  defp playable_src(%{bytes: bytes, data: data, content_type: type})
       when bytes <= @stt_playable_bytes,
       do: "data:#{type};base64,#{Base.encode64(data)}"

  defp playable_src(_audio), do: nil

  # The models the capability cache says hear, at the endpoint's provider,
  # for the model field's suggestions. A speech-to-text model (whisper and
  # the like) is in no chat catalogue, so it is typed in.
  defp hearing_models(nil), do: []

  defp hearing_models(%Endpoint{} = endpoint) do
    endpoint
    |> Capabilities.resolved_base_url()
    |> Capabilities.catalogue()
    |> Enum.filter(fn {_id, caps} -> caps.audio_input == :yes and caps.text_output != false end)
    |> Enum.map(fn {id, caps} -> {id, caps.name} end)
    |> Enum.sort()
  end

  defp assign_stt_hint(socket) do
    socket
    |> assign(:stt_hint, stt_hint(socket.assigns))
    |> assign(:dictate_opts, dictate_opts(socket.assigns))
  end

  # Which path the card's settings take, and on the chat path whether the
  # model is known to hear — what the guard will decide before any call.
  defp stt_hint(%{selected_endpoint: nil}), do: nil

  defp stt_hint(%{selected_endpoint: endpoint} = assigns) do
    opts = assigns |> stt_opts() |> Keyword.take([:model, :transport])
    model = opts[:model] || endpoint.model

    case Transcription.transport(endpoint, opts) do
      :transcriptions ->
        %{transport: :transcriptions, model: model, auto: is_nil(opts[:transport])}

      :chat ->
        %{
          transport: :chat,
          model: model,
          auto: is_nil(opts[:transport]),
          hears: hears(%{endpoint | model: model}),
          verified_only: Guard.verified_only?()
        }
    end
  end

  defp hears(endpoint) do
    case Capabilities.for_endpoint(endpoint) do
      %Capabilities{audio_input: flag} -> flag
      :unknown -> :unknown
    end
  end

  @doc false
  @spec stt_hint_text(map()) :: String.t()
  def stt_hint_text(%{transport: :transcriptions, model: model}) do
    gettext(
      "%{model} gets the recording through the speech-to-text API (/audio/transcriptions). Nothing checks beforehand that it is a speech-to-text model.",
      model: model
    )
  end

  def stt_hint_text(%{transport: :chat, model: model, hears: :yes}) do
    gettext("%{model} takes audio: the recording goes to it in a chat message.", model: model)
  end

  def stt_hint_text(%{transport: :chat, model: model, hears: :no}) do
    gettext(
      "%{model} does not take audio, so the call will be refused. Pick a model that does, or the speech-to-text API for a speech-to-text model.",
      model: model
    )
  end

  def stt_hint_text(%{transport: :chat, model: model, verified_only: true}) do
    gettext(
      "Nobody has verified that %{model} takes audio, so the call will be refused while only verified models are allowed.",
      model: model
    )
  end

  def stt_hint_text(%{transport: :chat, model: model}) do
    gettext(
      "Nobody has verified that %{model} takes audio. The call is made; a model that does not hear answers with an error.",
      model: model
    )
  end

  @doc false
  @spec stt_hint_class(map()) :: String.t()
  def stt_hint_class(%{hears: :no}), do: "text-error"
  def stt_hint_class(%{hears: :unknown, verified_only: true}), do: "text-warning"
  def stt_hint_class(_hint), do: "text-base-content/60"

  @doc false
  @spec transport_label(atom() | nil) :: String.t()
  def transport_label(:chat), do: gettext("Chat with the audio attached")
  def transport_label(:transcriptions), do: gettext("Speech-to-text API")
  def transport_label(_transport), do: gettext("Automatic")

  @doc false
  @spec auto_transport_label(map() | nil) :: String.t()
  def auto_transport_label(%{auto: true, transport: transport}),
    do: gettext("Automatic (%{path})", path: transport_label(transport))

  def auto_transport_label(_hint), do: transport_label(nil)

  @doc false
  @spec stt_accept() :: [String.t()]
  def stt_accept, do: @stt_accept

  @doc false
  @spec format_seconds(number() | nil) :: String.t() | nil
  def format_seconds(seconds) when is_number(seconds),
    do: gettext("%{seconds} s", seconds: :erlang.float_to_binary(seconds * 1.0, decimals: 1))

  def format_seconds(_seconds), do: nil

  @doc false
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when bytes >= 1_000_000,
    do: gettext("%{size} MB", size: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1))

  def format_bytes(bytes), do: gettext("%{size} kB", size: max(1, div(bytes + 500, 1000)))

  @doc false
  @spec upload_error_label(atom()) :: String.t()
  def upload_error_label(:too_large) do
    gettext("That file is too large (%{size} at most)",
      size: format_bytes(Transcription.max_bytes())
    )
  end

  def upload_error_label(:not_accepted), do: gettext("That file is not a recording")
  def upload_error_label(:too_many_files), do: gettext("One file at a time")
  def upload_error_label(other), do: upload_error_message(other)

  @doc false
  @spec option_label(atom()) :: String.t()
  def option_label(:aspect_ratio), do: gettext("Aspect ratio")
  def option_label(:resolution), do: gettext("Resolution")
  def option_label(:quality), do: gettext("Quality")
  def option_label(:background), do: gettext("Background")
  def option_label(:output_format), do: gettext("Output format")
  def option_label(key), do: key |> Atom.to_string() |> String.replace("_", " ")

  @doc false
  @spec warning_message(term()) :: String.t()
  def warning_message({:dropped_option, key, value}),
    do:
      gettext("%{option} was dropped: the model does not accept %{value}",
        option: key,
        value: shown(value)
      )

  def warning_message({:adjusted_option, key, from, to}),
    do:
      gettext("%{option} was changed from %{from} to %{to}",
        option: key,
        from: shown(from),
        to: shown(to)
      )

  def warning_message({:model_not_listed, model}),
    do:
      gettext("The provider's model list does not include %{model}; options were not checked",
        model: model
      )

  def warning_message({:capabilities_unavailable, _reason}),
    do: gettext("The provider's model list could not be fetched; options were not checked")

  def warning_message({:output_not_fetched, _url, _reason}),
    do: gettext("An output image could not be downloaded and is shown from the provider's link")

  def warning_message(other), do: inspect(PhoenixKitAI.Images.redact_warning(other))

  defp shown({:bytes, n}),
    do: ngettext("%{count} byte of image data", "%{count} bytes of image data", n)

  defp shown(value) when is_binary(value), do: value
  defp shown(value), do: inspect(value)

  @doc false
  @spec upload_error_message(atom()) :: String.t()
  def upload_error_message(:too_large), do: gettext("That file is too large (8 MB at most)")

  def upload_error_message(:not_accepted),
    do: gettext("Only JPEG, PNG and WebP images are accepted")

  def upload_error_message(:too_many_files), do: gettext("Two images at most")
  def upload_error_message(other), do: inspect(other)

  defp image_type(%{client_type: type}) when is_binary(type) and type != "", do: type
  defp image_type(_entry), do: "image/jpeg"

  # Inline the bytes; providers that hand back a URL (xAI) are shown from it.
  defp image_src(%{data: data, content_type: type}) when is_binary(data),
    do: "data:#{type || "image/png"};base64,#{Base.encode64(data)}"

  # A provider URL is rendered only when it is a web or image URL — never
  # a scheme a compromised response could smuggle into the admin's page.
  defp image_src(%{url: "https://" <> _ = url}), do: url
  defp image_src(%{url: "http://" <> _ = url}), do: url
  defp image_src(%{url: "data:image/" <> _ = url}), do: url
  defp image_src(_image), do: nil
end
