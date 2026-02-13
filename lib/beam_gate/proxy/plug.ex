defmodule BeamGate.Proxy.Plug do
  @moduledoc "Main proxy entrypoint for all non-admin requests."
  @behaviour Plug

  import Plug.Conn

  alias BeamGate.ControlPlane
  alias BeamGate.Proxy.{BasicAuth, Forwarder, RequestLogger}

  def init(opts), do: opts

  def call(conn, _opts) do
    log_ctx = RequestLogger.start(conn)

    host = conn.host
    path = conn.request_path
    tls? = conn.scheme == :https

    case ControlPlane.match_router(host, path, tls?) do
      nil ->
        conn = send_resp(conn, 404, "Route not found")
        finish(conn, log_ctx, 404, nil, nil)

      route ->
        with {:ok, conn} <- BasicAuth.authorize(conn, route.middleware || %{}),
             endpoint when not is_nil(endpoint) <- ControlPlane.select_endpoint(route.service_id),
             {:ok, conn} <- Forwarder.forward(conn, route, endpoint) do
          status = conn.status || 200
          ControlPlane.incr_metric(:proxy_requests_total, 1)
          ControlPlane.set_metric(:proxy_last_status, status)
          finish(conn, log_ctx, status, route, endpoint)
        else
          {:halt, conn} ->
            finish(conn, log_ctx, conn.status || 401, route, nil)

          nil ->
            conn = send_resp(conn, 503, "No healthy upstream endpoint")
            finish(conn, log_ctx, 503, route, nil)

          {:error, reason} ->
            conn = send_resp(conn, 502, "Bad gateway: #{inspect(reason)}")
            finish(conn, log_ctx, 502, route, nil)
        end
    end
  end

  defp finish(conn, log_ctx, status, route, endpoint) do
    RequestLogger.finish(log_ctx, status, route, endpoint)
    conn
  end
end
