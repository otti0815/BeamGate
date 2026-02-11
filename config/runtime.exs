import Config

if config_env() in [:dev, :prod] do
  cert_path = Application.fetch_env!(:reverse_proxy, :cert_path)
  key_path = Application.fetch_env!(:reverse_proxy, :key_path)
  env_secret = System.get_env("SECRET_KEY_BASE")

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

  secret_key_base =
    cond do
      is_binary(env_secret) and byte_size(env_secret) >= 64 ->
        env_secret

      is_binary(env_secret) and byte_size(env_secret) < 64 ->
        raise "SECRET_KEY_BASE must be at least 64 bytes"

      config_env() == :prod ->
        raise "SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"

      true ->
        "dev-local-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz-0123456789"
    end

  config :reverse_proxy, ReverseProxyWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    https: https_opts,
    secret_key_base: secret_key_base,
    server: true
end
