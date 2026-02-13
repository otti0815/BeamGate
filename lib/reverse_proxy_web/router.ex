defmodule ReverseProxyWeb.Router do
  use ReverseProxyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReverseProxyWeb.Layouts, :root}
  end

  pipeline :api do
    plug :accepts, ["json"]
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

  scope "/api/v1/search", ReverseProxyWeb do
    pipe_through :api

    put "/indexes/:index", SearchController, :create_index
    delete "/indexes/:index", SearchController, :delete_index
    get "/indexes/:index", SearchController, :get_index

    put "/indexes/:index/documents/:id", SearchController, :index_document
    get "/indexes/:index/documents/:id", SearchController, :get_document
    delete "/indexes/:index/documents/:id", SearchController, :delete_document

    post "/indexes/:index/_bulk", SearchController, :bulk
    post "/indexes/:index/_search", SearchController, :search
    post "/indexes/:index/_refresh", SearchController, :refresh
  end

  forward "/", ReverseProxy.Proxy.Plug
end
