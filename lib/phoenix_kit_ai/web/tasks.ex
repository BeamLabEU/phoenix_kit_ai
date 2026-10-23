defmodule PhoenixKitAI.Web.Tasks do
  @moduledoc """
  LiveView for the AI tasks the installed modules declare
  (`PhoenixKitAI.Tasks`): what each is for, what its model has to be able
  to do, the endpoints it uses now and whether each of them fits.

  The fitness is recomputed when the capability cache changes
  (`{:capabilities_refreshed, _}`), and the "Refresh catalogues" button
  asks `PhoenixKitAI.Capabilities.refresh/0` for a fresh read of the
  providers' model lists.

  The guard is set here too: each task's limits (`PhoenixKitAI.TaskLimits`:
  the task's own, the default for each user, personal exceptions), what was
  used today and this month, forgiving a reached limit, who is told
  (`ai_guard_watchers`) and "only verified models"; the recent off-purpose
  flags of each task (the reasons of a private task's only for `ai.manage`),
  blocking a person from a flag or their row, and the active blocks with
  lifting (`PhoenixKitAI.GuardBlocks`). Changing any of it
  needs `ai.manage`: without it the page shows the values and no controls,
  and every event that changes something checks the permission again
  (`PhoenixKitAI.Web.Access`) before the context function checks it once
  more with the scope as it is now.

  Mounted at `{prefix}/admin/ai/tasks`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitAI.Gettext

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitAI.{Capabilities, Guard, GuardBlocks, GuardEvents, Recommendations}
  alias PhoenixKitAI.{Money, TaskLimits, Tasks}
  alias PhoenixKitAI.TaskSpec
  alias PhoenixKitAI.Web.Access
  alias PhoenixKitAI.Web.Components.CapabilityBadges
  alias PhoenixKitAI.Web.Components.TaskModelPicker
  alias PhoenixKitAI.Web.MessageShape

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Capabilities.subscribe()
      PubSub.subscribe(TaskLimits.topic())
    end

    socket =
      socket
      |> Access.assign_session(session)
      |> assign(:can_manage, false)
      |> assign(:verified_only, false)
      |> assign(:watchers, [])
      |> assign(:user_editor, nil)
      |> assign(:block_editor, nil)
      |> assign(:lift_editor, nil)
      |> assign(:current_path, PhoenixKitAI.Routes.ai_path() <> "/tasks")
      |> assign(:page_section, gettext("AI"))
      |> assign(:page_section_path, PhoenixKitAI.Routes.ai_path())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, gettext("Tasks"))
      |> assign(:page_subtitle, gettext("What each AI task needs and whether its endpoints fit"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:refreshing, false)
      |> assign(:tasks, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     socket
     |> assign(:current_path, URI.parse(uri).path)
     |> assign(:can_manage, Access.may_manage?(socket))
     |> load_guard()
     |> load_tasks()}
  end

  @impl true
  def handle_event("refresh_catalogues", _params, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, true)
     |> start_async(:refresh_catalogues, fn -> Capabilities.refresh() end)}
  end

  # ── changes: each needs ai.manage, checked again here and in the context ──

  def handle_event(event, params, socket) when event in ~w(save_limits forgive
           limit_user_search limit_user_pick limit_user_cancel save_user_limits
           delete_user_limits watcher_search watcher_pick remove_watcher
           toggle_verified_only block_open block_cancel block_user lift_open
           lift_cancel lift_block toggle_self_flag) do
    if Access.may_manage?(socket) do
      manage(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, gettext("You may not change the AI task guard"))}
    end
  end

  defp manage("save_limits", %{"task" => key} = params, socket) do
    with {:ok, limits} <- form_limits(params["limits"] || %{}),
         {:ok, _} <-
           TaskLimits.update_settings(Access.session_scope(socket), key, %{
             "limits" => limits,
             "warn_percent" => params["warn_percent"]
           }) do
      {:noreply, socket |> load_tasks() |> put_flash(:info, gettext("Limits saved"))}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  defp manage("forgive", %{"task" => key, "scope" => scope, "period" => period} = params, socket) do
    case TaskLimits.forgive(
           Access.session_scope(socket),
           key,
           scope,
           period,
           blank_to_nil(params["user"])
         ) do
      {:ok, _event} ->
        {:noreply, socket |> load_tasks() |> put_flash(:info, gettext("Limit forgiven"))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp manage("limit_user_search", %{"q" => query} = params, socket),
    do: {:noreply, push_event(socket, "limit_user_results", user_results(query, params["id"]))}

  defp manage("limit_user_pick", %{"id" => picker_id, "uuid" => user_uuid} = params, socket) do
    case Enum.find(socket.assigns.tasks, &(picker_id(&1.dom_id) == picker_id)) do
      nil ->
        {:noreply, socket}

      task ->
        editor = %{
          task_key: task.spec.key,
          user_uuid: user_uuid,
          email: params["label"] || user_uuid,
          limits: personal_limits(task, user_uuid)
        }

        {:noreply,
         socket
         |> assign(:user_editor, editor)
         |> push_event("limit_user_staged", %{id: picker_id})}
    end
  end

  defp manage("limit_user_cancel", _params, socket),
    do: {:noreply, assign(socket, :user_editor, nil)}

  defp manage("save_user_limits", %{"task" => key, "user" => user_uuid} = params, socket) do
    with {:ok, limits} <- form_limits(%{"user" => params["limits"] || %{}}),
         {:ok, _} <-
           TaskLimits.put_user_limits(
             Access.session_scope(socket),
             key,
             user_uuid,
             limits["user"] || %{}
           ) do
      {:noreply,
       socket
       |> assign(:user_editor, nil)
       |> load_tasks()
       |> put_flash(:info, gettext("Personal limits saved"))}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  defp manage("delete_user_limits", %{"task" => key, "user" => user_uuid}, socket) do
    case TaskLimits.delete_user_limits(Access.session_scope(socket), key, user_uuid) do
      {:ok, _} ->
        {:noreply, socket |> load_tasks() |> put_flash(:info, gettext("Personal limits removed"))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp manage("watcher_search", %{"q" => query} = params, socket),
    do: {:noreply, push_event(socket, "watcher_results", user_results(query, params["id"]))}

  defp manage("watcher_pick", %{"uuid" => user_uuid} = params, socket) do
    uuids = Enum.map(socket.assigns.watchers, & &1.uuid) ++ [user_uuid]

    socket
    |> save_watchers(uuids)
    |> then(&{:noreply, push_event(&1, "watcher_staged", %{id: params["id"]})})
  end

  defp manage("remove_watcher", %{"uuid" => user_uuid}, socket) do
    uuids = socket.assigns.watchers |> Enum.map(& &1.uuid) |> List.delete(user_uuid)
    {:noreply, save_watchers(socket, uuids)}
  end

  defp manage("toggle_verified_only", _params, socket) do
    case Guard.set_verified_only(Access.session_scope(socket), !socket.assigns.verified_only) do
      {:ok, _} -> {:noreply, socket |> load_guard() |> load_tasks()}
      error -> {:noreply, refused(socket, error)}
    end
  end

  defp manage("block_open", %{"task" => key, "user" => user_uuid} = params, socket) do
    editor = %{task_key: key, user_uuid: user_uuid, event_uuid: blank_to_nil(params["event"])}
    {:noreply, socket |> assign(:block_editor, editor) |> assign(:lift_editor, nil)}
  end

  defp manage("block_cancel", _params, socket),
    do: {:noreply, assign(socket, :block_editor, nil)}

  defp manage("block_user", %{"task" => key, "user" => user_uuid} = params, socket) do
    origin = %{event_uuid: blank_to_nil(params["event"])}

    case Guard.block(Access.session_scope(socket), key, user_uuid, params["reason"], origin) do
      {:ok, _block} ->
        {:noreply,
         socket
         |> assign(:block_editor, nil)
         |> load_tasks()
         |> put_flash(:info, gettext("Blocked"))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp manage("lift_open", %{"block" => block_uuid}, socket),
    do: {:noreply, socket |> assign(:lift_editor, block_uuid) |> assign(:block_editor, nil)}

  defp manage("lift_cancel", _params, socket), do: {:noreply, assign(socket, :lift_editor, nil)}

  defp manage("lift_block", %{"block" => block_uuid} = params, socket) do
    case Guard.unblock(Access.session_scope(socket), block_uuid, params["note"]) do
      {:ok, _block} ->
        {:noreply,
         socket
         |> assign(:lift_editor, nil)
         |> load_tasks()
         |> put_flash(:info, gettext("Block lifted"))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp manage("toggle_self_flag", %{"task" => key}, socket) do
    mode = if Guard.self_flag?(key), do: "off", else: "self_flag"

    case TaskLimits.set_guard_mode(Access.session_scope(socket), key, mode) do
      {:ok, _setting} -> {:noreply, load_tasks(socket)}
      error -> {:noreply, refused(socket, error)}
    end
  end

  defp manage(_event, _params, socket), do: {:noreply, socket}

  defp save_watchers(socket, uuids) do
    case GuardEvents.set_watchers(Access.session_scope(socket), uuids) do
      {:ok, _} -> socket |> load_guard() |> put_flash(:info, gettext("Watchers saved"))
      error -> refused(socket, error)
    end
  end

  defp refused(socket, {:error, :forbidden}),
    do: put_flash(socket, :error, gettext("You may not change the AI task guard"))

  defp refused(socket, {:error, :invalid_amount}),
    do: put_flash(socket, :error, gettext("A limit must be a whole number, or dollars for money"))

  defp refused(socket, {:error, reason}) when reason in [:unknown_user, :invalid_user],
    do: put_flash(socket, :error, gettext("That person was not found"))

  defp refused(socket, {:error, :owner_only}),
    do: put_flash(socket, :error, gettext("Only an Owner blocks an Owner or lifts their block"))

  defp refused(socket, {:error, :own_block}),
    do: put_flash(socket, :error, gettext("Nobody but an Owner lifts their own block"))

  defp refused(socket, {:error, :already_blocked}),
    do: put_flash(socket, :error, gettext("That person is blocked from this task already"))

  defp refused(socket, {:error, reason}) when reason in [:not_blocked, :not_found],
    do: put_flash(socket, :error, gettext("That block was lifted already"))

  defp refused(socket, {:error, :too_long}),
    do: put_flash(socket, :error, gettext("Too many watchers"))

  defp refused(socket, {:error, :user_limits_off}),
    do: put_flash(socket, :error, gettext("Limits per user are set by the task's module"))

  defp refused(socket, _error),
    do: put_flash(socket, :error, gettext("The change was not saved"))

  @impl true
  def handle_async(:refresh_catalogues, result, socket) do
    socket = socket |> assign(:refreshing, false) |> load_tasks()

    case result do
      {:ok, :ok} ->
        {:noreply, put_flash(socket, :info, gettext("Model catalogues refreshed"))}

      _failed ->
        {:noreply, put_flash(socket, :error, gettext("Some model catalogues could not be read"))}
    end
  end

  @impl true
  def handle_info({:capabilities_refreshed, _base_urls}, socket),
    do: {:noreply, load_tasks(socket)}

  def handle_info({event, _key}, socket)
      when event in [:guard_blocks_changed, :task_limits_changed] do
    {:noreply,
     socket
     |> assign(:can_manage, Access.may_manage?(socket))
     |> load_guard()
     |> load_tasks()}
  end

  # Catch-all for messages from other topics: shape only, never content.
  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.Tasks] unhandled handle_info: #{MessageShape.describe(msg)}"
    end)

    {:noreply, socket}
  end

  defp load_tasks(socket) do
    # The catalogues and the journal are read once for all the tasks.
    specs = Tasks.list()
    recommendations = Recommendations.for_tasks(specs)
    # Only a viewer who may manage the guard now is shown a private reason.
    viewer = if socket.assigns.can_manage, do: Access.session_scope(socket)

    tasks =
      for spec <- specs do
        endpoints = Tasks.endpoints(spec)

        %{
          spec: spec,
          dom_id: dom_id(spec.key),
          recommendations: Map.fetch!(recommendations, spec.key),
          endpoints: Enum.map(endpoints, &%{endpoint: &1, fitness: Tasks.fitness(spec, &1)}),
          limits: limits_view(spec, endpoints),
          guard: guard_view(spec, viewer)
        }
      end

    assign(socket, :tasks, tasks)
  end

  # The task's recent flags and its group's active blocks, as `viewer` may
  # see them (nil: a viewer who may not manage the guard).
  defp guard_view(spec, viewer) do
    %{counts: counts, flags: flags} = GuardEvents.flags(spec, viewer)
    group = GuardBlocks.group(spec)
    blocks = GuardBlocks.list_active(group)

    emails =
      (Enum.map(counts, &elem(&1, 0)) ++
         Enum.flat_map(blocks, &[&1.user_uuid, &1.blocked_by_uuid]))
      |> Enum.reject(&is_nil/1)
      |> emails()

    blocked = MapSet.new(blocks, & &1.user_uuid)
    blockable = blockable(viewer, Enum.map(counts, &elem(&1, 0)), blocked)

    %{
      group: group,
      self_flag: Guard.self_flag?(spec),
      # The switch is for a task whose consumer flags: its declaration says
      # so, or an admin turned it on.
      self_flag_switch: spec.self_flag == true or Guard.self_flag?(spec),
      counts:
        Enum.map(counts, fn {user_uuid, count} ->
          %{
            user_uuid: user_uuid,
            email: email(emails, user_uuid),
            count: count,
            blockable: user_uuid in blockable
          }
        end),
      flags:
        Enum.map(flags, fn flag ->
          flag
          |> Map.put(:email, email(emails, flag.user_uuid))
          |> Map.put(:blockable, flag.user_uuid in blockable)
        end),
      blocks:
        Enum.map(blocks, fn block ->
          visible? = Guard.reasons_visible?(viewer, block.private)

          %{
            uuid: block.uuid,
            user_uuid: block.user_uuid,
            email: email(emails, block.user_uuid),
            blocked_by: block.blocked_by_uuid && email(emails, block.blocked_by_uuid),
            blocked_at: block.blocked_at,
            origin_task_key: block.origin_task_key,
            reason: if(visible?, do: block.reason),
            hidden: not visible?,
            liftable: viewer != nil and GuardBlocks.may_lift?(viewer, block)
          }
        end)
    }
  end

  # The people `viewer` may block now: not blocked already, and an Owner
  # only for an Owner.
  defp blockable(nil, _user_uuids, _blocked), do: MapSet.new()

  defp blockable(viewer, user_uuids, blocked) do
    for user_uuid <- user_uuids,
        is_binary(user_uuid),
        not MapSet.member?(blocked, user_uuid),
        GuardBlocks.may_block?(viewer, user_uuid),
        into: MapSet.new(),
        do: user_uuid
  end

  defp email(_emails, nil), do: gettext("No user")
  defp email(emails, user_uuid), do: emails[user_uuid] || user_uuid

  defp limits_view(spec, endpoints) do
    layers = TaskLimits.layers(spec)
    user_limits? = spec.user_limits != false
    personal = if user_limits?, do: TaskLimits.list_user_limits(spec.key), else: []
    reached = if user_limits?, do: users_at_limit(spec), else: []

    emails = emails(Enum.map(personal, & &1.user_uuid) ++ Enum.map(reached, & &1.user_uuid))

    %{
      layers: layers,
      user_limits?: user_limits?,
      used: TaskLimits.usage(spec.key, nil).task,
      warn_percent: layers.setting && layers.setting.warn_percent,
      personal:
        Enum.map(personal, fn row ->
          %{
            user_uuid: row.user_uuid,
            email: emails[row.user_uuid] || row.user_uuid,
            limits: TaskLimits.normalize(row.limits)
          }
        end),
      reached: Enum.map(reached, &Map.put(&1, :email, emails[&1.user_uuid] || &1.user_uuid)),
      money_uncounted: for(e <- endpoints, !TaskLimits.money_counted?(e, spec.needs), do: e.name)
    }
  end

  # Who reached a limit in this window and is still at it (not forgiven
  # since, the limit not raised).
  defp users_at_limit(spec) do
    for user_uuid <-
          spec.key |> GuardEvents.reached_users() |> Enum.map(& &1.user_uuid) |> Enum.uniq(),
        status <- TaskLimits.statuses(spec, user_uuid),
        status.scope == :user and status.used >= status.limit,
        do: Map.put(status, :user_uuid, user_uuid)
  end

  defp load_guard(socket) do
    watchers = GuardEvents.configured_watchers()
    emails = emails(watchers)

    socket
    |> assign(:verified_only, Guard.verified_only?())
    |> assign(:watchers, Enum.map(watchers, &%{uuid: &1, email: emails[&1] || &1}))
  end

  defp emails([]), do: %{}

  defp emails(uuids) do
    from(u in User, where: u.uuid in ^Enum.uniq(uuids), select: {u.uuid, u.email})
    |> PhoenixKit.RepoHelper.repo().all()
    |> Map.new()
  end

  defp user_results(query, picker_id) do
    rows =
      for user <- Auth.search_users(query || ""),
          do: %{kind: "user", uuid: user.uuid, label: user.email, icon: "hero-user"}

    %{id: picker_id, q: query, results: rows, has_more: false}
  end

  defp personal_limits(task, user_uuid) do
    case Enum.find(task.limits.personal, &(&1.user_uuid == user_uuid)) do
      nil -> %{}
      row -> row.limits
    end
  end

  # The limits of a submitted form: money in dollars (to micro-dollars),
  # requests and tokens whole numbers; a blank field is no limit.
  defp form_limits(params) when is_map(params) do
    if Enum.all?(params, fn {scope, units} ->
         scope not in ["task", "user"] or valid_units?(units)
       end),
       do: parse_form_limits(params),
       else: {:error, :invalid_amount}
  end

  defp form_limits(_params), do: {:error, :invalid_amount}

  defp valid_units?(units) when is_map(units) do
    Enum.all?(units, fn {unit, periods} ->
      unit not in ["money", "requests", "tokens"] or is_map(periods)
    end)
  end

  defp valid_units?(_units), do: false

  defp parse_form_limits(params) do
    cells =
      for {scope, units} <- params,
          scope in ["task", "user"],
          is_map(units),
          {unit, periods} <- units,
          unit in ["money", "requests", "tokens"],
          is_map(periods),
          {period, value} <- periods,
          period in ["day", "month"],
          value = form_value(value),
          value != "",
          do: {scope, unit, period, amount(unit, value)}

    if Enum.any?(cells, &(elem(&1, 3) == :error)) do
      {:error, :invalid_amount}
    else
      {:ok,
       Enum.reduce(cells, %{}, fn {scope, unit, period, amount}, acc ->
         Map.update(acc, scope, %{unit => %{period => amount}}, fn units ->
           Map.update(units, unit, %{period => amount}, &Map.put(&1, period, amount))
         end)
       end)}
    end
  end

  defp form_value(value) when is_binary(value), do: String.trim(value)
  defp form_value(value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(nil), do: ""
  defp form_value(_value), do: :invalid

  # Dollars, finite, from 0 to $1 000 000 000 (`PhoenixKitAI.Money`); 0
  # allows nothing.
  defp amount("money", value) when is_binary(value) do
    case Money.parse_dollars(value) do
      {:ok, micro} -> micro
      :error -> :error
    end
  end

  defp amount(_unit, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> :error
    end
  end

  defp amount(_unit, _value), do: :error

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp picker_id(dom_id), do: dom_id <> "-user-picker"

  # Readable, and unique: `a.b` and `a-b` slug alike, the hash tells them apart.
  defp dom_id(key) do
    hash = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "ai-task-" <> String.replace(key, ~r/[^A-Za-z0-9_-]/, "-") <> "-" <> hash
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col w-full px-4 py-6 gap-4">
      <div class="flex items-center justify-between gap-2">
        <p class="text-sm text-base-content/70">
          {gettext(
            "Each task is declared by a module. A call with a task is refused before it reaches the provider when the model lacks something the task needs."
          )}
        </p>
        <button
          id="ai-tasks-refresh"
          type="button"
          class="btn btn-sm btn-outline"
          phx-click="refresh_catalogues"
          disabled={@refreshing}
        >
          <.icon name="hero-arrow-path" class={if(@refreshing, do: "w-4 h-4 animate-spin", else: "w-4 h-4")} />
          {gettext("Refresh catalogues")}
        </button>
      </div>

      <.guard_settings
        can_manage={@can_manage}
        verified_only={@verified_only}
        watchers={@watchers}
      />

      <CapabilityBadges.glossary id="ai-tasks-capability-glossary" class="bg-base-100" />

      <%= if @tasks == [] do %>
        <div id="ai-tasks-empty" class="alert">
          {gettext("No module declares an AI task.")}
        </div>
      <% end %>

      <div id="ai-tasks" class="grid min-w-0 gap-4">
        <div
          :for={task <- @tasks}
          id={task.dom_id}
          data-task-key={task.spec.key}
          class={["card min-w-0 bg-base-200", !task.spec.enabled && "opacity-60"]}
        >
          <div class="card-body min-w-0 gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="card-title text-base">{TaskSpec.label(task.spec)}</h2>
              <code class="text-xs text-base-content/60">{task.spec.key}</code>
              <span :if={!task.spec.enabled} class="badge badge-ghost badge-sm" data-module-off>
                {gettext("Module off")}
              </span>
            </div>

            <p :if={TaskSpec.purpose(task.spec)} class="text-sm">{TaskSpec.purpose(task.spec)}</p>

            <div class="flex flex-wrap items-center gap-1 text-sm">
              <span class="text-base-content/70">{gettext("Needs:")}</span>
              <%= if task.spec.needs == [] do %>
                <span class="badge badge-ghost badge-sm">{gettext("text only")}</span>
              <% else %>
                <span
                  :for={need <- task.spec.needs}
                  class="badge badge-outline badge-sm"
                  data-need={need}
                  title={CapabilityBadges.explain_text(need)}
                >
                  {Tasks.need_label(need)}
                </span>
              <% end %>
            </div>

            <div class="flex flex-col gap-1 text-sm">
              <span class="text-base-content/70">{gettext("Endpoints in use:")}</span>
              <%= if task.endpoints == [] do %>
                <span class="text-base-content/60">
                  {gettext("None chosen; the caller names an endpoint per call.")}
                </span>
              <% end %>
              <div
                :for={row <- task.endpoints}
                class="flex flex-wrap items-center gap-2"
                data-endpoint-uuid={row.endpoint.uuid}
              >
                <.link
                  navigate={PhoenixKitAI.Routes.ai_path() <> "/endpoints/#{row.endpoint.uuid}/edit"}
                  class="link link-hover"
                >
                  {row.endpoint.name}
                </.link>
                <code class="text-xs text-base-content/60">{row.endpoint.model}</code>
                <.fitness_badge fitness={row.fitness} />
              </div>
            </div>

            <.limits
              task={task}
              can_manage={@can_manage}
              user_editor={@user_editor}
            />

            <.flags_and_blocks
              task={task}
              can_manage={@can_manage}
              block_editor={@block_editor}
              lift_editor={@lift_editor}
            />

            <TaskModelPicker.recommendations
              id={task.dom_id <> "-recommendations"}
              recommendations={task.recommendations}
              scope={assigns[:phoenix_kit_current_scope]}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:can_manage, :boolean, required: true)
  attr(:verified_only, :boolean, required: true)
  attr(:watchers, :list, required: true)

  defp guard_settings(assigns) do
    ~H"""
    <div id="ai-guard-settings" class="card min-w-0 bg-base-200">
      <div class="card-body min-w-0 gap-3">
        <h2 class="card-title text-base">{gettext("Task guard")}</h2>
        <p :if={!@can_manage} id="ai-guard-read-only" class="text-sm text-base-content/70">
          {gettext("Changing the guard needs the “Manage the AI task guard” permission.")}
        </p>

        <label class="flex items-start gap-3 cursor-pointer">
          <input
            id="ai-guard-verified-only"
            type="checkbox"
            class="toggle toggle-sm mt-0.5"
            checked={@verified_only}
            disabled={!@can_manage}
            phx-click={@can_manage && "toggle_verified_only"}
          />
          <span class="flex flex-col">
            <span class="text-sm font-medium">{gettext("Only verified models")}</span>
            <span class="text-xs text-base-content/70">
              {gettext(
                "A call is refused when nobody knows whether the model can do what its task needs. Declaring capabilities on an endpoint then needs this permission too."
              )}
            </span>
            <span id="ai-guard-verified-only-hint" class="text-xs text-base-content/70">
              {gettext(
                "Without a catalogue (OpenAI, xAI, Z.ai) the capabilities have to be marked on the endpoint, or the calls are refused."
              )}
            </span>
          </span>
        </label>

        <div id="ai-guard-watchers" class="flex flex-col gap-2">
          <span class="text-sm font-medium">{gettext("Who is told")}</span>
          <span class="text-xs text-base-content/70">
            {gettext(
              "Limits near or reached, spending caps, models that stop fitting, off-purpose flags, unusual use and blocks are sent to these people (and to the people a task names), never with a reason. Nobody chosen: every Owner."
            )}
          </span>
          <div class="flex flex-wrap gap-1">
            <span :if={@watchers == []} class="badge badge-ghost" data-watchers-owners>
              {gettext("Every Owner")}
            </span>
            <span :for={watcher <- @watchers} class="badge badge-outline gap-1" data-watcher={watcher.uuid}>
              {watcher.email}
              <button
                :if={@can_manage}
                type="button"
                class="btn btn-ghost btn-xs btn-circle"
                phx-click="remove_watcher"
                phx-value-uuid={watcher.uuid}
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </span>
          </div>
          <div :if={@can_manage} class="max-w-sm">
            <.search_picker
              id="ai-guard-watcher-picker"
              dropdown_id="ai-guard-watcher-picker-list"
              search_event="watcher_search"
              results_event="watcher_results"
              pick_event="watcher_pick"
              staged_event="watcher_staged"
              placeholder={gettext("Add a person…")}
              class="input input-sm w-full"
              searching_label={gettext("Searching…")}
              no_matches_label={gettext("No matches")}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:task, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:user_editor, :any, required: true)

  defp limits(assigns) do
    assigns =
      assigns
      |> assign(:view, assigns.task.limits)
      |> assign(:key, assigns.task.spec.key)
      |> assign(:id, assigns.task.dom_id <> "-limits")
      |> assign(
        :editing,
        assigns.user_editor && assigns.user_editor.task_key == assigns.task.spec.key &&
          assigns.user_editor
      )

    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-2 text-sm" data-limits>
      <span class="text-base-content/70">{gettext("Limits and use:")}</span>

      <.form for={%{}} id={@id <> "-form"} phx-submit="save_limits" class="min-w-0">
        <input type="hidden" name="task" value={@key} />
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th></th>
                <th>{gettext("Used today")}</th>
                <th>{gettext("Used this month")}</th>
                <th>{gettext("Task, a day")}</th>
                <th>{gettext("Task, a month")}</th>
                <th :if={@view.user_limits?}>{gettext("Each user, a day")}</th>
                <th :if={@view.user_limits?}>{gettext("Each user, a month")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={unit <- TaskLimits.units()} data-unit={unit}>
                <th>{unit_label(unit)}</th>
                <td data-used="day">{GuardEvents.format_amount(unit, @view.used[unit].day)}</td>
                <td data-used="month">{GuardEvents.format_amount(unit, @view.used[unit].month)}</td>
                <td :for={{scope, period} <- limit_cells(@view)}>
                  <.limit_cell
                    can_manage={@can_manage}
                    name={"limits[#{scope}][#{unit}][#{period}]"}
                    unit={unit}
                    stored={get_in(@view.layers.stored, [scope, unit, period])}
                    declared={get_in(@view.layers.declared, [scope, unit, period])}
                    data-limit={"#{scope}-#{unit}-#{period}"}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="flex flex-wrap items-end gap-2 mt-2">
          <%= if @can_manage do %>
            <.input
              type="number"
              id={@id <> "-warn"}
              name="warn_percent"
              value={@view.warn_percent}
              label={gettext("Warn at, %")}
              placeholder="80"
              min="1"
              max="100"
              class="input-sm"
              wrapper_class="w-28"
            />
            <button id={@id <> "-save"} type="submit" class="btn btn-sm btn-primary">
              {gettext("Save limits")}
            </button>
          <% else %>
            <span class="text-base-content/70">
              {gettext("Warn at %{percent}%", percent: @view.warn_percent || 80)}
            </span>
          <% end %>
        </div>
      </.form>

      <p class="text-xs text-base-content/60">
        {gettext(
          "Days and months follow the site time zone. Empty limits inherit defaults when set; otherwise they are unlimited. 0 allows nothing. Calls running at the same time can each go past a limit by their own size."
        )}
      </p>
      <p :if={@view.money_uncounted != []} class="text-xs text-warning" data-money-uncounted>
        {gettext(
          "Money is not counted for this task's calls on %{endpoints}: nothing prices them (the provider reports no cost, and no catalogue, manual or list price applies). Requests and tokens still apply.",
          endpoints: Enum.join(@view.money_uncounted, ", ")
        )}
      </p>

      <div :if={reached_task_limits(@view) != []} class="flex flex-col gap-1" data-task-reached>
        <div
          :for={{unit, period} <- reached_task_limits(@view)}
          class="flex flex-wrap items-center gap-2"
        >
          <span class="badge badge-error badge-sm">
            {gettext("Reached: %{limit}", limit: GuardEvents.limit_name(unit, period))}
          </span>
          <button
            :if={@can_manage}
            type="button"
            class="btn btn-xs btn-outline"
            phx-click="forgive"
            phx-value-task={@key}
            phx-value-scope="task"
            phx-value-period={period}
            data-forgive={"task-#{period}"}
          >
            {gettext("Forgive")}
          </button>
        </div>
      </div>

      <p :if={!@view.user_limits?} class="text-xs text-base-content/60" data-user-limits-off>
        {gettext("Limits per user are set by the task's module")}
      </p>

      <div :if={@view.reached != []} class="flex flex-col gap-1" data-users-reached>
        <span class="text-base-content/70">{gettext("People at a limit now:")}</span>
        <div
          :for={row <- @view.reached}
          class="flex flex-wrap items-center gap-2"
          data-reached-user={row.user_uuid}
        >
          <span>{row.email}</span>
          <span class="badge badge-error badge-sm">{GuardEvents.limit_name(row.unit, row.period)}</span>
          <button
            :if={@can_manage}
            type="button"
            class="btn btn-xs btn-outline"
            phx-click="forgive"
            phx-value-task={@key}
            phx-value-scope="user"
            phx-value-period={row.period}
            phx-value-user={row.user_uuid}
            data-forgive={"user-#{row.period}"}
          >
            {gettext("Forgive")}
          </button>
        </div>
      </div>

      <div :if={@view.user_limits?} class="flex flex-col gap-1" data-personal-limits>
        <span class="text-base-content/70">{gettext("Personal limits:")}</span>
        <span :if={@view.personal == []} class="text-base-content/60">{gettext("None")}</span>
        <div
          :for={row <- @view.personal}
          class="flex flex-wrap items-center gap-2"
          data-personal-user={row.user_uuid}
        >
          <span>{row.email}</span>
          <span class="text-base-content/70">{limits_summary(row.limits)}</span>
          <button
            :if={@can_manage}
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="delete_user_limits"
            phx-value-task={@key}
            phx-value-user={row.user_uuid}
            data-remove-personal={row.user_uuid}
          >
            {gettext("Remove")}
          </button>
        </div>

        <div :if={@can_manage && !@editing} class="max-w-sm">
          <.search_picker
            id={@task.dom_id <> "-user-picker"}
            dropdown_id={@task.dom_id <> "-user-picker-list"}
            search_event="limit_user_search"
            results_event="limit_user_results"
            pick_event="limit_user_pick"
            staged_event="limit_user_staged"
            placeholder={gettext("Set personal limits for…")}
            class="input input-sm w-full"
            searching_label={gettext("Searching…")}
            no_matches_label={gettext("No matches")}
          />
        </div>

        <.form
          :if={@can_manage && @editing}
          for={%{}}
          id={@id <> "-personal-form"}
          phx-submit="save_user_limits"
          class="flex flex-col gap-2 rounded-box border border-base-300 p-2"
        >
          <input type="hidden" name="task" value={@key} />
          <input type="hidden" name="user" value={@editing.user_uuid} />
          <span class="font-medium">{@editing.email}</span>
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
            <%= for unit <- TaskLimits.units(), period <- TaskLimits.periods() do %>
              <.input
                id={"#{@id}-personal-#{unit}-#{period}"}
                name={"limits[#{unit}][#{period}]"}
                value={display_amount(unit, get_in(@editing.limits, [unit, period]))}
                label={GuardEvents.limit_name(unit, period)}
                class="input-sm"
              />
            <% end %>
          </div>
          <div class="flex gap-2">
            <button id={@id <> "-personal-save"} type="submit" class="btn btn-sm btn-primary">
              {gettext("Save")}
            </button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="limit_user_cancel">
              {gettext("Cancel")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr(:task, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:block_editor, :any, required: true)
  attr(:lift_editor, :any, required: true)

  defp flags_and_blocks(assigns) do
    guard = assigns.task.guard
    key = assigns.task.spec.key

    assigns =
      assigns
      |> assign(:guard, guard)
      |> assign(:key, key)
      |> assign(:id, assigns.task.dom_id <> "-guard")
      |> assign(
        :blocking,
        assigns.can_manage && assigns.block_editor && assigns.block_editor.task_key == key &&
          assigns.block_editor
      )
      |> assign(
        :lifting,
        assigns.can_manage && Enum.find(guard.blocks, &(&1.uuid == assigns.lift_editor))
      )

    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-2 text-sm" data-guard-flags>
      <label :if={@guard.self_flag_switch} class="flex items-start gap-3 cursor-pointer">
        <input
          id={@id <> "-self-flag"}
          type="checkbox"
          class="toggle toggle-sm mt-0.5"
          checked={@guard.self_flag}
          disabled={!@can_manage}
          phx-click={@can_manage && "toggle_self_flag"}
          phx-value-task={@key}
          data-self-flag
        />
        <span class="flex flex-col">
          <span class="font-medium">{gettext("The model flags off-purpose requests")}</span>
          <span class="text-xs text-base-content/70">
            {gettext(
              "The module that uses this task asks the model to refuse what is not the task's purpose and to flag it. Off: no such instruction, and no flags are written."
            )}
          </span>
        </span>
      </label>

      <span class="text-base-content/70">{gettext("Off-purpose flags, last 30 days:")}</span>
      <span :if={@guard.counts == []} class="text-base-content/60" data-no-flags>
        {gettext("None")}
      </span>

      <div :if={@guard.counts != []} class="overflow-x-auto">
        <table id={@id <> "-people"} class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Person")}</th>
              <th>{gettext("Flags")}</th>
              <th :if={@can_manage}></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @guard.counts}>
              <td class="break-all">{row.email}</td>
              <td data-flag-count={row.user_uuid}>{row.count}</td>
              <td :if={@can_manage} class="text-right">
                <button
                  :if={row.blockable}
                  type="button"
                  class="btn btn-xs btn-outline btn-error"
                  phx-click="block_open"
                  phx-value-task={@key}
                  phx-value-user={row.user_uuid}
                  data-block-user={row.user_uuid}
                >
                  {gettext("Block")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@guard.flags != []} class="overflow-x-auto">
        <table id={@id <> "-latest"} class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("When")}</th>
              <th>{gettext("Person")}</th>
              <th>{gettext("Reason")}</th>
              <th :if={@can_manage}></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={flag <- @guard.flags}
              data-flag={flag.uuid}
              data-flag-hidden={flag.hidden}
            >
              <td class="whitespace-nowrap"><.time_ago datetime={flag.inserted_at} /></td>
              <td class="break-all">{flag.email}</td>
              <td class="min-w-48">
                <%= if flag.hidden do %>
                  <span class="text-base-content/60">
                    {gettext("Hidden: the task is private")}
                  </span>
                <% else %>
                  <span>{flag.reason || "—"}</span>
                  <code
                    :if={flag.request_uuid}
                    class="block text-xs text-base-content/60 break-all"
                    title={gettext("Journal row")}
                    data-flag-request
                  >
                    {flag.request_uuid}
                  </code>
                <% end %>
              </td>
              <td :if={@can_manage} class="text-right">
                <button
                  :if={flag.blockable}
                  type="button"
                  class="btn btn-xs btn-outline btn-error"
                  phx-click="block_open"
                  phx-value-task={@key}
                  phx-value-user={flag.user_uuid}
                  phx-value-event={flag.uuid}
                  data-block-flag={flag.uuid}
                >
                  {gettext("Block")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.form
        :if={@blocking}
        for={%{}}
        id={@id <> "-block-form"}
        phx-submit="block_user"
        class="flex flex-col gap-2 rounded-box border border-base-300 p-2"
        data-block-form
      >
        <input type="hidden" name="task" value={@key} />
        <input type="hidden" name="user" value={@blocking.user_uuid} />
        <input type="hidden" name="event" value={@blocking.event_uuid} />
        <span class="font-medium break-all" data-block-person>{blocking_email(@guard, @blocking)}</span>
        <.input
          id={@id <> "-block-reason"}
          name="reason"
          value=""
          label={gettext("Why (seen by those who manage the guard)")}
          maxlength="500"
          class="input-sm"
        />
        <p class="text-xs text-base-content/70">
          {gettext(
            "The person cannot use the tasks of the group %{group} until the block is lifted.",
            group: @guard.group
          )}
        </p>
        <div class="flex gap-2">
          <button id={@id <> "-block-save"} type="submit" class="btn btn-sm btn-error">
            {gettext("Block")}
          </button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="block_cancel">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>

      <span class="text-base-content/70">{gettext("Blocked now:")}</span>
      <span :if={@guard.blocks == []} class="text-base-content/60" data-no-blocks>
        {gettext("Nobody")}
      </span>

      <div :if={@guard.blocks != []} class="overflow-x-auto">
        <table id={@id <> "-blocks"} class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Person")}</th>
              <th>{gettext("Since")}</th>
              <th>{gettext("By")}</th>
              <th>{gettext("Reason")}</th>
              <th :if={@can_manage}></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={block <- @guard.blocks} data-active-block={block.user_uuid}>
              <td class="break-all">{block.email}</td>
              <td class="whitespace-nowrap"><.time_ago datetime={block.blocked_at} /></td>
              <td class="break-all">{block.blocked_by || "—"}</td>
              <td class="min-w-48">
                <%= if block.hidden do %>
                  <span class="text-base-content/60">
                    {gettext("Hidden: the task is private")}
                  </span>
                <% else %>
                  {block.reason || "—"}
                <% end %>
                <code
                  :if={block.origin_task_key && block.origin_task_key != @key}
                  class="block text-xs text-base-content/60"
                >
                  {block.origin_task_key}
                </code>
              </td>
              <td :if={@can_manage} class="text-right">
                <button
                  :if={block.liftable}
                  type="button"
                  class="btn btn-xs btn-outline"
                  phx-click="lift_open"
                  phx-value-block={block.uuid}
                  data-lift={block.uuid}
                >
                  {gettext("Lift")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.form
        :if={@lifting}
        for={%{}}
        id={@id <> "-lift-form"}
        phx-submit="lift_block"
        class="flex flex-col gap-2 rounded-box border border-base-300 p-2"
        data-lift-form
      >
        <input type="hidden" name="block" value={@lifting.uuid} />
        <span class="font-medium break-all">{@lifting.email}</span>
        <.input
          id={@id <> "-lift-note"}
          name="note"
          value=""
          label={gettext("Note")}
          maxlength="500"
          class="input-sm"
        />
        <div class="flex gap-2">
          <button id={@id <> "-lift-save"} type="submit" class="btn btn-sm btn-primary">
            {gettext("Lift")}
          </button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="lift_cancel">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp blocking_email(guard, %{user_uuid: user_uuid}) do
    case Enum.find(guard.counts, &(&1.user_uuid == user_uuid)) do
      %{email: email} -> email
      nil -> user_uuid
    end
  end

  attr(:can_manage, :boolean, required: true)
  attr(:name, :string, required: true)
  attr(:unit, :atom, required: true)
  attr(:stored, :any, required: true)
  attr(:declared, :any, required: true)
  attr(:rest, :global)

  defp limit_cell(assigns) do
    ~H"""
    <%= if @can_manage do %>
      <input
        type="text"
        inputmode={if(@unit == :money, do: "decimal", else: "numeric")}
        name={@name}
        value={display_amount(@unit, @stored)}
        placeholder={display_amount(@unit, @declared) || "—"}
        class="input input-sm w-24"
        {@rest}
      />
    <% else %>
      <span {@rest}>{display_amount(@unit, @stored || @declared) || "—"}</span>
    <% end %>
    """
  end

  defp unit_label(:money), do: gettext("Money")
  defp unit_label(:requests), do: gettext("Requests")
  defp unit_label(:tokens), do: gettext("Tokens")

  # Money in dollars, the rest as it is; nil for no limit.
  defp display_amount(_unit, nil), do: nil
  defp display_amount(:money, micro), do: GuardEvents.format_usd(micro)
  defp display_amount(_unit, amount), do: Integer.to_string(amount)

  defp limits_summary(limits) do
    Enum.map_join(
      for(
        unit <- TaskLimits.units(),
        period <- TaskLimits.periods(),
        amount = get_in(limits, [unit, period]),
        do: {unit, period, amount}
      ),
      "; ",
      fn {unit, period, amount} ->
        "#{GuardEvents.limit_name(unit, period)}: #{GuardEvents.format_amount(unit, amount)}"
      end
    )
  end

  # The editable cells of a row: the task's, then each user's when the guard
  # limits the task's users.
  defp limit_cells(%{user_limits?: true}),
    do: [task: :day, task: :month, user: :day, user: :month]

  defp limit_cells(_view), do: [task: :day, task: :month]

  # The task's own limits whose count has reached them now.
  defp reached_task_limits(view) do
    for period <- TaskLimits.periods(),
        unit <- TaskLimits.units(),
        limit = get_in(view.layers.defaults, [:task, unit, period]),
        is_integer(limit),
        view.used[unit][period] >= limit,
        do: {unit, period}
  end

  attr(:fitness, :any, required: true)

  defp fitness_badge(%{fitness: :fit} = assigns) do
    ~H"""
    <span class="badge badge-success badge-sm" data-fitness="fit">
      <.icon name="hero-check" class="w-3 h-3" /> {gettext("Fits")}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unfit, missing}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(missing))

    ~H"""
    <span class="badge badge-error badge-sm" data-fitness="unfit">
      <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Lacks: %{needs}", needs: @needs)}
    </span>
    """
  end

  defp fitness_badge(%{fitness: {:unknown, unclear}} = assigns) do
    assigns = assign(assigns, :needs, Tasks.need_labels(unclear))

    ~H"""
    <span class="badge badge-warning badge-sm" data-fitness="unknown">
      ? {gettext("Not verified: %{needs}", needs: @needs)}
    </span>
    """
  end
end
