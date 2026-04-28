defmodule PhoenixKitAI.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitAI.Routes` so `live/2` calls in tests work
  with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to prepending the default
  locale (`"en"`) to every admin path, so our scope is
  `/en/admin/ai/…`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitAI.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/ai", PhoenixKitAI.Web do
    pipe_through(:browser)

    live_session :ai_test, layout: {PhoenixKitAI.Test.Layouts, :app} do
      live("/", Endpoints, :index, as: :ai_index)
      live("/endpoints", Endpoints, :endpoints, as: :ai_endpoints)
      live("/endpoints/new", EndpointForm, :new, as: :ai_endpoint_new)
      live("/endpoints/:id/edit", EndpointForm, :edit, as: :ai_endpoint_edit)

      live("/prompts", Prompts, :index, as: :ai_prompts)
      live("/prompts/new", PromptForm, :new, as: :ai_prompt_new)
      live("/prompts/:id/edit", PromptForm, :edit, as: :ai_prompt_edit)

      live("/playground", Playground, :index, as: :ai_playground)
      live("/usage", Endpoints, :usage, as: :ai_usage)
    end
  end
end
