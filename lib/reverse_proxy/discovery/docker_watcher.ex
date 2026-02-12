defmodule ReverseProxy.Discovery.DockerWatcher do
  @moduledoc """
  Docker-first service discovery loop.
  Polls Docker API and reconciles proxy state from labels.
  """

  use GenServer

  alias ReverseProxy.ControlPlane
  alias ReverseProxy.Discovery.{DockerClient, RuleParser}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def refresh_now, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(_) do
    interval = Application.get_env(:reverse_proxy, :docker_poll_interval_ms, 5_000)
    Process.send_after(self(), :refresh, 1000)
    {:ok, %{interval: interval, known: %{}}}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_info(:refresh, state) do
    # Only timer-driven refreshes schedule the next tick; manual refresh_now/0 reuses this schedule.
    state = refresh(state)
    Process.send_after(self(), :refresh, state.interval)
    {:noreply, state}
  end

  defp refresh(state) do
    case DockerClient.list_containers() do
      {:ok, containers} -> reconcile(containers, state)
      {:error, _reason} -> state
    end
  end

  defp reconcile(containers, %{known: known} = state) do
    # The in-memory map lets us remove stale routes when containers disappear.
    enabled =
      containers
      |> Enum.filter(&enabled_container?/1)
      |> Enum.map(&normalize_container/1)

    enabled_ids = MapSet.new(Enum.map(enabled, & &1.id))

    to_remove = known |> Map.keys() |> Enum.reject(&MapSet.member?(enabled_ids, &1))
    Enum.each(to_remove, fn id -> remove_container_state(id, known[id]) end)

    new_known =
      enabled
      |> Enum.reduce(Map.drop(known, to_remove), fn container, acc ->
        {:ok, mapping} = upsert_container_state(container)
        Map.put(acc, container.id, mapping)
      end)

    ControlPlane.set_metric(:proxy_discovered_containers_total, map_size(new_known))
    ControlPlane.set_metric(:proxy_routes_total, length(ControlPlane.list_routers()))

    %{state | known: new_known}
  end

  defp enabled_container?(container) do
    labels = Map.get(container, "Labels", %{})

    labels
    |> Map.get("proxy.enable", "false")
    |> String.downcase()
    |> Kernel.==("true")
  end

  defp normalize_container(container) do
    id = Map.fetch!(container, "Id")
    labels = Map.get(container, "Labels", %{})

    inspect =
      case DockerClient.inspect_container(id) do
        {:ok, payload} -> payload
        _ -> %{}
      end

    ip = extract_ip(inspect)

    names = Map.get(container, "Names", [])
    name = names |> List.first("unknown") |> String.trim_leading("/")

    rule = RuleParser.parse(Map.get(labels, "proxy.rule"))

    host = Map.get(labels, "proxy.host", rule.host)

    path_prefix =
      labels
      |> Map.get("proxy.path_prefix", rule.path_prefix)
      |> normalize_path_prefix()

    port = labels |> Map.get("proxy.port", "4000") |> parse_int(4000)

    tls_enabled =
      labels
      |> Map.get("proxy.tls", "false")
      |> String.downcase()
      |> Kernel.==("true")

    middleware = build_middleware(labels)

    %{
      id: id,
      name: name,
      host: host,
      path_prefix: path_prefix,
      port: port,
      ip: ip,
      tls_enabled: tls_enabled,
      middleware: middleware,
      labels: labels
    }
  end

  defp upsert_container_state(container) do
    service_id = "docker-service:#{container.id}"
    router_id = "docker-router:#{container.id}"
    endpoint_id = "docker-endpoint:#{container.id}:#{container.port}"

    _ =
      ControlPlane.put_service(%{
        id: service_id,
        name: container.name,
        load_balancer_strategy: :round_robin,
        metadata: %{source: :docker, labels: container.labels}
      })

    _ =
      ControlPlane.put_router(%{
        id: router_id,
        service_id: service_id,
        host: container.host,
        path_prefix: container.path_prefix,
        tls_enabled: container.tls_enabled,
        source: :docker,
        middleware: container.middleware
      })

    _ =
      ControlPlane.put_endpoint(%{
        id: endpoint_id,
        service_id: service_id,
        host: container.ip,
        port: container.port,
        health_status: :unknown,
        health_path: Map.get(container.labels, "proxy.health_path", "/health"),
        metadata: %{source: :docker, container_id: container.id}
      })

    {:ok, %{router_id: router_id, service_id: service_id, endpoint_id: endpoint_id}}
  end

  defp remove_container_state(_container_id, nil), do: :ok

  defp remove_container_state(_container_id, mapping) do
    ControlPlane.delete_router(mapping.router_id)
    ControlPlane.delete_endpoint(mapping.endpoint_id)
    ControlPlane.delete_service(mapping.service_id)
  end

  defp extract_ip(inspect_payload) do
    networks = get_in(inspect_payload, ["NetworkSettings", "Networks"]) || %{}

    networks
    |> Map.values()
    |> Enum.map(&Map.get(&1, "IPAddress"))
    |> Enum.find("127.0.0.1", fn ip -> is_binary(ip) and ip != "" end)
  end

  defp parse_int(value, fallback) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_path_prefix(prefix) when prefix in [nil, ""], do: "/"

  defp normalize_path_prefix(prefix) do
    if String.starts_with?(prefix, "/"), do: prefix, else: "/" <> prefix
  end

  defp build_middleware(labels) do
    basic_auth =
      if labels["proxy.auth.user"] && labels["proxy.auth.pass"] do
        %{username: labels["proxy.auth.user"], password: labels["proxy.auth.pass"]}
      else
        nil
      end

    req_headers = prefixed_values(labels, "proxy.req_header.")
    resp_headers = prefixed_values(labels, "proxy.resp_header.")

    %{}
    |> maybe_put(:basic_auth, basic_auth)
    |> maybe_put(:request_headers, req_headers)
    |> maybe_put(:response_headers, resp_headers)
  end

  defp prefixed_values(labels, prefix) do
    labels
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Map.new(fn {k, v} -> {String.replace_prefix(k, prefix, ""), v} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
