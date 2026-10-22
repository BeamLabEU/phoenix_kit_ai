defmodule PhoenixKitAI.Test.RouteMacros do
  @moduledoc false

  defmacro ai_routes, do: PhoenixKitAI.Routes.admin_routes()
  defmacro ai_locale_routes, do: PhoenixKitAI.Routes.admin_locale_routes()
end
