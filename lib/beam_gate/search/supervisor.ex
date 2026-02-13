defmodule BeamGate.Search.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: BeamGate.Search.IndexSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: BeamGate.Search.ShardSupervisor},
      BeamGate.Search.QueryCoordinator,
      BeamGate.Search.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
