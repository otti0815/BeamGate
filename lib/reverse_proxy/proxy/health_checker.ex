defmodule ReverseProxy.Proxy.HealthChecker do
  @moduledoc "Periodic HTTP health checks for all known endpoints."

  use GenServer

  alias ReverseProxy.ControlPlane

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    interval = Application.get_env(:reverse_proxy, :health_check_interval_ms, 10_000)
    Process.send_after(self(), :check, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:check, state) do
    path = Application.get_env(:reverse_proxy, :health_check_path, "/health")

    ControlPlane.list_endpoints()
    |> Enum.each(fn endpoint ->
      health_path = endpoint.health_path || path
      url = "http://#{endpoint.host}:#{endpoint.port}#{health_path}"

      request = Finch.build(:get, url)

      status =
        case Finch.request(request, ReverseProxy.Finch, receive_timeout: 3_000) do
          {:ok, %Finch.Response{status: code}} when code >= 200 and code < 400 -> :up
          _ -> :down
        end

      ControlPlane.mark_endpoint_health(endpoint.id, status)
    end)

    update_health_metrics()

    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  defp update_health_metrics do
    endpoints = ControlPlane.list_endpoints()
    up = Enum.count(endpoints, &(&1.health_status == :up))
    down = Enum.count(endpoints, &(&1.health_status == :down))

    ControlPlane.set_metric(:proxy_endpoints_up, up)
    ControlPlane.set_metric(:proxy_endpoints_down, down)
    ControlPlane.set_metric(:proxy_endpoints_total, length(endpoints))
  end
end
