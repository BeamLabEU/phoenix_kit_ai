defmodule PhoenixKitAI.Web.Access do
  @moduledoc """
  The permission checks of the module's admin pages. `can?/2` checks a
  sub-permission against the socket's scope. The `ai.manage` check, made
  again on every
  event (`PhoenixKitAI.Guard.may_manage?/1`: an Owner, or a holder of
  `ai.manage`).

  A LiveView keeps the scope it got at mount, so a role taken away while the
  page is open, a switch to another role or a logout would still read as the
  rights of the mount. A check here passes only if two scopes both hold:

    * the socket's (`:phoenix_kit_current_scope`, set by core's `on_mount`);
    * the scope as it is now: the scope of the **session**
      (`PhoenixKit.Users.Auth.SessionRef`; it must still be live, its user
      active and confirmed, narrowed to the role the session acts as).

  The page calls `assign_session/2` in its `mount/3`. The session reference
  is read from the signed session only in the connected mount; the static
  render has none and is checked against the socket's scope alone, which
  core's `on_mount` has just built. A connected page whose scope cannot be
  rebuilt is refused everything.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKitAI.Guard

  @doc """
  Keeps the reference of the session the page runs in (see the moduledoc):
  read from `session` in the connected mount, `nil` in the static render.
  """
  @spec assign_session(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_session(socket, session) do
    ref =
      with true <- Phoenix.LiveView.connected?(socket),
           {:ok, ref} <- SessionRef.from_session(session) do
        ref
      else
        _none -> nil
      end

    assign(socket, :ai_session_ref, ref)
  end

  @doc """
  Whether the socket's scope holds the AI sub-permission `key` (an Owner
  always does). The page-level rule for `ai.view_usage` and
  `ai.manage_endpoints`: checked at mount and again in every event that
  reads or writes what the key gates. Fails closed on an absent scope.
  """
  @spec can?(Phoenix.LiveView.Socket.t(), String.t()) :: boolean()
  def can?(socket, key) when is_binary(key) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope -> Scope.owner?(scope) or Scope.can?(scope, key)
      _ -> false
    end
  end

  @doc "Whether the signed-in person may change the AI task guard now (see the moduledoc)."
  @spec may_manage?(Phoenix.LiveView.Socket.t()) :: boolean()
  def may_manage?(socket), do: match?({:ok, _scope}, manage_scope(socket))

  @doc """
  `may_manage?/1` that also hands back the scope it checked: `{:ok, scope}`
  with the scope as it is now (`session_scope/1`), the one to give a
  context function, so the check and the call read the same scope (rebuilt
  once); `:error` when the person may not.
  """
  @spec manage_scope(Phoenix.LiveView.Socket.t()) :: {:ok, Scope.t()} | :error
  def manage_scope(socket), do: scope_with(socket, &Guard.may_manage?/1)

  @doc """
  `manage_scope/1` for deciding AI reviews: `ai.review`, `ai.manage` or an
  Owner (`Guard.may_review?/1`), in both scopes.
  """
  @spec review_scope(Phoenix.LiveView.Socket.t()) :: {:ok, Scope.t()} | :error
  def review_scope(socket), do: scope_with(socket, &Guard.may_review?/1)

  @doc "Whether the signed-in person may decide AI reviews now (see `review_scope/1`)."
  @spec may_review?(Phoenix.LiveView.Socket.t()) :: boolean()
  def may_review?(socket), do: match?({:ok, _scope}, review_scope(socket))

  defp scope_with(socket, allowed?) do
    with %Scope{} = scope <- socket.assigns[:phoenix_kit_current_scope],
         %Scope{} = now <- session_scope(socket),
         true <- allowed?.(scope) and allowed?.(now) do
      {:ok, now}
    else
      _ -> :error
    end
  end

  @doc """
  The scope as it is now (`nil` if it can no longer act, see the moduledoc):
  what a context function that checks `ai.manage` itself is given.
  """
  @spec session_scope(Phoenix.LiveView.Socket.t()) :: Scope.t() | nil
  def session_scope(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: current_scope(socket),
      else: socket.assigns[:phoenix_kit_current_scope]
  end

  defp current_scope(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{user: %{uuid: uuid}} when is_binary(uuid) ->
        from_session(socket, uuid)

      _ ->
        nil
    end
  rescue
    _db_error -> nil
  end

  defp from_session(socket, user_uuid) do
    with {token_uuid, _user_uuid} <- socket.assigns[:ai_session_ref],
         {:ok, %Scope{} = scope} <- SessionRef.scope_for_session(token_uuid, user_uuid) do
      scope
    else
      _gone -> nil
    end
  end
end
