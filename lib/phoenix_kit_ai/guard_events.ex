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

  The period key is the local date (`2026-10-22`) or month (`2026-10`) of the
  site time zone. A forgiving (`limit_forgiven`) has no key: every one is
  kept.

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
  call's content.

  A signal never fails the call that caused it: a failure is logged as its
  class only.
  """

  use Gettext, backend: PhoenixKitAI.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.{Activity, Notifications, Settings}
  alias PhoenixKit.Users.{Auth, Roles}
  alias PhoenixKit.Utils.{RecipientLocale, Routes}
  alias PhoenixKitAI.{Budget, Endpoint, Guard, GuardEvent, TaskLimits, Tasks, TaskSpec}

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
  Needs `ai.manage`; written to the Activity log with who changed it.
  """
  @spec set_watchers(term(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, :forbidden | :invalid_uuid | :too_long | term()}
  def set_watchers(scope, uuids) when is_list(uuids) do
    with :ok <- Guard.authorize_manage(scope),
         {:ok, uuids} <- cast_uuids(uuids),
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

  defp valid_uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  # ===========================================
  # EVENTS
  # ===========================================

  @doc """
  Inserts an event. `{:ok, event}` when it was written, `:duplicate` when its
  `dedupe_key` was already taken.
  """
  @spec record(map()) :: {:ok, GuardEvent.t()} | :duplicate
  def record(attrs) when is_map(attrs) do
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
      dedupe_key: "#{kind}:#{spec.key}:#{user_uuid || "-"}:#{status.unit}:#{status.period_key}"
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
               dedupe_key: "limit_reached:budget:#{scope}:#{id}:#{day}"
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
               dedupe_key: "model_unfit:#{spec.key}:#{endpoint.uuid}:#{day}"
             }) do
        log(event)
        tell_watchers(spec, nil, &unfit_text(&1, spec, endpoint, missing))
      end
    end)
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

  defp tell_watchers(spec, user_uuid, text_fun) do
    case watchers(spec, user_uuid) do
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
