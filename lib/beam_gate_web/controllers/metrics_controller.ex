defmodule BeamGateWeb.MetricsController do
  use BeamGateWeb, :controller

  alias BeamGate.ControlPlane

  def index(conn, _params) do
    metrics = ControlPlane.metrics()

    payload = [
      "# HELP proxy_requests_total Total proxied requests",
      "# TYPE proxy_requests_total counter",
      "proxy_requests_total #{Map.get(metrics, :proxy_requests_total, 0)}",
      "",
      "# HELP proxy_routes_total Current route count",
      "# TYPE proxy_routes_total gauge",
      "proxy_routes_total #{Map.get(metrics, :proxy_routes_total, 0)}",
      "",
      "# HELP proxy_endpoints_total Current endpoint count",
      "# TYPE proxy_endpoints_total gauge",
      "proxy_endpoints_total #{Map.get(metrics, :proxy_endpoints_total, 0)}",
      "proxy_endpoints_up #{Map.get(metrics, :proxy_endpoints_up, 0)}",
      "proxy_endpoints_down #{Map.get(metrics, :proxy_endpoints_down, 0)}",
      "",
      "# HELP proxy_discovered_containers_total Docker containers discovered",
      "# TYPE proxy_discovered_containers_total gauge",
      "proxy_discovered_containers_total #{Map.get(metrics, :proxy_discovered_containers_total, 0)}"
    ]

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Enum.join(payload, "\n"))
  end
end
