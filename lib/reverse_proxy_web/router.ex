defmodule ReverseProxyWeb.Router do
  use ReverseProxyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReverseProxyWeb.Layouts, :root}
  end

  pipeline :admin_auth do
    plug ReverseProxyWeb.Plugs.AdminAuth
  end

  scope "/admin", ReverseProxyWeb do
    pipe_through :browser

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
    get "/logout", AdminSessionController, :delete
    delete "/logout", AdminSessionController, :delete
  end

  scope "/admin", ReverseProxyWeb do
    pipe_through [:browser, :admin_auth]

    live "/dashboard", DashboardLive, :index
  end

  scope "/", ReverseProxyWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/metrics", MetricsController, :index
    get "/health", HealthController, :index
  end

  forward "/", ReverseProxy.Proxy.Plug
end
