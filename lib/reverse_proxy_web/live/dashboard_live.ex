defmodule ReverseProxyWeb.DashboardLive do
  use ReverseProxyWeb, :live_view

  alias ReverseProxy.ControlPlane

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_state(socket)}
  end

  @impl true
  def handle_event("refresh_discovery", _params, socket) do
    ReverseProxy.Discovery.DockerWatcher.refresh_now()
    {:noreply, put_flash(load_state(socket), :info, "Discovery refresh requested")}
  end

  def handle_event("create_route", params, socket) do
    service_id = "manual-service:" <> unique_id()
    router_id = "manual-router:" <> unique_id()
    endpoint_id = "manual-endpoint:" <> unique_id()

    middleware =
      %{}
      |> maybe_put_basic_auth(params)

    with {:ok, _service} <-
           ControlPlane.put_service(%{
             id: service_id,
             name: Map.get(params, "service_name", "manual-service"),
             load_balancer_strategy: :round_robin,
             metadata: %{source: :manual}
           }),
         {:ok, _router} <-
           ControlPlane.put_router(%{
             id: router_id,
             service_id: service_id,
             host: blank_to_nil(params["host"]),
             path_prefix: normalize_path_prefix(params["path_prefix"] || "/"),
             tls_enabled: truthy?(params["tls_enabled"]),
             source: :manual,
             middleware: middleware
           }),
         {:ok, _endpoint} <-
           ControlPlane.put_endpoint(%{
             id: endpoint_id,
             service_id: service_id,
             host: Map.get(params, "endpoint_host", "127.0.0.1"),
             port: parse_int(Map.get(params, "endpoint_port", "4000"), 4000),
             health_status: :unknown,
             metadata: %{source: :manual}
           }) do
      {:noreply, put_flash(load_state(socket), :info, "Route created")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to create route")}
    end
  end

  def handle_event("delete_route", %{"id" => router_id}, socket) do
    case ControlPlane.get_router(router_id) do
      nil ->
        {:noreply, load_state(socket)}

      route ->
        ControlPlane.delete_endpoints_for_service(route.service_id)
        ControlPlane.delete_router(route.id)
        ControlPlane.delete_service(route.service_id)
        {:noreply, put_flash(load_state(socket), :info, "Route removed")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="card">
      <h1>Reverse Proxy Dashboard</h1>
      <p class="muted">Dynamic routes, upstreams, and health state.</p>
      <p>
        <button phx-click="refresh_discovery">Refresh Docker Discovery</button>
        <a href="/metrics" target="_blank">Metrics</a>
        <a href="/admin/logout">Sign out</a>
      </p>
    </section>

    <section class="card">
      <h2>Counters</h2>
      <p>Routes: <%= @counters.routes %> | Services: <%= @counters.services %> | Endpoints: <%= @counters.endpoints %></p>
      <p>Requests: <%= @counters.requests %> | Endpoints Up: <%= @counters.up %> | Down: <%= @counters.down %></p>
    </section>

    <section class="card">
      <h2>Create Manual Route</h2>
      <form phx-submit="create_route">
        <input name="service_name" placeholder="service name" />
        <input name="host" placeholder="host (optional)" />
        <input name="path_prefix" placeholder="/api" value="/" />
        <input name="endpoint_host" placeholder="endpoint host" value="127.0.0.1" />
        <input name="endpoint_port" placeholder="endpoint port" value="4000" />
        <label><input type="checkbox" name="tls_enabled" /> TLS route only</label>
        <br/><br/>
        <input name="basic_auth_user" placeholder="basic auth user (optional)" />
        <input name="basic_auth_pass" placeholder="basic auth pass (optional)" />
        <br/><br/>
        <button type="submit">Add Route</button>
      </form>
    </section>

    <section class="card">
      <h2>Routers</h2>
      <table>
        <thead>
          <tr>
            <th>ID</th><th>Source</th><th>Host</th><th>Path</th><th>Service</th><th>TLS</th><th></th>
          </tr>
        </thead>
        <tbody>
          <%= for r <- @routers do %>
            <tr>
              <td><%= r.id %></td>
              <td><%= r.source %></td>
              <td><%= r.host || "*" %></td>
              <td><%= r.path_prefix %></td>
              <td><%= r.service_id %></td>
              <td><%= r.tls_enabled %></td>
              <td>
                <button phx-click="delete_route" phx-value-id={r.id}>Delete</button>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>

    <section class="card">
      <h2>Endpoints</h2>
      <table>
        <thead>
          <tr>
            <th>ID</th><th>Service</th><th>Host</th><th>Port</th><th>Health</th>
          </tr>
        </thead>
        <tbody>
          <%= for e <- @endpoints do %>
            <tr>
              <td><%= e.id %></td>
              <td><%= e.service_id %></td>
              <td><%= e.host %></td>
              <td><%= e.port %></td>
              <td><%= e.health_status %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>
    """
  end

  defp load_state(socket) do
    routes = ControlPlane.list_routers()
    services = ControlPlane.list_services()
    endpoints = ControlPlane.list_endpoints()
    metrics = ControlPlane.metrics()

    assign(socket,
      routers: routes,
      services: services,
      endpoints: endpoints,
      counters: %{
        routes: length(routes),
        services: length(services),
        endpoints: length(endpoints),
        requests: Map.get(metrics, :proxy_requests_total, 0),
        up: Enum.count(endpoints, &(&1.health_status == :up)),
        down: Enum.count(endpoints, &(&1.health_status == :down))
      }
    )
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp parse_int(value, fallback) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_path_prefix(nil), do: "/"
  defp normalize_path_prefix(""), do: "/"

  defp normalize_path_prefix(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(val), do: val in ["true", "on", true, 1, "1"]

  defp maybe_put_basic_auth(map, %{"basic_auth_user" => u, "basic_auth_pass" => p}) do
    if u in [nil, ""] or p in [nil, ""] do
      map
    else
      Map.put(map, :basic_auth, %{username: u, password: p})
    end
  end

  defp maybe_put_basic_auth(map, _), do: map
end
