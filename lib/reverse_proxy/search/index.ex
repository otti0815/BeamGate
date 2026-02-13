defmodule ReverseProxy.Search.Index do
  @moduledoc false
  use GenServer

  alias ReverseProxy.Search.QueryCoordinator
  alias ReverseProxy.Search.Shard

  def start_link(config) do
    index = Map.fetch!(config, "index")
    GenServer.start_link(__MODULE__, config, name: via(index))
  end

  def child_spec(config) do
    index = Map.fetch!(config, "index")

    %{
      id: {:search_index, index},
      start: {__MODULE__, :start_link, [config]},
      type: :worker
    }
  end

  @impl true
  def init(config) do
    index = Map.fetch!(config, "index")
    settings = Map.fetch!(config, "settings")
    mappings = Map.fetch!(config, "mappings")
    analysis = Map.fetch!(config, "analysis")

    shard_count = settings["number_of_shards"]
    replica_count = settings["number_of_replicas"]

    with {:ok, primaries, replicas} <-
           start_shards(index, shard_count, replica_count, mappings, analysis) do
      {:ok,
       %{
         index: index,
         settings: settings,
         mappings: mappings,
         analysis: analysis,
         shard_count: shard_count,
         replica_count: replica_count,
         primaries: primaries,
         replicas: replicas,
         seq_no: 0,
         primary_term: 1
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    for pid <- Map.values(state.primaries) do
      _ = DynamicSupervisor.terminate_child(ReverseProxy.Search.ShardSupervisor, pid)
    end

    for replica_pids <- Map.values(state.replicas), pid <- replica_pids do
      _ = DynamicSupervisor.terminate_child(ReverseProxy.Search.ShardSupervisor, pid)
    end

    :ok
  end

  @impl true
  def handle_call(:metadata, _from, state) do
    {:reply,
     {:ok,
      %{
        index: state.index,
        settings: state.settings,
        mappings: state.mappings,
        analysis: state.analysis,
        shards: state.shard_count,
        replicas: state.replica_count
      }}, state}
  end

  def handle_call({:index_document, id, document, _opts}, _from, state) do
    shard_id = shard_for_id(id, state.shard_count)
    primary_pid = Map.fetch!(state.primaries, shard_id)
    seq_no = state.seq_no + 1

    with {:ok, metadata} <-
           GenServer.call(primary_pid, {:index, id, document, seq_no, state.primary_term}, 30_000),
         :ok <- replicate_index(shard_id, id, document, seq_no, state.primary_term, state) do
      result = if metadata.version == 1, do: "created", else: "updated"
      {:reply, {:ok, Map.put(metadata, :result, result)}, %{state | seq_no: seq_no}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_document, id}, _from, state) do
    shard_id = shard_for_id(id, state.shard_count)
    primary_pid = Map.fetch!(state.primaries, shard_id)

    {:reply, GenServer.call(primary_pid, {:get_document, id}), state}
  end

  def handle_call({:delete_document, id, _opts}, _from, state) do
    shard_id = shard_for_id(id, state.shard_count)
    primary_pid = Map.fetch!(state.primaries, shard_id)
    seq_no = state.seq_no + 1

    with {:ok, metadata} <-
           GenServer.call(primary_pid, {:delete, id, seq_no, state.primary_term}, 30_000),
         :ok <- replicate_delete(shard_id, id, seq_no, state.primary_term, state) do
      {:reply, {:ok, metadata}, %{state | seq_no: seq_no}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bulk, operations}, _from, state) do
    {items, new_state} =
      Enum.reduce(operations, {[], state}, fn op, {acc, acc_state} ->
        {result, next_state} = run_bulk_item(op, acc_state)
        {[result | acc], next_state}
      end)

    has_errors =
      Enum.any?(items, fn item ->
        case Map.to_list(item) do
          [{_, payload}] when is_map(payload) -> Map.has_key?(payload, "error")
          _ -> Map.has_key?(item, "error")
        end
      end)

    {:reply,
     {:ok,
      %{
        "items" => Enum.reverse(items),
        "errors" => has_errors
      }}, new_state}
  end

  def handle_call({:search, query}, _from, state) do
    shards = Map.values(state.primaries)

    case QueryCoordinator.search(shards, query, state.mappings, state.analysis) do
      {:ok, response} -> {:reply, {:ok, response}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:refresh, _from, state) do
    Enum.each(Map.values(state.primaries), &GenServer.call(&1, :refresh))
    {:reply, {:ok, :refreshed}, state}
  end

  defp run_bulk_item(%{"index" => payload}, state), do: run_bulk_upsert("index", payload, state)
  defp run_bulk_item(%{"create" => payload}, state), do: run_bulk_upsert("create", payload, state)
  defp run_bulk_item(%{"update" => payload}, state), do: run_bulk_upsert("update", payload, state)

  defp run_bulk_item(%{"delete" => payload}, state) do
    id = Map.get(payload, "_id") || Map.get(payload, "id")

    if is_binary(id) do
      case do_delete_document(state, id) do
        {{:ok, metadata}, next_state} ->
          {%{
             "delete" => %{
               "_id" => id,
               "result" => metadata.result,
               "_version" => metadata.version
             }
           }, next_state}

        {{:error, reason}, next_state} ->
          {%{"delete" => %{"_id" => id, "error" => inspect(reason)}}, next_state}
      end
    else
      {%{"delete" => %{"error" => "missing _id"}}, state}
    end
  end

  defp run_bulk_item(_unknown, state), do: {%{"error" => "unsupported bulk operation"}, state}

  defp run_bulk_upsert(op_name, payload, state) do
    id = Map.get(payload, "_id") || Map.get(payload, "id")
    document = Map.get(payload, "document") || Map.get(payload, "doc")

    if is_binary(id) and is_map(document) do
      case do_index_document(state, id, document) do
        {{:ok, metadata}, next_state} ->
          result =
            if op_name == "create" and metadata.version > 1, do: "updated", else: metadata.result

          {%{op_name => %{"_id" => id, "result" => result, "_version" => metadata.version}},
           next_state}

        {{:error, reason}, next_state} ->
          {%{op_name => %{"_id" => id, "error" => inspect(reason)}}, next_state}
      end
    else
      {%{op_name => %{"error" => "missing _id or document"}}, state}
    end
  end

  defp do_index_document(state, id, document) do
    shard_id = shard_for_id(id, state.shard_count)
    primary_pid = Map.fetch!(state.primaries, shard_id)
    seq_no = state.seq_no + 1

    result =
      with {:ok, metadata} <-
             GenServer.call(
               primary_pid,
               {:index, id, document, seq_no, state.primary_term},
               30_000
             ),
           :ok <- replicate_index(shard_id, id, document, seq_no, state.primary_term, state) do
        result = if metadata.version == 1, do: "created", else: "updated"
        {:ok, Map.put(metadata, :result, result)}
      end

    {result, %{state | seq_no: seq_no}}
  end

  defp do_delete_document(state, id) do
    shard_id = shard_for_id(id, state.shard_count)
    primary_pid = Map.fetch!(state.primaries, shard_id)
    seq_no = state.seq_no + 1

    result =
      with {:ok, metadata} <-
             GenServer.call(primary_pid, {:delete, id, seq_no, state.primary_term}, 30_000),
           :ok <- replicate_delete(shard_id, id, seq_no, state.primary_term, state) do
        {:ok, metadata}
      end

    {result, %{state | seq_no: seq_no}}
  end

  defp replicate_index(shard_id, id, document, seq_no, primary_term, state) do
    state.replicas
    |> Map.get(shard_id, [])
    |> Enum.reduce_while(:ok, fn pid, _acc ->
      case GenServer.call(pid, {:index, id, document, seq_no, primary_term}, 30_000) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:replication_failed, reason}}}
      end
    end)
  end

  defp replicate_delete(shard_id, id, seq_no, primary_term, state) do
    state.replicas
    |> Map.get(shard_id, [])
    |> Enum.reduce_while(:ok, fn pid, _acc ->
      case GenServer.call(pid, {:delete, id, seq_no, primary_term}, 30_000) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:replication_failed, reason}}}
      end
    end)
  end

  defp start_shards(index, shard_count, replica_count, mappings, analysis) do
    shard_ids = Enum.to_list(0..(shard_count - 1))

    with {:ok, primaries} <- start_primary_shards(index, shard_ids, mappings, analysis),
         {:ok, replicas} <-
           start_replica_shards(index, shard_ids, replica_count, mappings, analysis) do
      {:ok, primaries, replicas}
    end
  end

  defp start_primary_shards(index, shard_ids, mappings, analysis) do
    Enum.reduce_while(shard_ids, {:ok, %{}}, fn shard_id, {:ok, acc} ->
      spec =
        Shard.child_spec(%{
          index: index,
          shard_id: shard_id,
          replica_id: nil,
          role: :primary,
          mappings: mappings,
          analysis: analysis
        })

      case DynamicSupervisor.start_child(ReverseProxy.Search.ShardSupervisor, spec) do
        {:ok, pid} -> {:cont, {:ok, Map.put(acc, shard_id, pid)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_replica_shards(index, shard_ids, replica_count, mappings, analysis) do
    Enum.reduce_while(shard_ids, {:ok, %{}}, fn shard_id, {:ok, acc} ->
      case start_replicas_for_shard(index, shard_id, replica_count, mappings, analysis) do
        {:ok, replica_pids} -> {:cont, {:ok, Map.put(acc, shard_id, replica_pids)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_replicas_for_shard(_index, _shard_id, replica_count, _mappings, _analysis)
       when replica_count <= 0,
       do: {:ok, []}

  defp start_replicas_for_shard(index, shard_id, replica_count, mappings, analysis) do
    Enum.reduce_while(1..replica_count, {:ok, []}, fn replica_id, {:ok, acc} ->
      spec =
        Shard.child_spec(%{
          index: index,
          shard_id: shard_id,
          replica_id: replica_id,
          role: :replica,
          mappings: mappings,
          analysis: analysis
        })

      case DynamicSupervisor.start_child(ReverseProxy.Search.ShardSupervisor, spec) do
        {:ok, pid} -> {:cont, {:ok, [pid | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pids} -> {:ok, Enum.reverse(pids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shard_for_id(id, shard_count), do: :erlang.phash2(id, shard_count)

  defp via(index), do: {:global, {:search_index, index}}
end
