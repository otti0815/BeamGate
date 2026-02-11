defmodule ReverseProxyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :reverse_proxy

  @session_options [
    store: :cookie,
    key: "_reverse_proxy_key",
    signing_salt: "dashboardsalt"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  if code_reloading? do
    plug Phoenix.LiveReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ReverseProxyWeb.Router
end
