defmodule PhoenixKitAI.Web.AccessTest do
  @moduledoc """
  `PhoenixKitAI.Web.Access.manage_scope/1` hands back the scope it checked:
  the session's scope as it is now, rebuilt from the database, never the
  scope the socket was mounted with.
  """

  use PhoenixKitAI.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.Web.Access

  setup do
    PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)
    # the first user is the Owner
    _owner = Fixtures.user_fixture()
    :ok
  end

  # A connected socket whose mount scope is `mounted`, in `user`'s session.
  defp socket(user, mounted) do
    {:ok, user} = Auth.admin_confirm_user(user)
    session = %{"user_token" => Auth.generate_user_session_token(user)}

    %Socket{transport_pid: self()}
    |> Phoenix.Component.assign(:phoenix_kit_current_scope, mounted)
    |> Access.assign_session(session)
  end

  defp manager(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    {user, role_uuid}
  end

  test "the scope handed back is the session's now, not the mounted one" do
    {user, _role} = manager(["ai", "ai.manage"])
    mounted = Scope.for_user(%{user | email: "as-mounted@example.com"})

    assert {:ok, %Scope{} = scope} = user |> socket(mounted) |> Access.manage_scope()
    assert scope.user.uuid == user.uuid
    assert scope.user.email == user.email
    refute scope == mounted
  end

  test "a right taken away since the mount: refused" do
    {user, role_uuid} = manager(["ai", "ai.manage"])
    socket = socket(user, Scope.for_user(user))
    assert {:ok, _scope} = Access.manage_scope(socket)

    :ok = Permissions.set_permissions(role_uuid, ["ai"])
    assert Access.manage_scope(socket) == :error
    refute Access.may_manage?(socket)
  end

  test "without the right: refused" do
    {user, _role} = manager(["ai"])
    assert user |> socket(Scope.for_user(user)) |> Access.manage_scope() == :error
  end
end
