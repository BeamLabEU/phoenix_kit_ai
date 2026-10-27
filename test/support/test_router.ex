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

  # Core's own scope hook, so a test can drive a permission change through
  # the real refresh path (ScopeNotifier broadcast -> the hook -> the page's
  # `phoenix_kit_scope_changed/1`). One route; the rest use the test hook.
  scope "/core-scope" do
    pipe_through(:browser)

    live_session :ai_core_scope_test,
      layout: {PhoenixKitAI.Test.Layouts, :app},
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
      live("/admin/ai/usage", PhoenixKitAI.Web.Endpoints, :usage, as: :core_scope_ai_usage)
      live("/admin/ai/tasks", PhoenixKitAI.Web.Tasks, :index, as: :core_scope_ai_tasks)

      live("/admin/ai/endpoints/new", PhoenixKitAI.Web.EndpointForm, :new,
        as: :core_scope_ai_endpoint_new
      )
    end
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
