import Config

config :reverse_proxy,
  ecto_repos: []

config :reverse_proxy, ReverseProxyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ReverseProxyWeb.ErrorHTML, json: ReverseProxyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ReverseProxy.PubSub,
  live_view: [signing_salt: "mvp-salt"]

config :reverse_proxy,
  docker_api_base: System.get_env("DOCKER_API_BASE", "http://localhost:2375"),
  docker_poll_interval_ms: 5_000,
  admin_user: System.get_env("PROXY_ADMIN_USER", "admin"),
  admin_pass: System.get_env("PROXY_ADMIN_PASS", "admin"),
  admin_ip_whitelist: System.get_env("PROXY_ADMIN_IP_WHITELIST", ""),
  cert_path: System.get_env("PROXY_TLS_CERT_PATH", "priv/certs/tls.crt"),
  key_path: System.get_env("PROXY_TLS_KEY_PATH", "priv/certs/tls.key"),
  health_check_path: System.get_env("PROXY_HEALTH_PATH", "/health"),
  health_check_interval_ms: 10_000

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :route_id, :service_id, :endpoint_id]

import_config "#{config_env()}.exs"
