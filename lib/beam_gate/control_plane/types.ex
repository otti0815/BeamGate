defmodule BeamGate.ControlPlane.Router do
  @enforce_keys [:id, :service_id]
  defstruct [
    :id,
    :host,
    :service_id,
    tls_enabled: false,
    source: :manual,
    path_prefix: "/",
    middleware: %{}
  ]
end

defmodule BeamGate.ControlPlane.Service do
  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    load_balancer_strategy: :round_robin,
    metadata: %{}
  ]
end

defmodule BeamGate.ControlPlane.Endpoint do
  @enforce_keys [:id, :service_id, :host, :port]
  defstruct [
    :id,
    :service_id,
    :host,
    :port,
    health_status: :unknown,
    health_path: "/health",
    metadata: %{}
  ]
end
