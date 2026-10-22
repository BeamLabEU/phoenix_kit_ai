defmodule PhoenixKitAI.GuardEvents do
  @moduledoc """
  What the AI task guard noticed (`PhoenixKitAI.GuardEvent`) and who is told.

  ## Once per window

  An event that is signalled once per window carries a `dedupe_key` naming
  the window; the key is unique, the row is inserted with `ON CONFLICT DO
  NOTHING`, and only the insert that went through signals:

  | event | key |
  |---|---|
  | a limit at its warn percent | `limit_warning:<task>:<user or ->:<unit>:<period key>` |
  | a limit reached | `limit_reached:<task>:<user or ->:<unit>:<period key>` |
  | a `PhoenixKitAI.Budget` refusal | `limit_reached:budget:<scope>:<user, endpoint or ->:<local date>` |
  | a model that no longer fits a task | `model_unfit:<task>:<endpoint>:<local date>` |
  | an off-purpose flag | `off_purpose:<task>:<user or ->:<turn_ref or request_uuid>` |
  | the watchers told of a person's flags | `off_purpose_signal:<task>:<user or ->:<local date>` |
  | an anomaly rule broken | `anomaly:<task>:<user or ->:<rule>:<local date>` |

  The period key is the local date (`2026-10-22`) or month (`2026-10`) of the
  site time zone. A key that was inserted (here or, seen as a conflict, on
  another node) is also kept on this node until its window ends, so a limit
  that stays past its threshold costs no further write. A forgiving
  (`limit_forgiven`), a block (`blocked`) and a lift (`unblocked`) have no
  key: every one is kept.

  ## Who is told

  The watchers (`watchers/2`): the setting `ai_guard_watchers` (a JSON list of
  user uuids, changed with `set_watchers/2`; empty — every Owner) and the
  people the task's `watchers` callback names for the user, without the user
  themself. They get a notification of type `"ai_guard"`
  (`PhoenixKit.Notifications.create_many/2`, which leaves out a watcher who
  switched the type off), in the site's content language. A user's own limit
  is told to the user in the app (`PhoenixKit.Notifications.upsert_inapp/3`):
  at the warn percent the user only, when reached the user and the watchers.

  Each signalled event is written to the Activity log as `guard.<kind>` with
  the event as its resource (`resource_uuid`; never `target_uuid`, which
  would notify the user a second time). A text names the task, the user by
  e-mail and the limit with its numbers — never a reason or anything of a
  call's content. The reason of an off-purpose flag stays in its event row
  (`flags/2` shows it to those allowed); a block's reason and a lift's note
  stay in the block row.

  A signal never fails the call that caused it: a failure is logged as its
  class only.
  """

  use Gettext, backend: PhoenixKitAI.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.{Activity, Notifications, Settings}
  alias PhoenixKit.Users.{Auth, Roles}
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.{RecipientLocale, Routes}
  alias PhoenixKitAI.{Budget, Endpoint, Guard, GuardBlock, GuardBlocks, GuardEvent, TaskLimits}
  alias PhoenixKitAI.{Request, Tasks, TaskSpec}

  @notice_type "ai_guard"
  @icon "hero-shield-exclamation"
  @watchers_key "ai_guard_watchers"
  # Core keeps a string setting to 1000 characters; the list is JSON text.
  @watchers_max 1000

  @doc "The notification type of the guard's signals."
  @spec notice_type() :: String.t()
  def notice_type, do: @notice_type

  @doc "The setting holding the watchers."
  @spec watchers_setting() :: String.t()
  def watchers_setting, do: @watchers_key

  # ===========================================
  # WATCHERS
  # ===========================================

  @doc "The configured watchers (`ai_guard_watchers`); empty means every Owner."
  @spec configured_watchers() :: [String.t()]
  def configured_watchers do
    case Settings.get_setting(@watchers_key) do
      value when is_binary(value) and value != "" ->
        case Jason.decode(value) do
          {:ok, list} when is_list(list) -> Enum.filter(list, &valid_uuid?/1)
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Who is told about `spec` (`nil` for no task) and `user_uuid`: the configured
  watchers (or every Owner) and the task's own, without the user.
  """
  @spec watchers(TaskSpec.t() | nil, String.t() | nil) :: [String.t()]
  def watchers(spec, user_uuid) do
    configured =
      case configured_watchers() do
        [] -> "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
        uuids -> uuids
      end

    (configured ++ task_watchers(spec, user_uuid))
    |> Enum.uniq()
    |> List.delete(user_uuid)
  end

  defp task_watchers(%TaskSpec{watchers: {module, function, args}}, user_uuid) do
    module
    |> apply(function, args ++ [user_uuid])
    |> List.wrap()
    |> Enum.filter(&valid_uuid?/1)
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] watchers callback failed: #{inspect(error.__struct__)}")
      []
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAI] watchers callback failed: #{kind}")
      []
  end

  defp task_watchers(_spec, _user_uuid), do: []

  @doc """
  Sets the watchers (`ai_guard_watchers`); an empty list means every Owner.
  A uuid of nobody is left out, with a warning, and the rest are saved; the
  answer lists who was saved. Needs `ai.manage`; written to the Activity log
  with who changed it.
  """
  @spec set_watchers(term(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, :forbidden | :invalid_uuid | :too_long | term()}
  def set_watchers(scope, uuids) when is_list(uuids) do
    with :ok <- Guard.authorize_manage(scope),
         {:ok, uuids} <- cast_uuids(uuids),
         uuids = existing_users(uuids),
         json = Jason.encode!(uuids),
         :ok <- if(String.length(json) <= @watchers_max, do: :ok, else: {:error, :too_long}),
         {:ok, setting} <- Settings.update_setting_with_module(@watchers_key, json, "ai") do
      Activity.log("ai", "guard.watchers_updated",
        actor_uuid: Guard.actor_uuid(scope),
        resource_type: "setting",
        resource_uuid: setting.uuid,
        metadata: %{"count" => length(uuids)}
      )

      {:ok, uuids}
    end
  end

  defp cast_uuids(uuids) do
    cast = Enum.map(uuids, &Ecto.UUID.cast/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)),
      do: {:ok, cast |> Enum.map(&elem(&1, 1)) |> Enum.uniq()},
      else: {:error, :invalid_uuid}
  end

  defp existing_users([]), do: []

  defp existing_users(uuids) do
    found =
      from(u in User, where: u.uuid in ^uuids, select: u.uuid)
      |> repo().all()
      |> MapSet.new()

    case Enum.count(uuids, &(not MapSet.member?(found, &1))) do
      0 ->
        :ok

      missing ->
        Logger.warning(
          "[PhoenixKitAI] #{missing} watcher(s) left out of ai_guard_watchers: no such user"
        )
    end

    Enum.filter(uuids, &MapSet.member?(found, &1))
  end

  defp valid_uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  # ===========================================
  # EVENTS
  # ===========================================

  @doc """
  Inserts an event. `{:ok, event}` when it was written, `:duplicate` when its
  `dedupe_key` was already taken — known on this node (kept until `:until`,
  default the end of the local day) or found taken in the database.
  """
  @spec record(map()) :: {:ok, GuardEvent.t()} | :duplicate
  def record(attrs) when is_map(attrs) do
    key = attrs[:dedupe_key]

    if is_binary(key) and sent?(key) do
      :duplicate
    else
      result = insert(attrs)
      if is_binary(key), do: remember(key, attrs[:until])
      result
    end
  end

  defp insert(attrs) do
    row =
      attrs
      |> Map.take(GuardEvent.__schema__(:fields))
      |> Map.put(:uuid, UUIDv7.generate())
      |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.update!(:inserted_at, &DateTime.truncate(&1, :second))

    case repo().insert_all(GuardEvent, [row],
           on_conflict: :nothing,
           conflict_target: {:unsafe_fragment, "(dedupe_key) WHERE dedupe_key IS NOT NULL"},
           returning: true
         ) do
      {1, [event]} -> {:ok, event}
      {0, _} -> :duplicate
    end
  end

  @doc false
  # Whether `key` was written and is still kept on this node: a caller may
  # skip work that could only end in a duplicate.
  @spec already_sent?(String.t()) :: boolean()
  def already_sent?(key) when is_binary(key), do: sent?(key)

  defp sent?(key) do
    case :ets.lookup(flags_table(), {__MODULE__, :sent, key}) do
      [{_key, until}] -> System.os_time(:second) < until
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  # Kept until the window of the key ends; the ones already past are dropped
  # here, so the table holds the open windows only.
  defp remember(key, until) do
    now = System.os_time(:second)
    until = DateTime.to_unix(until || elem(TaskLimits.windows().day, 1))

    :ets.select_delete(flags_table(), [
      {{{__MODULE__, :sent, :_}, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    :ets.insert(flags_table(), {{__MODULE__, :sent, key}, until})
  rescue
    ArgumentError -> false
  end

  @doc false
  # Forgets the keys kept on this node (tests: the database is rolled back,
  # the table is not).
  @spec reset_sent() :: :ok
  def reset_sent do
    :ets.match_delete(flags_table(), {{__MODULE__, :sent, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp flags_table, do: PhoenixKitAI.RequestCache.flags_table()

  @doc "A limit of `spec` at its warn percent (see the moduledoc)."
  @spec limit_warning(TaskSpec.t(), String.t() | nil, TaskLimits.status()) :: :ok
  def limit_warning(%TaskSpec{} = spec, user_uuid, status) do
    safely(fn ->
      with {:ok, event} <- limit_event("limit_warning", spec, user_uuid, status) do
        log(event)
        tell_warning(spec, user_uuid, status)
      end
    end)
  end

  defp tell_warning(spec, nil, status), do: tell_watchers(spec, nil, &warn_text(&1, spec, status))

  defp tell_warning(spec, user_uuid, status),
    do: tell_user(user_uuid, spec, status, &warn_text_for_user/2)

  @doc "A limit of `spec` reached (see the moduledoc)."
  @spec limit_reached(TaskSpec.t(), String.t() | nil, TaskLimits.status()) :: :ok
  def limit_reached(%TaskSpec{} = spec, user_uuid, status) do
    safely(fn ->
      with {:ok, event} <- limit_event("limit_reached", spec, user_uuid, status) do
        log(event)
        tell_reached(spec, user_uuid, status)
      end
    end)
  end

  defp tell_reached(spec, nil, status),
    do: tell_watchers(spec, nil, &reached_text(&1, spec, status, nil))

  defp tell_reached(spec, user_uuid, status) do
    tell_user(user_uuid, spec, status, &reached_text_for_user/2)
    tell_watchers(spec, user_uuid, &reached_text(&1, spec, status, user_uuid))
  end

  defp limit_event(kind, spec, user_uuid, status) do
    record(%{
      kind: kind,
      task_key: spec.key,
      user_uuid: user_uuid,
      ref: %{
        "scope" => Atom.to_string(status.scope),
        "unit" => Atom.to_string(status.unit),
        "period" => Atom.to_string(status.period),
        "used" => status.used,
        "limit" => status.limit
      },
      dedupe_key: "#{kind}:#{spec.key}:#{user_uuid || "-"}:#{status.unit}:#{status.period_key}",
      until: status.ends_at
    })
  end

  @doc """
  A limit forgiven: the count of `scope` and `period` starts again at `now`.
  Written to the Activity log with who forgave it; nobody is notified.
  """
  @spec limit_forgiven(
          String.t(),
          String.t() | nil,
          TaskLimits.scope(),
          TaskLimits.period(),
          String.t() | nil,
          DateTime.t()
        ) :: {:ok, GuardEvent.t()} | :duplicate
  def limit_forgiven(task_key, user_uuid, scope, period, actor_uuid, now) do
    with {:ok, event} <-
           record(%{
             kind: "limit_forgiven",
             task_key: task_key,
             user_uuid: user_uuid,
             actor_uuid: actor_uuid,
             ref: %{"scope" => Atom.to_string(scope), "period" => Atom.to_string(period)},
             inserted_at: now
           }) do
      log(event, actor_uuid)
      {:ok, event}
    end
  end

  @doc """
  A `PhoenixKitAI.Budget` cap refused a call: a `limit_reached` event (scope
  `budget:<scope>`) and the watchers told, once per local day.
  """
  @spec budget_refused(Budget.scope(), Endpoint.t(), keyword(), DateTime.t()) :: :ok
  def budget_refused(scope, %Endpoint{} = endpoint, opts, now \\ DateTime.utc_now()) do
    safely(fn ->
      user_uuid = if is_binary(opts[:user_uuid]), do: opts[:user_uuid]
      spec = Tasks.get(Guard.task_key(opts) || "")
      day = TaskLimits.period_keys(now).day

      id =
        case scope do
          user when user in [:user, :user_calls] -> user_uuid || "-"
          :endpoint -> endpoint.uuid
          _global -> "-"
        end

      with {:ok, event} <-
             record(%{
               kind: "limit_reached",
               task_key: Guard.task_key(opts),
               user_uuid: if(scope in [:user, :user_calls], do: user_uuid),
               endpoint_uuid: endpoint.uuid,
               ref: %{"scope" => "budget:#{scope}"},
               dedupe_key: "limit_reached:budget:#{scope}:#{id}:#{day}",
               until: elem(TaskLimits.windows(now).day, 1)
             }) do
        log(event)
        tell_watchers(spec, user_uuid, &budget_text(&1, scope))
      end
    end)
  end

  @doc """
  The model of `endpoint` no longer has what `spec` needs (`missing`): an
  event and the watchers told, once a day per task and endpoint.
  """
  @spec model_unfit(TaskSpec.t(), Endpoint.t(), [TaskSpec.need()], DateTime.t()) :: :ok
  def model_unfit(%TaskSpec{} = spec, %Endpoint{} = endpoint, missing, now \\ DateTime.utc_now()) do
    safely(fn ->
      day = TaskLimits.period_keys(now).day

      with {:ok, event} <-
             record(%{
               kind: "model_unfit",
               task_key: spec.key,
               endpoint_uuid: endpoint.uuid,
               ref: %{"model" => endpoint.model, "missing" => Enum.map(missing, &to_string/1)},
               dedupe_key: "model_unfit:#{spec.key}:#{endpoint.uuid}:#{day}",
               until: elem(TaskLimits.windows(now).day, 1)
             }) do
        log(event)
        tell_watchers(spec, nil, &unfit_text(&1, spec, endpoint, missing))
      end
    end)
  end

  @doc """
  An off-purpose flag of `spec` for `user_uuid` (nil for none): one event
  per turn or call (`ref`: `"turn_ref"` or `"request_uuid"`; the request
  uuid is linked when its row exists), and on the person's first flag in the
  task that day, an `off_purpose_signal` and the watchers told — without the
  reason. `{:ok, event}`, or `:duplicate` when the turn or call was flagged.
  """
  @spec off_purpose(TaskSpec.t(), String.t() | nil, String.t() | nil, map(), DateTime.t()) ::
          {:ok, GuardEvent.t()} | :duplicate
  def off_purpose(%TaskSpec{} = spec, user_uuid, reason, ref, now \\ DateTime.utc_now()) do
    id = ref["turn_ref"] || ref["request_uuid"]

    result =
      record(%{
        kind: "off_purpose",
        task_key: spec.key,
        user_uuid: user_uuid,
        request_uuid: linked_request(ref["request_uuid"]),
        ref: ref,
        reason: reason,
        dedupe_key: "off_purpose:#{spec.key}:#{user_uuid || "-"}:#{id}"
      })

    with {:ok, event} <- result, do: off_purpose_signal(spec, user_uuid, event, now)
    result
  end

  defp linked_request(uuid) when is_binary(uuid) do
    if repo().exists?(from(r in Request, where: r.uuid == ^uuid)), do: uuid
  end

  defp linked_request(_uuid), do: nil

  defp off_purpose_signal(spec, user_uuid, event, now) do
    safely(fn ->
      with {:ok, signal} <-
             record(%{
               kind: "off_purpose_signal",
               task_key: spec.key,
               user_uuid: user_uuid,
               ref: %{"event_uuid" => event.uuid},
               dedupe_key:
                 "off_purpose_signal:#{spec.key}:#{user_uuid || "-"}:#{TaskLimits.period_keys(now).day}",
               until: elem(TaskLimits.windows(now).day, 1)
             }) do
        log(signal)
        tell_watchers(spec, user_uuid, &off_purpose_text(&1, spec))
      end
    end)
  end

  @doc """
  An anomaly rule of `spec` broken by the call of `request` (`rule`:
  `"source"`, `"calls_per_hour"` or `"tokens_per_call"`, with the value
  seen and the task's limit): an event and the watchers told, once a day per
  task, person and rule.
  """
  @spec anomaly(TaskSpec.t(), Request.t(), String.t(), term(), term(), DateTime.t()) :: :ok
  def anomaly(
        %TaskSpec{} = spec,
        %Request{} = request,
        rule,
        value,
        limit,
        now \\ DateTime.utc_now()
      ) do
    safely(fn ->
      with {:ok, event} <-
             record(%{
               kind: "anomaly",
               task_key: spec.key,
               user_uuid: request.user_uuid,
               request_uuid: request.uuid,
               ref: %{"rule" => rule, "value" => value, "limit" => limit},
               dedupe_key: anomaly_key(spec, request.user_uuid, rule, now),
               until: elem(TaskLimits.windows(now).day, 1)
             }) do
        log(event)
        tell_watchers(spec, request.user_uuid, &anomaly_text(&1, spec, rule, limit))
      end
    end)
  end

  @doc false
  @spec anomaly_key(TaskSpec.t(), String.t() | nil, String.t(), DateTime.t()) :: String.t()
  def anomaly_key(%TaskSpec{key: key}, user_uuid, rule, now \\ DateTime.utc_now()),
    do: "anomaly:#{key}:#{user_uuid || "-"}:#{rule}:#{TaskLimits.period_keys(now).day}"

  @doc """
  A block set or lifted (`kind`: `"blocked"` or `"unblocked"`) by
  `actor_uuid`: the event, the Activity entry, the watchers (but the actor)
  told and the person told in the app — none of them with the reason or the
  note.
  """
  @spec block_event(String.t(), GuardBlock.t(), String.t() | nil) :: :ok
  def block_event(kind, %GuardBlock{} = block, actor_uuid) when kind in ~w(blocked unblocked) do
    safely(fn ->
      spec = block.origin_task_key && Tasks.get(block.origin_task_key)
      task = block_task_label(block, spec)

      with {:ok, event} <-
             record(%{
               kind: kind,
               task_key: block.origin_task_key || block.block_group,
               user_uuid: block.user_uuid,
               actor_uuid: actor_uuid,
               ref: %{"group" => block.block_group, "block_uuid" => block.uuid}
             }) do
        log(event, actor_uuid)

        Notifications.upsert_inapp(block.user_uuid, "ai:guard:block:#{block.block_group}", %{
          text: block_text_for_user(kind, task),
          icon: @icon
        })

        # Whoever set or lifted it knows already.
        tell_watchers(spec, block.user_uuid, &block_text(&1, kind, task), actor_uuid)
      end
    end)
  end

  defp block_task_label(_block, %TaskSpec{} = spec), do: TaskSpec.label(spec)

  defp block_task_label(block, nil) do
    case GuardBlocks.tasks_of(block.block_group) do
      [] -> block.block_group
      specs -> Enum.map_join(specs, ", ", &TaskSpec.label/1)
    end
  end

  @doc """
  The off-purpose flags of a task in the last `days` (default 30), for the
  Tasks page as `viewer` (a scope) may see them: the count per person (most
  first) and the latest `limit` flags (default 20). A flag's reason and its
  journal row are left out (`hidden: true`) of a private task's flags unless
  the viewer may manage the guard (`PhoenixKitAI.Guard.reasons_visible?/2`).
  """
  @spec flags(TaskSpec.t(), term(), keyword()) :: %{
          counts: [{String.t() | nil, pos_integer()}],
          flags: [map()]
        }
  def flags(%TaskSpec{} = spec, viewer, opts \\ []) do
    since = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days, 30), :day)
    visible? = Guard.reasons_visible?(viewer, spec.private)

    base =
      from(e in GuardEvent,
        where: e.task_key == ^spec.key and e.kind == "off_purpose" and e.inserted_at >= ^since
      )

    counts =
      from(e in base,
        group_by: e.user_uuid,
        select: {e.user_uuid, count(e.uuid)},
        order_by: [desc: count(e.uuid)]
      )
      |> repo().all()

    flags =
      from(e in base, order_by: [desc: e.inserted_at], limit: ^Keyword.get(opts, :limit, 20))
      |> repo().all()
      |> Enum.map(fn event ->
        %{
          uuid: event.uuid,
          user_uuid: event.user_uuid,
          inserted_at: event.inserted_at,
          reason: if(visible?, do: event.reason),
          request_uuid: if(visible?, do: event.request_uuid),
          hidden: not visible?
        }
      end)

    %{counts: counts, flags: flags}
  end

  @doc "The limit events of the current windows of a task (for the Tasks page)."
  @spec reached_users(String.t(), DateTime.t()) :: [GuardEvent.t()]
  def reached_users(task_key, now \\ DateTime.utc_now()) do
    keys = TaskLimits.period_keys(now)
    %{month: {month_from, _}} = TaskLimits.windows(now)

    from(e in GuardEvent,
      where:
        e.task_key == ^task_key and e.kind == "limit_reached" and not is_nil(e.user_uuid) and
          e.inserted_at >= ^month_from,
      order_by: [desc: e.inserted_at]
    )
    |> repo().all()
    |> Enum.filter(fn event ->
      String.ends_with?(event.dedupe_key || "", [":" <> keys.day, ":" <> keys.month]) and
        not String.starts_with?(event.dedupe_key || "", "limit_reached:budget:")
    end)
  end

  defp log(%GuardEvent{} = event, actor_uuid \\ nil) do
    Activity.log("ai", "guard." <> event.kind,
      mode: if(actor_uuid, do: "manual", else: "auto"),
      actor_uuid: actor_uuid,
      resource_type: "ai_guard_event",
      resource_uuid: event.uuid,
      metadata:
        %{"task" => event.task_key, "user_uuid" => event.user_uuid}
        |> Map.merge(Map.take(event.ref || %{}, ["scope", "unit", "period"]))
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  # ===========================================
  # TELLING
  # ===========================================

  defp tell_watchers(spec, user_uuid, text_fun, actor_uuid \\ nil) do
    case List.delete(watchers(spec, user_uuid), actor_uuid) do
      [] ->
        :ok

      watchers ->
        email = if user_uuid, do: user_email(user_uuid)

        Notifications.create_many(watchers, %{
          type: @notice_type,
          text: for_watchers(fn -> text_fun.(email) end),
          icon: @icon,
          link: Routes.path("/admin/ai/tasks")
        })
    end
  end

  defp tell_user(user_uuid, spec, status, text_fun) do
    Notifications.upsert_inapp(
      user_uuid,
      "ai:guard:limit:#{spec.key}:#{status.unit}:#{status.period_key}",
      %{text: text_fun.(spec, status), icon: @icon}
    )
  end

  defp user_email(user_uuid) do
    case Auth.get_user(user_uuid) do
      %{email: email} -> email
      nil -> gettext("A user")
    end
  end

  # The watchers are other people than the one whose call this is, and one
  # text goes to all of them: the site's content language, else the default
  # locale.
  defp for_watchers(fun) do
    language = Settings.get_content_language() || PhoenixKit.Config.default_locale()

    RecipientLocale.in_locale(language, fn ->
      Gettext.with_locale(PhoenixKitAI.Gettext, Gettext.get_locale(PhoenixKitWeb.Gettext), fun)
    end)
  end

  # ===========================================
  # TEXTS
  # ===========================================

  @doc "A limit in words, e.g. \"daily request limit\"."
  @spec limit_name(TaskLimits.unit(), TaskLimits.period()) :: String.t()
  def limit_name(:money, :day), do: gettext("daily spending limit")
  def limit_name(:money, :month), do: gettext("monthly spending limit")
  def limit_name(:requests, :day), do: gettext("daily request limit")
  def limit_name(:requests, :month), do: gettext("monthly request limit")
  def limit_name(:tokens, :day), do: gettext("daily token limit")
  def limit_name(:tokens, :month), do: gettext("monthly token limit")

  @doc "An amount of a unit for display: dollars for money, a count otherwise."
  @spec format_amount(TaskLimits.unit(), non_neg_integer()) :: String.t()
  def format_amount(:money, micro), do: "$" <> format_usd(micro)
  def format_amount(_unit, amount), do: Integer.to_string(amount)

  @doc "Micro-dollars as dollars with at least two decimals: `1_500_000` is `\"1.50\"`."
  @spec format_usd(integer()) :: String.t()
  def format_usd(micro) when is_integer(micro) do
    text =
      micro
      |> Decimal.new()
      |> Decimal.div(1_000_000)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    case String.split(text, ".") do
      [whole] -> whole <> ".00"
      [whole, <<_::binary-size(1)>> = fraction] -> "#{whole}.#{fraction}0"
      _ -> text
    end
  end

  defp numbers(status),
    do: [
      used: format_amount(status.unit, status.used),
      limit: format_amount(status.unit, status.limit),
      name: limit_name(status.unit, status.period)
    ]

  defp warn_text_for_user(spec, status) do
    gettext(
      "You have used %{used} of your %{name} (%{limit}) in the AI task %{task}.",
      numbers(status) ++ [task: TaskSpec.label(spec)]
    )
  end

  defp reached_text_for_user(spec, status) do
    gettext(
      "You have reached your %{name} (%{limit}) in the AI task %{task}.",
      numbers(status) ++ [task: TaskSpec.label(spec)]
    )
  end

  defp warn_text(_email, spec, status) do
    gettext(
      "The AI task %{task} has used %{used} of its %{name} (%{limit}).",
      numbers(status) ++ [task: TaskSpec.label(spec)]
    )
  end

  defp reached_text(_email, spec, status, nil) do
    gettext(
      "The AI task %{task} has reached its %{name} (%{limit}).",
      numbers(status) ++ [task: TaskSpec.label(spec)]
    )
  end

  defp reached_text(email, spec, status, _user_uuid) do
    gettext(
      "%{email} has reached the %{name} (%{limit}) in the AI task %{task}.",
      numbers(status) ++ [task: TaskSpec.label(spec), email: email]
    )
  end

  defp budget_text(_email, scope) do
    gettext(
      "An AI spending cap (%{cap}) refused a call. Calls are refused until spending is below it.",
      cap: budget_scope(scope)
    )
  end

  defp budget_scope(:global), do: gettext("the whole site")
  defp budget_scope(:endpoint), do: gettext("one endpoint")
  defp budget_scope(:user), do: gettext("one user's spending")
  defp budget_scope(:user_calls), do: gettext("one user's calls")
  defp budget_scope(other), do: to_string(other)

  defp unfit_text(_email, spec, endpoint, missing) do
    gettext("The AI task %{task} uses the endpoint %{endpoint}, whose model now lacks: %{needs}.",
      task: TaskSpec.label(spec),
      endpoint: endpoint.name,
      needs: Tasks.need_labels(missing)
    )
  end

  defp off_purpose_text(nil, spec) do
    gettext(
      "The AI task %{task} was asked for something outside its purpose. The flags are on the AI tasks page.",
      task: TaskSpec.label(spec)
    )
  end

  defp off_purpose_text(email, spec) do
    gettext(
      "%{email} asked the AI task %{task} for something outside its purpose. The flags are on the AI tasks page.",
      email: email,
      task: TaskSpec.label(spec)
    )
  end

  defp anomaly_text(nil, spec, rule, limit) do
    gettext("Unusual use of the AI task %{task}: %{rule}.",
      task: TaskSpec.label(spec),
      rule: rule_text(rule, limit)
    )
  end

  defp anomaly_text(email, spec, rule, limit) do
    gettext("Unusual use of the AI task %{task} by %{email}: %{rule}.",
      task: TaskSpec.label(spec),
      email: email,
      rule: rule_text(rule, limit)
    )
  end

  @doc "An anomaly rule in words."
  @spec rule_text(String.t(), term()) :: String.t()
  def rule_text("source", _limit), do: gettext("a call from a place the task does not expect")

  def rule_text("calls_per_hour", limit),
    do: gettext("more than %{limit} calls in an hour", limit: limit)

  def rule_text("tokens_per_call", limit),
    do: gettext("a call of more than %{limit} tokens", limit: limit)

  def rule_text(rule, _limit), do: to_string(rule)

  defp block_text(email, "blocked", task),
    do: gettext("%{email} is blocked from the AI task %{task}.", email: email, task: task)

  defp block_text(email, "unblocked", task),
    do:
      gettext("%{email} is no longer blocked from the AI task %{task}.", email: email, task: task)

  defp block_text_for_user("blocked", task) do
    gettext("You are blocked from the AI task %{task} until an administrator lifts the block.",
      task: task
    )
  end

  defp block_text_for_user("unblocked", task),
    do: gettext("You are no longer blocked from the AI task %{task}.", task: task)

  # A signal is never worth a call: a failure is logged as its class only.
  defp safely(fun) do
    _ = fun.()
    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKitAI] a guard signal was not sent: #{inspect(error.__struct__)}")
      :ok
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAI] a guard signal was not sent: #{kind}")
      :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
