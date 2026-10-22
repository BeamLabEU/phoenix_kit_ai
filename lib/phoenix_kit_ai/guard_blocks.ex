defmodule PhoenixKitAI.GuardBlocks do
  @moduledoc """
  Blocks: a person may not call a group of AI tasks until the block is lifted
  (`PhoenixKitAI.GuardBlock`). A person sets them — there is no automatic
  block.

  ## Groups

  A block is on a task's `block_group`, or on the task's key when it names
  none, so tasks that take the same kind of free text (`free_text`: the
  Playground and an assistant's chat) share one block. A block of a group is
  private when any task of the group is (`private: true`): its reason is
  shown only to the holders of `ai.manage`.

  ## The check

  `check/2` runs on every call of a declared task that has a user, before
  the model check (see `PhoenixKitAI.Guard`), and in `PhoenixKitAI.Guard.admit/4`:
  a blocked call is refused with `{:error, {:task_blocked, block_group}}`,
  which names the group and never the reason (the refusal is a journal row
  every holder of `ai` reads). A turn admitted before the block runs to its
  end. A dry run (`process_image(dry_run: true)`) is not checked.

  ## Who may

  | | set a block | lift a block |
  |---|---|---|
  | an Owner | anybody | any block, their own too (kept as a record) |
  | a holder of `ai.manage` | anybody but an Owner | another person's, not an Owner's |
  | a holder of `agent.manage` | — | another person's `free_text` block, not an Owner's |
  | anybody else | — | — |

  Nobody but an Owner lifts their own block. `agent.manage` is checked by
  its string; this module does not depend on the assistant's.

  Each block and lift is a `blocked` / `unblocked` event, a notification to
  the watchers (`PhoenixKitAI.GuardEvents`), an in-app notice to the person,
  and an Activity entry with the event as its resource. None of them carries
  the reason or the note.

  ## The cache

  The active blocks of every group are kept on each node (the request
  cache's flags table), loaded with one query, so a call without a block
  costs none. A block or a lift drops this node's copy at once and
  broadcasts `{:guard_blocks_changed, block_group}` on
  `PhoenixKitAI.TaskLimits.topic/0`,
  which `PhoenixKitAI.GuardWatch` turns into the same drop on every node; a
  restarted watch drops it too. The copy is also read again after 60
  seconds. The check fails open: a database error reads as no block.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAI.{Guard, GuardBlock, GuardEvent, GuardEvents, TaskLimits, Tasks, TaskSpec}

  @free_text "free_text"
  @agent_manage "agent.manage"
  @text_max 500
  @cache_ttl_ms :timer.seconds(60)

  # ===========================================
  # GROUPS
  # ===========================================

  @doc "The block group of a task: its `block_group`, or its key."
  @spec group(TaskSpec.t()) :: String.t()
  def group(%TaskSpec{block_group: group}) when is_binary(group) and group != "", do: group
  def group(%TaskSpec{key: key}), do: key

  @doc "The declared tasks of a block group."
  @spec tasks_of(String.t()) :: [TaskSpec.t()]
  def tasks_of(group) when is_binary(group), do: Enum.filter(Tasks.list(), &(group(&1) == group))

  @doc "Whether a block of `group` is private: any of its tasks is."
  @spec private?(String.t()) :: boolean()
  def private?(group), do: Enum.any?(tasks_of(group), & &1.private)

  # ===========================================
  # THE CHECK
  # ===========================================

  @doc """
  `:ok`, or `{:error, {:task_blocked, block_group}}` when `user_uuid` is
  blocked from the task's group. A call without a task or a user is `:ok`.
  """
  @spec check(TaskSpec.t() | nil, term()) :: :ok | {:error, {:task_blocked, String.t()}}
  def check(%TaskSpec{} = spec, user_uuid) when is_binary(user_uuid) do
    group = group(spec)

    if Map.has_key?(cached(), {group, user_uuid}),
      do: {:error, {:task_blocked, group}},
      else: :ok
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI] blocks of #{inspect(spec.key)} not checked: #{inspect(error.__struct__)}"
      )

      :ok
  end

  def check(_spec, _user_uuid), do: :ok

  @doc "Whether `user_uuid` is blocked from `task_key` now."
  @spec blocked?(String.t(), term()) :: boolean()
  def blocked?(task_key, user_uuid) do
    match?({:error, {:task_blocked, _}}, check(Tasks.get(task_key), user_uuid))
  end

  @doc """
  The active block of `user_uuid` in `task_key`'s group, or nil — without
  its reason and note, for a page or notice that shows the state. With the
  reason: `active/3`.
  """
  @spec active(String.t(), term()) :: GuardBlock.t() | nil
  def active(task_key, user_uuid) do
    case active_block(task_key, user_uuid) do
      nil -> nil
      block -> %{block | reason: nil, lift_note: nil}
    end
  end

  @doc """
  The active block as `viewer` (a scope) may see it: its reason only when
  `PhoenixKitAI.Guard.reasons_visible?/2` allows it (any viewer of a
  block that is not private; `ai.manage` or an Owner for a private one).
  """
  @spec active(String.t(), term(), term()) :: GuardBlock.t() | nil
  def active(task_key, user_uuid, viewer) do
    case active_block(task_key, user_uuid) do
      nil ->
        nil

      block ->
        if Guard.reasons_visible?(viewer, block.private),
          do: block,
          else: %{block | reason: nil, lift_note: nil}
    end
  end

  defp active_block(task_key, user_uuid) when is_binary(user_uuid) do
    case Tasks.get(task_key) do
      nil -> nil
      spec -> Map.get(cached(), {group(spec), user_uuid})
    end
  end

  defp active_block(_task_key, _user_uuid), do: nil

  @doc "The active blocks of a group, newest first (from the database)."
  @spec list_active(String.t()) :: [GuardBlock.t()]
  def list_active(group) when is_binary(group) do
    from(b in GuardBlock,
      where: b.block_group == ^group and is_nil(b.lifted_at),
      order_by: [desc: b.blocked_at]
    )
    |> repo().all()
  end

  # ===========================================
  # RIGHTS
  # ===========================================

  @doc "Whether `scope` may block `user_uuid` (see the moduledoc)."
  @spec may_block?(term(), String.t()) :: boolean()
  def may_block?(scope, user_uuid), do: authorize_block(scope, user_uuid) == :ok

  @doc "Whether `scope` may lift `block` (see the moduledoc)."
  @spec may_lift?(term(), GuardBlock.t()) :: boolean()
  def may_lift?(scope, %GuardBlock{} = block), do: authorize_lift(scope, block) == :ok

  defp authorize_block(scope, user_uuid) do
    cond do
      not Guard.may_manage?(scope) -> {:error, :forbidden}
      owner_target?(user_uuid) and not Scope.owner?(scope) -> {:error, :owner_only}
      true -> :ok
    end
  end

  defp authorize_lift(scope, %GuardBlock{} = block) do
    cond do
      Scope.owner?(scope) -> :ok
      not lifter?(scope, block) -> {:error, :forbidden}
      owner_target?(block.user_uuid) -> {:error, :owner_only}
      Guard.actor_uuid(scope) == block.user_uuid -> {:error, :own_block}
      true -> :ok
    end
  end

  defp lifter?(scope, block) do
    Guard.may_manage?(scope) or
      (block.block_group == @free_text and match?(%Scope{}, scope) and
         Scope.can?(scope, @agent_manage))
  end

  # A person holding the Owner role at all, whatever role they act as now.
  defp owner_target?(user_uuid) do
    case repo().get(User, user_uuid) do
      %User{} = user -> Roles.user_has_role_owner?(user)
      nil -> false
    end
  end

  # ===========================================
  # CHANGES
  # ===========================================

  @doc """
  Blocks `user_uuid` from the group of `task_or_group` (a task key, or a
  block group's name). `reason` is kept, cut to 500 characters; `origin`
  may name the flag it came from (`%{event_uuid: uuid}`, kept when the flag
  is that person's). Needs `ai.manage`, and an Owner to block an Owner (see
  the moduledoc).
  """
  @spec block(term(), String.t(), term(), term(), map() | keyword() | nil) ::
          {:ok, GuardBlock.t()}
          | {:error,
             :forbidden
             | :owner_only
             | :unknown_task
             | :invalid_user
             | :unknown_user
             | :already_blocked
             | Ecto.Changeset.t()}
  def block(scope, task_or_group, user_uuid, reason, origin \\ nil)
      when is_binary(task_or_group) do
    with :ok <- if(Guard.may_manage?(scope), do: :ok, else: {:error, :forbidden}),
         {:ok, group, origin_task} <- resolve(task_or_group),
         {:ok, user_uuid} <- user(user_uuid),
         :ok <- authorize_block(scope, user_uuid),
         {:ok, block} <- insert(scope, group, origin_task, user_uuid, reason, origin) do
      changed(group)
      GuardEvents.block_event("blocked", block, Guard.actor_uuid(scope))
      {:ok, block}
    end
  end

  defp resolve(task_or_group) do
    case Tasks.get(task_or_group) do
      %TaskSpec{} = spec ->
        {:ok, group(spec), spec.key}

      nil ->
        if tasks_of(task_or_group) == [],
          do: {:error, :unknown_task},
          else: {:ok, task_or_group, nil}
    end
  end

  defp insert(scope, group, origin_task, user_uuid, reason, origin) do
    %GuardBlock{
      block_group: group,
      user_uuid: user_uuid,
      origin_task_key: origin_task,
      origin_event_uuid: origin_event(origin, user_uuid),
      private: private?(group),
      reason: text(reason),
      blocked_by_uuid: Guard.actor_uuid(scope),
      blocked_at: now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:block_group, :user_uuid],
      name: :phoenix_kit_ai_guard_blocks_active_index,
      message: "already blocked"
    )
    |> Ecto.Changeset.check_constraint(:reason, name: :phoenix_kit_ai_guard_blocks_text_check)
    |> repo().insert()
    |> case do
      {:ok, block} ->
        {:ok, block}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :block_group),
          do: {:error, :already_blocked},
          else: {:error, changeset}
    end
  end

  # The flag the block came from, when it is one of this person's.
  defp origin_event(origin, user_uuid) when is_map(origin) or is_list(origin) do
    with uuid when is_binary(uuid) <- origin[:event_uuid] || get(origin, "event_uuid"),
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %GuardEvent{user_uuid: ^user_uuid} <- repo().get(GuardEvent, uuid) do
      uuid
    else
      _ -> nil
    end
  end

  defp origin_event(_origin, _user_uuid), do: nil

  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(_list, _key), do: nil

  @doc """
  Lifts `block` (a `%GuardBlock{}` or its uuid), keeping `note` (cut to 500
  characters) and who lifted it. Who may: see the moduledoc.
  """
  @spec unblock(term(), GuardBlock.t() | String.t(), term()) ::
          {:ok, GuardBlock.t()}
          | {:error, :forbidden | :owner_only | :own_block | :not_blocked | :not_found}
  def unblock(scope, block_or_uuid, note) do
    with {:ok, block} <- fetch(block_or_uuid),
         :ok <- authorize_lift(scope, block),
         {:ok, lifted} <- lift(block, scope, note) do
      changed(lifted.block_group)
      GuardEvents.block_event("unblocked", lifted, Guard.actor_uuid(scope))
      {:ok, lifted}
    end
  end

  # Read again: the struct a caller holds may be stale.
  defp fetch(%GuardBlock{uuid: uuid}), do: fetch(uuid)

  defp fetch(uuid) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %GuardBlock{lifted_at: nil} = block <- repo().get(GuardBlock, uuid) do
      {:ok, block}
    else
      %GuardBlock{} -> {:error, :not_blocked}
      _ -> {:error, :not_found}
    end
  end

  defp fetch(_other), do: {:error, :not_found}

  # Only an active row is lifted, so two lifts at once leave one record.
  defp lift(block, scope, note) do
    values = [lifted_at: now(), lifted_by_uuid: Guard.actor_uuid(scope), lift_note: text(note)]

    case from(b in GuardBlock, where: b.uuid == ^block.uuid and is_nil(b.lifted_at), select: b)
         |> repo().update_all(set: values) do
      {1, [lifted]} -> {:ok, lifted}
      {0, _} -> {:error, :not_blocked}
    end
  end

  defp user(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_uuid),
         true <- repo().exists?(from(u in User, where: u.uuid == ^uuid)) do
      {:ok, uuid}
    else
      :error -> {:error, :invalid_user}
      false -> {:error, :unknown_user}
    end
  end

  @doc false
  # A reason or note as kept: trimmed, blank as nil, at most 500 code points
  # — what the database's `char_length` counts; a grapheme (an emoji of
  # several code points) is never split. A text whose first grapheme alone
  # is longer is cut by code points.
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> cut(text)
    end
  end

  def text(_value), do: nil

  defp cut(text) do
    {kept, _count} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
        count = count + length(String.codepoints(grapheme))

        if count > @text_max,
          do: {:halt, {kept, count}},
          else: {:cont, {[grapheme | kept], count}}
      end)

    case kept do
      [] -> text |> String.codepoints() |> Enum.take(@text_max) |> Enum.join()
      kept -> kept |> Enum.reverse() |> Enum.join()
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ===========================================
  # THE CACHE
  # ===========================================

  @doc false
  @spec cache_ttl_ms() :: pos_integer()
  def cache_ttl_ms, do: @cache_ttl_ms

  @doc false
  # Drops this node's copy (see the moduledoc).
  @spec forget() :: :ok
  def forget do
    key = {__MODULE__, :generation}
    :ets.update_counter(flags_table(), key, 1, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Forgets the copy (tests, and a restarted watch).
  @spec reset_cache() :: :ok
  def reset_cache do
    :ets.delete(flags_table(), {__MODULE__, :active})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp changed(group) do
    forget()
    PubSub.broadcast(TaskLimits.topic(), {:guard_blocks_changed, group})
  end

  # `%{{group, user_uuid} => block}` of the active blocks.
  defp cached do
    table = flags_table()
    generation = generation(table)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, {__MODULE__, :active}) do
      [{_key, {^generation, loaded_at, entry}}] when now - loaded_at < @cache_ttl_ms ->
        entry

      _missing_stale_or_old ->
        entry = load()
        :ets.insert(table, {{__MODULE__, :active}, {generation, now, entry}})
        entry
    end
  rescue
    ArgumentError -> load()
  end

  defp generation(table) do
    case :ets.lookup(table, {__MODULE__, :generation}) do
      [{_key, generation}] -> generation
      [] -> 0
    end
  end

  defp load do
    from(b in GuardBlock, where: is_nil(b.lifted_at))
    |> repo().all()
    |> Map.new(&{{&1.block_group, &1.user_uuid}, &1})
  end

  defp flags_table, do: PhoenixKitAI.RequestCache.flags_table()

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
