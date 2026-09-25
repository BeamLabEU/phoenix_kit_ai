defmodule PhoenixKitAI.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in
  the host app and the phoenix_kit core — these just wrap LiveView
  content in an HTML shell so `Phoenix.LiveViewTest` can render it.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  # Core's admin layout renders `page_section` / `page_crumbs` / `page_title`
  # as the header breadcrumb and `page_subtitle` under it, which is why the
  # LiveViews here set the assigns instead of putting a heading in their own
  # markup. Mirror that, or every test asserting on a page's name fails
  # against a page that is rendering perfectly well.
  def app(assigns) do
    ~H"""
    <nav :if={assigns[:page_section]} id="page-trail">
      <a :if={assigns[:page_section_path]} href={@page_section_path}>{@page_section}</a>
      <span :if={!assigns[:page_section_path]}>{@page_section}</span>
      <span :for={crumb <- assigns[:page_crumbs] || []} class="crumb">
        <a :if={crumb[:path]} href={crumb.path}>{crumb.label}</a>
        <span :if={!crumb[:path]}>{crumb.label}</span>
      </span>
    </nav>
    <h1 :if={assigns[:page_title]}>{@page_title}</h1>
    <p :if={assigns[:page_subtitle]}>{@page_subtitle}</p>
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" role="alert">{msg}</div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" role="alert">{msg}</div>
    <div :if={msg = Phoenix.Flash.get(@flash, :warning)} id="flash-warning" role="alert">
      {msg}
    </div>
    {@inner_content}
    """
  end

  # Phoenix's error pipeline will try to render "<status>.html" from the
  # layouts module if a LiveView raises during mount. Forward everything
  # to a single generic template so tests get a readable error instead
  # of a `no template defined` crash.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
