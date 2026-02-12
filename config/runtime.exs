import Config

if config_env() == :prod do
  cert_path = Application.fetch_env!(:reverse_proxy, :cert_path)
  key_path = Application.fetch_env!(:reverse_proxy, :key_path)

  https_opts =
    if File.exists?(cert_path) and File.exists?(key_path) do
      [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("HTTPS_PORT", "4443")),
        cipher_suite: :strong,
        certfile: cert_path,
        keyfile: key_path
      ]
    else
      nil
    end

  # In production, sessions must use a real external secret.
  config :reverse_proxy, ReverseProxyWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    https: https_opts,
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true
end
