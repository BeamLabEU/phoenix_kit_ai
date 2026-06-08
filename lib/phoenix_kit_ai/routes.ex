defmodule PhoenixKitAI.Routes do
  @moduledoc """
  Route module for PhoenixKit AI admin routes.

  Defines all admin LiveView routes for the AI module. Both `admin_locale_routes/0`
  and `admin_routes/0` define the same routes — one for localized paths (with
  `/:locale` prefix) and one for non-localized paths.

  Called by PhoenixKit's integration via the `route_module/0` callback.
  """

  alias PhoenixKit.Utils.Routes

  @doc """
  Admin routes for localized paths (with /:locale prefix).
  """
  def admin_locale_routes do
    quote do
      live("/admin/ai", PhoenixKitAI.Web.Endpoints, :index, as: :ai_index_localized)

      live("/admin/ai/endpoints", PhoenixKitAI.Web.Endpoints, :endpoints,
        as: :ai_endpoints_localized
      )

      live("/admin/ai/endpoints/new", PhoenixKitAI.Web.EndpointForm, :new,
        as: :ai_endpoint_new_localized
      )

      live("/admin/ai/endpoints/:id/edit", PhoenixKitAI.Web.EndpointForm, :edit,
        as: :ai_endpoint_edit_localized
      )

      live("/admin/ai/prompts", PhoenixKitAI.Web.Prompts, :index, as: :ai_prompts_localized)

      live("/admin/ai/prompts/new", PhoenixKitAI.Web.PromptForm, :new,
        as: :ai_prompt_new_localized
      )

      live("/admin/ai/prompts/:id/edit", PhoenixKitAI.Web.PromptForm, :edit,
        as: :ai_prompt_edit_localized
      )

      live("/admin/ai/playground", PhoenixKitAI.Web.Playground, :index,
        as: :ai_playground_localized
      )

      live("/admin/ai/usage", PhoenixKitAI.Web.Endpoints, :usage, as: :ai_usage_localized)
    end
  end

  @doc """
  Admin routes for non-localized paths.
  """
  def admin_routes do
    quote do
      live("/admin/ai", PhoenixKitAI.Web.Endpoints, :index, as: :ai_index)
      live("/admin/ai/endpoints", PhoenixKitAI.Web.Endpoints, :endpoints, as: :ai_endpoints)
      live("/admin/ai/endpoints/new", PhoenixKitAI.Web.EndpointForm, :new, as: :ai_endpoint_new)

      live("/admin/ai/endpoints/:id/edit", PhoenixKitAI.Web.EndpointForm, :edit,
        as: :ai_endpoint_edit
      )

      live("/admin/ai/prompts", PhoenixKitAI.Web.Prompts, :index, as: :ai_prompts)
      live("/admin/ai/prompts/new", PhoenixKitAI.Web.PromptForm, :new, as: :ai_prompt_new)
      live("/admin/ai/prompts/:id/edit", PhoenixKitAI.Web.PromptForm, :edit, as: :ai_prompt_edit)

      live("/admin/ai/playground", PhoenixKitAI.Web.Playground, :index, as: :ai_playground)
      live("/admin/ai/usage", PhoenixKitAI.Web.Endpoints, :usage, as: :ai_usage)
    end
  end

  @doc """
  Prefix-aware path to the AI admin section (`/admin/ai`).

  Wraps core's generic `PhoenixKit.Utils.Routes.path/1` so the plugin owns its
  own admin URL instead of a module-specific helper living in core's Routes util.
  Used by the AI admin LiveViews to build sort/navigation links.
  """
  @spec ai_path() :: String.t()
  def ai_path, do: Routes.path("/admin/ai")
end
