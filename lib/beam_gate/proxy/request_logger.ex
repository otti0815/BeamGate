defmodule BeamGate.Proxy.RequestLogger do
  @moduledoc false
  require Logger

  def start(conn) do
    %{
      started_at: System.monotonic_time(),
      method: conn.method,
      path: conn.request_path,
      host: conn.host,
      request_id: List.first(Plug.Conn.get_req_header(conn, "x-request-id"))
    }
  end

  def finish(ctx, status, route, endpoint) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - ctx.started_at, :native, :millisecond)

    Logger.info("proxy_request",
      request_id: ctx.request_id,
      method: ctx.method,
      path: ctx.path,
      host: ctx.host,
      status: status,
      duration_ms: duration_ms,
      route_id: route && route.id,
      service_id: route && route.service_id,
      endpoint_id: endpoint && endpoint.id
    )
  end
end
