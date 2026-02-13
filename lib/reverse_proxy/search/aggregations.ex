defmodule ReverseProxy.Search.Aggregations do
  @moduledoc false

  def compute(aggs, hits) when is_map(aggs) do
    Enum.reduce(aggs, %{}, fn {name, spec}, acc ->
      Map.put(acc, name, compute_single(spec, hits))
    end)
  end

  def compute(_, _), do: %{}

  defp compute_single(%{"terms" => %{"field" => field} = config}, hits) do
    size = normalize_integer(Map.get(config, "size", 10), 10)

    buckets =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {key, count} -> {-count, to_string(key)} end)
      |> Enum.take(size)
      |> Enum.map(fn {key, count} -> %{"key" => key, "doc_count" => count} end)

    %{"buckets" => buckets}
  end

  defp compute_single(%{"range" => %{"field" => field, "ranges" => ranges}}, hits)
       when is_list(ranges) do
    buckets =
      Enum.map(ranges, fn range ->
        from = Map.get(range, "from")
        to = Map.get(range, "to")
        key = Map.get(range, "key", "#{format_bound(from)}-#{format_bound(to)}")

        count =
          hits
          |> Enum.count(fn hit ->
            read_field(hit, field)
            |> in_range?(from, to)
          end)

        %{"key" => key, "from" => from, "to" => to, "doc_count" => count}
      end)

    %{"buckets" => buckets}
  end

  defp compute_single(%{"histogram" => %{"field" => field, "interval" => interval}}, hits) do
    normalized_interval = normalize_number(interval, 1)

    buckets =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_number/1)
      |> Enum.map(fn value ->
        floor(value / normalized_interval) * normalized_interval
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {key, _count} -> key end)
      |> Enum.map(fn {key, count} -> %{"key" => key, "doc_count" => count} end)

    %{"buckets" => buckets}
  end

  defp compute_single(%{"date_histogram" => %{"field" => field} = config}, hits) do
    interval = Map.get(config, "calendar_interval", Map.get(config, "fixed_interval", "day"))
    bucket_ms = date_interval_ms(interval)

    buckets =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_integer/1)
      |> Enum.map(fn value -> floor(value / bucket_ms) * bucket_ms end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {key, _count} -> key end)
      |> Enum.map(fn {key, count} ->
        %{
          "key" => key,
          "key_as_string" =>
            key
            |> DateTime.from_unix!(:millisecond)
            |> DateTime.to_iso8601(),
          "doc_count" => count
        }
      end)

    %{"buckets" => buckets}
  end

  defp compute_single(%{"count" => %{"field" => field}}, hits) do
    count =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.reject(&is_nil/1)
      |> length()

    %{"value" => count}
  end

  defp compute_single(%{"sum" => %{"field" => field}}, hits) do
    value =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_number/1)
      |> Enum.sum()

    %{"value" => value}
  end

  defp compute_single(%{"avg" => %{"field" => field}}, hits) do
    values =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_number/1)

    %{"value" => if(values == [], do: nil, else: Enum.sum(values) / length(values))}
  end

  defp compute_single(%{"min" => %{"field" => field}}, hits) do
    values =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_number/1)

    %{"value" => if(values == [], do: nil, else: Enum.min(values))}
  end

  defp compute_single(%{"max" => %{"field" => field}}, hits) do
    values =
      hits
      |> Enum.flat_map(fn hit -> to_list(read_field(hit, field)) end)
      |> Enum.filter(&is_number/1)

    %{"value" => if(values == [], do: nil, else: Enum.max(values))}
  end

  defp compute_single(_unknown, _hits), do: %{}

  defp read_field(hit, field) do
    case get_in(hit, [:values, field]) do
      nil -> get_in(hit, [:source, field])
      value -> value
    end
  end

  defp in_range?(values, from, to) when is_list(values),
    do: Enum.any?(values, &in_range?(&1, from, to))

  defp in_range?(nil, _from, _to), do: false

  defp in_range?(value, from, to) do
    lower_ok = is_nil(from) or value >= from
    upper_ok = is_nil(to) or value < to
    lower_ok and upper_ok
  rescue
    _ -> false
  end

  defp format_bound(nil), do: "*"
  defp format_bound(value), do: to_string(value)

  defp to_list(value) when is_list(value), do: value
  defp to_list(nil), do: []
  defp to_list(value), do: [value]

  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_integer(_, fallback), do: fallback

  defp normalize_number(value, _fallback) when is_integer(value), do: value
  defp normalize_number(value, _fallback) when is_float(value), do: value

  defp normalize_number(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_number(_, fallback), do: fallback

  defp date_interval_ms(interval) when is_integer(interval) and interval > 0, do: interval

  defp date_interval_ms(interval) when is_binary(interval) do
    case String.downcase(interval) do
      "hour" -> 3_600_000
      "1h" -> 3_600_000
      "day" -> 86_400_000
      "1d" -> 86_400_000
      "week" -> 604_800_000
      "1w" -> 604_800_000
      "month" -> 2_592_000_000
      _ -> 86_400_000
    end
  end

  defp date_interval_ms(_), do: 86_400_000
end
