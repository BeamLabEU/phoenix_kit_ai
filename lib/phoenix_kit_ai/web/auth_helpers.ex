defmodule PhoenixKitAI.Web.AuthHelpers do
  @moduledoc """
  Per-LV actor-resolution helpers.

  Every mutating context call in the AI admin LVs threads `actor_uuid`
  + `actor_role` through `actor_opts(socket)` so the activity feed
  attributes the change to the right user. This module is the single
  source for that shape — without it, four copies (`endpoints.ex`,
  `endpoint_form.ex`, `prompts.ex`, `prompt_form.ex`) drifted in
  parallel.
  """

  alias PhoenixKit.Users.Auth.Scope

  @doc """
  Builds the `actor_opts` keyword list expected by every mutating
  context fn (`create_endpoint/2`, `update_endpoint/3`,
  `delete_endpoint/2`, `reorder_endpoints/2`, `create_prompt/2`,
  `update_prompt/3`, etc).

  Returns `[actor_uuid: uuid, actor_role: "admin" | "user"]` when the
  socket carries a `phoenix_kit_current_user` with a uuid, or
  `[actor_role: ...]` only when no user is in the socket (rare —
  on_mount usually guarantees one, but defensive callers still want
  the role).
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def actor_opts(socket) do
    role = if admin?(socket), do: "admin", else: "user"

    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> [actor_uuid: uuid, actor_role: role]
      _ -> [actor_role: role]
    end
  end

  @doc """
  Returns `true` when the socket's scope reports admin role, `false`
  otherwise (including `nil` scope).
  """
  @spec admin?(Phoenix.LiveView.Socket.t()) :: boolean()
  def admin?(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.admin?(scope)
    end
  end
end
