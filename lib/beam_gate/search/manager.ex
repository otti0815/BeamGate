defmodule BeamGate.Search.Manager do
  @moduledoc false
  use GenServer

  alias BeamGate.Search.Index

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def create_index(index, config), do: GenServer.call(__MODULE__, {:create_index, index, config})
  def delete_index(index), do: GenServer.call(__MODULE__, {:delete_index, index})
  def get_index(index), do: GenServer.call(__MODULE__, {:get_index, index})
  def list_indexes, do: GenServer.call(__MODULE__, :list_indexes)

  def index_document(index, id, document, opts),
    do: GenServer.call(__MODULE__, {:index_document, index, id, document, opts}, 60_000)

  def get_document(index, id), do: GenServer.call(__MODULE__, {:get_document, index, id})

  def delete_document(index, id, opts),
    do: GenServer.call(__MODULE__, {:delete_document, index, id, opts}, 60_000)

  def bulk(index, operations), do: GenServer.call(__MODULE__, {:bulk, index, operations}, 60_000)
  def search(index, query), do: GenServer.call(__MODULE__, {:search, index, query}, 60_000)
  def refresh(index), do: GenServer.call(__MODULE__, {:refresh, index})

  @impl true
  def init(_) do
    {:ok, %{indexes: %{}}}
  end

  @impl true
  def handle_call(:list_indexes, _from, state) do
    indexes = state.indexes |> Map.keys() |> Enum.sort()
    {:reply, {:ok, indexes}, state}
  end

  def handle_call({:create_index, index, config}, _from, state) do
    if Map.has_key?(state.indexes, index) do
      {:reply, {:error, :index_already_exists}, state}
    else
      spec =
        normalize_index_config(index, config)
        |> Index.child_spec()
        |> Map.put(:restart, :transient)

      case DynamicSupervisor.start_child(BeamGate.Search.IndexSupervisor, spec) do
        {:ok, pid} ->
          metadata = %{pid: pid, created_at: DateTime.utc_now()}
          {:reply, {:ok, :created}, %{state | indexes: Map.put(state.indexes, index, metadata)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:delete_index, index}, _from, state) do
    case Map.fetch(state.indexes, index) do
      {:ok, %{pid: pid}} ->
        _ = DynamicSupervisor.terminate_child(BeamGate.Search.IndexSupervisor, pid)
        {:reply, {:ok, :deleted}, %{state | indexes: Map.delete(state.indexes, index)}}

      :error ->
        {:reply, {:error, :index_not_found}, state}
    end
  end

  def handle_call({:get_index, index}, _from, state) do
    with {:ok, %{pid: pid}} <- Map.fetch(state.indexes, index),
         {:ok, metadata} <- GenServer.call(pid, :metadata) do
      {:reply, {:ok, metadata}, state}
    else
      :error -> {:reply, {:error, :index_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:index_document, index, id, document, opts}, _from, state) do
    {:reply,
     with_index(state, index, &GenServer.call(&1, {:index_document, id, document, opts}, 60_000)),
     state}
  end

  def handle_call({:get_document, index, id}, _from, state) do
    {:reply, with_index(state, index, &GenServer.call(&1, {:get_document, id})), state}
  end

  def handle_call({:delete_document, index, id, opts}, _from, state) do
    {:reply, with_index(state, index, &GenServer.call(&1, {:delete_document, id, opts}, 60_000)),
     state}
  end

  def handle_call({:bulk, index, operations}, _from, state) do
    {:reply, with_index(state, index, &GenServer.call(&1, {:bulk, operations}, 60_000)), state}
  end

  def handle_call({:search, index, query}, _from, state) do
    {:reply, with_index(state, index, &GenServer.call(&1, {:search, query}, 60_000)), state}
  end

  def handle_call({:refresh, index}, _from, state) do
    {:reply, with_index(state, index, &GenServer.call(&1, :refresh)), state}
  end

  defp with_index(state, index, fun) do
    case Map.fetch(state.indexes, index) do
      {:ok, %{pid: pid}} ->
        if Process.alive?(pid) do
          fun.(pid)
        else
          {:error, :index_unavailable}
        end

      :error ->
        {:error, :index_not_found}
    end
  end

  defp normalize_index_config(index, config) do
    settings = Map.get(config, "settings", %{})

    shard_count =
      settings
      |> Map.get("number_of_shards", 1)
      |> normalize_positive_integer(1)

    replica_count =
      settings
      |> Map.get("number_of_replicas", 0)
      |> normalize_positive_integer(0)

    mappings =
      config
      |> Map.get("mappings", %{})
      |> normalize_mappings()

    analysis = normalize_analysis(Map.get(config, "analysis", %{}))

    %{
      "index" => index,
      "settings" =>
        settings
        |> Map.put("number_of_shards", shard_count)
        |> Map.put("number_of_replicas", replica_count),
      "mappings" => mappings,
      "analysis" => analysis
    }
  end

  defp normalize_mappings(%{"properties" => properties}) when is_map(properties), do: properties
  defp normalize_mappings(properties) when is_map(properties), do: properties
  defp normalize_mappings(_), do: %{}

  defp normalize_analysis(analysis) when is_map(analysis) do
    analysis
    |> Map.put_new("analyzer", %{})
    |> Map.put_new("filter", %{})
  end

  defp normalize_analysis(_), do: %{"analyzer" => %{}, "filter" => %{}}

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> fallback
    end
  end

  defp normalize_positive_integer(_, fallback), do: fallback
end
