defmodule ReverseProxyWeb do
  @moduledoc false

  def static_paths, do: []

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ReverseProxyWeb.Layouts]

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ReverseProxyWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      import Phoenix.HTML
      import Phoenix.LiveView.Helpers

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ReverseProxyWeb.Endpoint,
        router: ReverseProxyWeb.Router,
        statics: ReverseProxyWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
