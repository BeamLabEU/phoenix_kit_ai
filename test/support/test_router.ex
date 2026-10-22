defmodule PhoenixKitAI.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitAI.Routes` so `live/2` calls in tests work
  with exactly the same URLs the LiveViews push themselves to.

  Both localized and prefixless routes come from the production route module,
  so navigation works with either of core's language configurations.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router
  import PhoenixKitAI.Test.RouteMacros

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitAI.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/" do
    pipe_through(:browser)

    live_session :ai_test,
      layout: {PhoenixKitAI.Test.Layouts, :app},
      on_mount: {PhoenixKitAI.Test.Hooks, :assign_scope} do
      ai_routes()

      scope "/:locale" do
        ai_locale_routes()
      end
    end
  end
end
