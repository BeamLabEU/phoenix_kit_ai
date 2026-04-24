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

  def app(assigns) do
    ~H"""
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
