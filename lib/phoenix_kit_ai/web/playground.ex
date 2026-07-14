defmodule PhoenixKitAI.Web.Playground do
  @moduledoc """
  LiveView for testing AI endpoints and prompts.

  Provides an interactive playground where admins can:
  - Select an endpoint and optionally a prompt
  - Fill in prompt variables
  - Send requests and see AI responses
  - Type freeform messages when no prompt is selected
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.Completion
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.OpenRouterClient
  alias PhoenixKitAI.Prompt
  alias PhoenixKitAI.Realtime.Session

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
      |> assign(:page_title, "AI Playground")
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

  @impl true
  def handle_event("send", _params, socket) do
    endpoint_uuid = socket.assigns.selected_endpoint_uuid

    if is_nil(endpoint_uuid) do
      {:noreply, put_flash(socket, :error, gettext("Please select an endpoint"))}
    else
      socket =
        socket
        |> assign(:sending, true)
        |> assign(:response_text, nil)
        |> assign(:response_usage, nil)
        |> assign(:response_error, nil)

      send(self(), :do_send)
      {:noreply, socket}
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

  @impl true
  def handle_event("voice_change", %{"text" => text}, socket) do
    {:noreply, assign(socket, :voice_text, text)}
  end

  @impl true
  def handle_event("start_voice", _params, socket) do
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

  @impl true
  def handle_event("speak_voice", %{"text" => text}, socket) do
    if socket.assigns.voice_status == :connected and socket.assigns.voice_session_pid do
      Session.send_text(socket.assigns.voice_session_pid, text)
      Session.finish(socket.assigns.voice_session_pid)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_voice", _params, socket) do
    if pid = socket.assigns.voice_session_pid, do: Session.close(pid)
    {:noreply, socket}
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
      voice: "eve",
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
          "[PhoenixKitAI.Web.Playground] failed to start xAI realtime voice session: #{inspect(reason)}"
        )

        socket
        |> assign(:voice_status, :error)
        |> assign(:voice_error, gettext("Could not connect to xAI realtime voice"))
    end
  end

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
      socket
      |> maybe_close_voice_session()
      |> assign(:selected_endpoint_uuid, uuid)
      |> assign(:selected_endpoint, Enum.find(socket.assigns.endpoints, &(&1.uuid == uuid)))
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

  @impl true
  def handle_info(:do_send, socket) do
    result = execute_request(socket.assigns)

    socket =
      case result do
        {:ok, text, usage} ->
          socket
          |> assign(:response_text, text)
          |> assign(:response_usage, usage)
          |> assign(:response_error, nil)

        {:error, reason} ->
          socket
          |> assign(:response_error, PhoenixKitAI.Errors.message(reason))
      end

    {:noreply, assign(socket, :sending, false)}
  end

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
  @impl true
  def handle_info({:xai_realtime_event, event}, socket) do
    Logger.debug(fn -> "[PhoenixKitAI.Web.Playground] xai realtime event: #{inspect(event)}" end)
    {:noreply, socket}
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
      "[PhoenixKitAI.Web.Playground] unhandled handle_info: #{inspect(msg)}"
    end)

    {:noreply, socket}
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp execute_request(assigns) do
    endpoint_uuid = assigns.selected_endpoint_uuid
    prompt = assigns.selected_prompt
    variable_values = assigns.variable_values
    edited_content = assigns.edited_content

    if prompt do
      # Use edited content (user may have modified the template)
      prompt_with_edits = %{prompt | content: edited_content || prompt.content}
      execute_prompt_request(endpoint_uuid, prompt_with_edits, variable_values)
    else
      execute_freeform_request(
        endpoint_uuid,
        assigns.freeform_message,
        assigns.freeform_system
      )
    end
  end

  defp execute_prompt_request(endpoint_uuid, prompt, variable_values) do
    with {:ok, rendered_content} <- Prompt.render(prompt, variable_values),
         {:ok, rendered_system} <- Prompt.render_system_prompt(prompt, variable_values) do
      opts =
        [
          source: "Playground",
          prompt_uuid: prompt.uuid,
          prompt_name: prompt.name
        ]
        |> maybe_add_system(rendered_system)

      case AI.ask(endpoint_uuid, rendered_content, opts) do
        {:ok, response} ->
          AI.increment_prompt_usage(prompt.uuid)
          {:ok, extract_text(response), Completion.extract_usage(response)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_freeform_request(_endpoint_uuid, "", _system) do
    {:error, :empty_input}
  end

  defp execute_freeform_request(endpoint_uuid, message, system) do
    opts =
      [source: "Playground"]
      |> maybe_add_system(if(system == "", do: nil, else: system))

    case AI.ask(endpoint_uuid, message, opts) do
      {:ok, response} ->
        {:ok, extract_text(response), Completion.extract_usage(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_system(opts, nil), do: opts
  defp maybe_add_system(opts, system), do: Keyword.put(opts, :system, system)

  defp extract_text(response) do
    case Completion.extract_content(response) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> "(No content in response)"
    end
  end
end
