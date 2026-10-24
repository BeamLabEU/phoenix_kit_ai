defmodule PhoenixKitAI.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which is configured by core `phoenix_kit` to populate
  `socket.assigns[:phoenix_kit_current_scope]` and
  `socket.assigns[:phoenix_kit_current_user]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module resolves real fixture sessions through core's token loader.
  Display-only tests can supply a fake scope instead.

  Tests set scope via `LiveCase.put_test_scope/2` (which calls
  `Plug.Test.init_test_session/2`); real user scopes are represented by
  a session token so the cookie does not carry a complete user struct.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  `on_mount` callback. Resolves `"user_token"`, or reads a fake scope, and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. No-op when session has no scope (LiveView mounts
  with the same nil-scope state production sees for logged-out users).
  """
  def on_mount(:assign_scope, _params, session, socket) do
    scope =
      case Map.get(session, "user_token") do
        token when is_binary(token) ->
          token
          |> Auth.get_user_by_session_token()
          |> Scope.for_user()

        _ ->
          Map.get(session, "phoenix_kit_test_scope")
      end

    case scope do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end
end
