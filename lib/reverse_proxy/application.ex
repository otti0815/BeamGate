defmodule ReverseProxy.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Finch, name: ReverseProxy.Finch},
      {Phoenix.PubSub, name: ReverseProxy.PubSub},
      ReverseProxy.Search.Supervisor,
      ReverseProxy.ControlPlane,
      ReverseProxy.Proxy.HealthChecker,
      ReverseProxy.Discovery.DockerWatcher,
      ReverseProxyWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ReverseProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    ReverseProxyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
