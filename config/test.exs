import Config

config :beam_gate, BeamGateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # Test-only constant, intentionally long enough for Plug session cookies.
  secret_key_base: "test-local-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz-0123456789",
  server: false

config :logger, level: :warning
