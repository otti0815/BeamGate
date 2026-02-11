defmodule ReverseProxy.ControlPlane do
  @moduledoc """
  ETS-backed state store for routers, services, endpoints, and metrics.
  Writes are serialized through this GenServer; reads are direct ETS lookups.
  """

  use GenServer

  alias ReverseProxy.ControlPlane.{Endpoint, Router, Service}

  @routers :rp_routers
  @services :rp_services
  @endpoints :rp_endpoints
  @lb :rp_lb
  @metrics :rp_metrics
  @certs :rp_certs

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def put_router(attrs), do: GenServer.call(__MODULE__, {:put_router, attrs})
  def delete_router(id), do: GenServer.call(__MODULE__, {:delete_router, id})
  def list_routers, do: :ets.tab2list(@routers) |> Enum.map(&elem(&1, 1))
  def get_router(id), do: lookup(@routers, id)

  def put_service(attrs), do: GenServer.call(__MODULE__, {:put_service, attrs})
  def delete_service(id), do: GenServer.call(__MODULE__, {:delete_service, id})
  def list_services, do: :ets.tab2list(@services) |> Enum.map(&elem(&1, 1))
  def get_service(id), do: lookup(@services, id)

  def put_endpoint(attrs), do: GenServer.call(__MODULE__, {:put_endpoint, attrs})
  def delete_endpoint(id), do: GenServer.call(__MODULE__, {:delete_endpoint, id})
  def delete_endpoints_for_service(service_id), do: GenServer.call(__MODULE__, {:delete_endpoints_for_service, service_id})
  def list_endpoints, do: :ets.tab2list(@endpoints) |> Enum.map(&elem(&1, 1))

  def list_endpoints_for_service(service_id) do
    @endpoints
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.service_id == service_id))
  end

  def mark_endpoint_health(endpoint_id, status), do: GenServer.cast(__MODULE__, {:mark_endpoint_health, endpoint_id, status})

  def match_router(host, path, tls?) do
    list_routers()
    |> Enum.filter(fn router ->
      host_ok?(router.host, host) and path_ok?(router.path_prefix, path) and tls_ok?(router, tls?)
    end)
    |> Enum.sort_by(fn router ->
      {(router.host && 1) || 0, String.length(router.path_prefix || "/")}
    end, :desc)
    |> List.first()
  end

  def select_endpoint(service_id) do
    service = get_service(service_id)

    endpoints =
      list_endpoints_for_service(service_id)
      |> Enum.filter(&(&1.health_status in [:up, :unknown]))

    case {service, endpoints} do
      {nil, _} -> nil
      {_, []} -> nil
      {%Service{load_balancer_strategy: :round_robin}, list} -> round_robin(service_id, list)
      {_, [first | _]} -> first
    end
  end

  def put_cert(domain, cert_pem, key_pem), do: GenServer.call(__MODULE__, {:put_cert, domain, cert_pem, key_pem})

  def get_cert(domain), do: lookup(@certs, domain)

  def incr_metric(metric, value \\ 1), do: :ets.update_counter(@metrics, metric, {2, value}, {metric, 0})
  def set_metric(metric, value), do: :ets.insert(@metrics, {metric, value})
  def metrics, do: :ets.tab2list(@metrics) |> Map.new()

  @impl true
  def init(_) do
    :ets.new(@routers, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@services, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@endpoints, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@lb, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@metrics, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@certs, [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_router, attrs}, _from, state) do
    router = struct(Router, attrs)
    :ets.insert(@routers, {router.id, router})
    refresh_topology_metrics()
    {:reply, {:ok, router}, state}
  end

  def handle_call({:delete_router, id}, _from, state) do
    :ets.delete(@routers, id)
    refresh_topology_metrics()
    {:reply, :ok, state}
  end

  def handle_call({:put_service, attrs}, _from, state) do
    service = struct(Service, attrs)
    :ets.insert(@services, {service.id, service})
    refresh_topology_metrics()
    {:reply, {:ok, service}, state}
  end

  def handle_call({:delete_service, id}, _from, state) do
    :ets.delete(@services, id)
    refresh_topology_metrics()
    {:reply, :ok, state}
  end

  def handle_call({:put_endpoint, attrs}, _from, state) do
    endpoint = struct(Endpoint, attrs)
    :ets.insert(@endpoints, {endpoint.id, endpoint})
    refresh_topology_metrics()
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call({:delete_endpoint, id}, _from, state) do
    :ets.delete(@endpoints, id)
    refresh_topology_metrics()
    {:reply, :ok, state}
  end

  def handle_call({:delete_endpoints_for_service, service_id}, _from, state) do
    list_endpoints_for_service(service_id)
    |> Enum.each(fn endpoint -> :ets.delete(@endpoints, endpoint.id) end)

    refresh_topology_metrics()
    {:reply, :ok, state}
  end

  def handle_call({:put_cert, domain, cert_pem, key_pem}, _from, state) do
    :ets.insert(@certs, {domain, %{cert: cert_pem, key: key_pem}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:mark_endpoint_health, endpoint_id, status}, state) do
    case lookup(@endpoints, endpoint_id) do
      nil -> :ok
      endpoint -> :ets.insert(@endpoints, {endpoint.id, %{endpoint | health_status: status}})
    end

    {:noreply, state}
  end

  defp lookup(table, id) do
    case :ets.lookup(table, id) do
      [{^id, value}] -> value
      [] -> nil
    end
  end

  defp round_robin(service_id, endpoints) do
    idx = :ets.update_counter(@lb, service_id, {2, 1}, {service_id, -1})
    Enum.at(endpoints, rem(idx, length(endpoints)))
  end

  defp host_ok?(nil, _host), do: true
  defp host_ok?("", _host), do: true

  defp host_ok?(configured, host) do
    String.downcase(configured || "") == String.downcase(host || "")
  end

  defp path_ok?(nil, _path), do: true
  defp path_ok?("", _path), do: true
  defp path_ok?(prefix, path), do: String.starts_with?(path || "/", prefix)

  defp tls_ok?(%Router{tls_enabled: false}, _), do: true
  defp tls_ok?(%Router{tls_enabled: true}, true), do: true
  defp tls_ok?(%Router{tls_enabled: true}, false), do: false

  defp refresh_topology_metrics do
    set_metric(:proxy_routes_total, :ets.info(@routers, :size))
    set_metric(:proxy_services_total, :ets.info(@services, :size))
    set_metric(:proxy_endpoints_total, :ets.info(@endpoints, :size))
  end
end
