# ReverseProxy MVP (Elixir)

A single-node L7 reverse proxy MVP with:

- Dynamic router/service/endpoint state in ETS
- Docker label-based service discovery
- Host + path-prefix routing
- Round-robin upstream selection
- Basic auth + header injection middleware
- Health checks
- Embedded Phoenix LiveView admin dashboard
- Prometheus-style `/metrics`

## Architecture

- Data plane: `ReverseProxy.Proxy.Plug` + `ReverseProxy.Proxy.Forwarder`
- Control plane: `ReverseProxy.ControlPlane` (GenServer writes + ETS reads)
- Discovery: `ReverseProxy.Discovery.DockerWatcher`
- Admin UI: `ReverseProxyWeb.DashboardLive`

## Docker Labels

Supported container labels:

- `proxy.enable=true`
- `proxy.rule=Host(api.example.com)`
- `proxy.rule=Host(api.example.com) && PathPrefix(/v1)`
- `proxy.port=4000`
- `proxy.path_prefix=/api`
- `proxy.tls=true`
- `proxy.health_path=/healthz`
- `proxy.auth.user=admin`
- `proxy.auth.pass=secret`
- `proxy.req_header.x-foo=bar`
- `proxy.resp_header.x-powered-by=reverse-proxy`

## Environment Variables

- `PORT` (default `4000`)
- `HTTPS_PORT` (default `4443`)
- `PROXY_ADMIN_USER` (default `admin`)
- `PROXY_ADMIN_PASS` (default `admin`)
- `PROXY_ADMIN_IP_WHITELIST` (optional comma-separated IPs)
- `DOCKER_API_BASE` (default `http://localhost:2375`)
- `PROXY_TLS_CERT_PATH` (default `priv/certs/tls.crt`)
- `PROXY_TLS_KEY_PATH` (default `priv/certs/tls.key`)
- `PROXY_HEALTH_PATH` (default `/health`)

## Run

Start a reproducible dev shell first:

```bash
nix-shell
```

```bash
mix deps.get
mix phx.server
```

Admin UI: `http://localhost:4000/admin/dashboard`

Metrics: `http://localhost:4000/metrics`

Health: `http://localhost:4000/health`

Containerized run (single-node): `docker compose up --build`

## Notes

- TLS is enabled when cert/key files exist at configured paths.
- Docker discovery is polling-based in this MVP (set `DOCKER_API_BASE` to a reachable Docker API endpoint, e.g. `http://localhost:2375`).
- Upstream response streaming is chunked; request body handling currently reads request body before forwarding.
- This is single-node by design.
