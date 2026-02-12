import Config

config :reverse_proxy, ReverseProxyWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  code_reloader: true,
  debug_errors: true,
  check_origin: false,
  # Dev-only constant, intentionally long enough for Plug session cookies.
  secret_key_base: "dev-local-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz-0123456789",
  watchers: []

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
