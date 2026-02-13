defmodule ReverseProxy.Search.QueryCoordinator do
  @moduledoc false
  use GenServer

  alias ReverseProxy.Search.Aggregations

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def search(shards, query, mappings, analysis) do
    GenServer.call(__MODULE__, {:search, shards, query, mappings, analysis}, 60_000)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:search, shards, query, mappings, analysis}, _from, state) do
    started_at = System.monotonic_time(:millisecond)

    shard_hits =
      shards
      |> Task.async_stream(
        fn shard ->
          case GenServer.call(shard, {:search, query, mappings, analysis}, 30_000) do
            {:ok, response} -> response.hits
            {:error, _} -> []
          end
        end,
        timeout: 35_000,
        ordered: false,
        max_concurrency: max(length(shards), 1),
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, hits} -> hits
        {:exit, _} -> []
      end)

    sort_specs = parse_sort(Map.get(query, "sort", []))
    ordered_hits = sort_hits(shard_hits, sort_specs)

    total = length(ordered_hits)

    ordered_hits = apply_search_after(ordered_hits, Map.get(query, "search_after"), sort_specs)
    from = normalize_integer(Map.get(query, "from", 0), 0)
    size = normalize_integer(Map.get(query, "size", 10), 10)

    paged_hits =
      ordered_hits
      |> Enum.drop(max(from, 0))
      |> Enum.take(max(size, 0))

    aggregations =
      case Map.get(query, "aggs", Map.get(query, "aggregations", %{})) do
        aggs when is_map(aggs) and map_size(aggs) > 0 -> Aggregations.compute(aggs, ordered_hits)
        _ -> nil
      end

    took = System.monotonic_time(:millisecond) - started_at

    response =
      %{
        "took" => took,
        "timed_out" => false,
        "hits" => %{
          "total" => %{"value" => total, "relation" => "eq"},
          "hits" => Enum.map(paged_hits, &format_hit(&1, sort_specs))
        }
      }
      |> maybe_put_aggregations(aggregations)

    {:reply, {:ok, response}, state}
  end

  defp maybe_put_aggregations(payload, nil), do: payload
  defp maybe_put_aggregations(payload, aggs), do: Map.put(payload, "aggregations", aggs)

  defp format_hit(hit, sort_specs) do
    %{
      "_id" => hit.id,
      "_score" => hit.score,
      "_source" => hit.source,
      "sort" => sort_values(hit, sort_specs)
    }
  end

  defp parse_sort([]), do: [{"_score", :desc}, {"_id", :asc}]

  defp parse_sort(sort) when is_list(sort) do
    parsed =
      sort
      |> Enum.flat_map(fn entry ->
        case entry do
          %{} = map when map_size(map) > 0 ->
            [{field, dir}] = Map.to_list(map)
            [{field, parse_direction(dir)}]

          field when is_binary(field) ->
            [{field, :asc}]

          _ ->
            []
        end
      end)

    if parsed == [], do: [{"_score", :desc}, {"_id", :asc}], else: parsed
  end

  defp parse_sort(_), do: [{"_score", :desc}, {"_id", :asc}]

  defp parse_direction(direction) when direction in [:asc, "asc", "ASC"], do: :asc
  defp parse_direction(_), do: :desc

  defp sort_hits(hits, sort_specs) do
    Enum.sort(hits, fn left, right ->
      compare_hit(left, right, sort_specs) == :lt
    end)
  end

  defp compare_hit(left, right, sort_specs) do
    left_values = sort_values(left, sort_specs)
    right_values = sort_values(right, sort_specs)
    compare_sort_values(left_values, right_values, sort_specs)
  end

  defp compare_sort_values([], [], _specs), do: :eq

  defp compare_sort_values([left | left_tail], [right | right_tail], [{_field, dir} | dir_tail]) do
    cmp = compare_scalar(left, right)

    adjusted =
      case dir do
        :asc -> cmp
        :desc -> invert_cmp(cmp)
      end

    case adjusted do
      :eq -> compare_sort_values(left_tail, right_tail, dir_tail)
      _ -> adjusted
    end
  end

  defp compare_sort_values(_left, _right, _specs), do: :eq

  defp compare_scalar(nil, nil), do: :eq
  defp compare_scalar(nil, _), do: :gt
  defp compare_scalar(_, nil), do: :lt

  defp compare_scalar(left, right) when is_number(left) and is_number(right) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp compare_scalar(left, right) when is_boolean(left) and is_boolean(right) do
    compare_scalar(to_string(left), to_string(right))
  end

  defp compare_scalar(left, right) do
    left = to_string(left)
    right = to_string(right)

    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp invert_cmp(:lt), do: :gt
  defp invert_cmp(:gt), do: :lt
  defp invert_cmp(:eq), do: :eq

  defp sort_values(hit, sort_specs) do
    Enum.map(sort_specs, fn {field, _dir} ->
      case field do
        "_score" -> hit.score
        "_id" -> hit.id
        other -> Map.get(hit.values, other, Map.get(hit.source, other))
      end
    end)
  end

  defp apply_search_after(hits, search_after, _sort_specs) when not is_list(search_after),
    do: hits

  defp apply_search_after(hits, search_after, sort_specs) do
    Enum.drop_while(hits, fn hit ->
      hit_values = sort_values(hit, sort_specs)
      compare_sort_values(hit_values, search_after, sort_specs) != :gt
    end)
  end

  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_integer(_, fallback), do: fallback
end
