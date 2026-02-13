defmodule BeamGate.Search.Shard do
  @moduledoc false
  use GenServer

  alias BeamGate.Search.Analyzer
  alias BeamGate.Search.Query

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    shard_id = Map.fetch!(opts, :shard_id)
    replica_id = Map.get(opts, :replica_id)
    index = Map.fetch!(opts, :index)

    %{
      id: {:search_shard, index, shard_id, replica_id || :primary},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       index: Map.fetch!(opts, :index),
       shard_id: Map.fetch!(opts, :shard_id),
       replica_id: Map.get(opts, :replica_id),
       role: Map.fetch!(opts, :role),
       mappings: Map.get(opts, :mappings, %{}),
       analysis: Map.get(opts, :analysis, %{"analyzer" => %{}, "filter" => %{}}),
       docs: %{},
       inverted: %{},
       live_docs: 0,
       field_lengths_total: %{},
       field_doc_count: %{}
     }}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, state}

  def handle_call({:get_document, id}, _from, state) do
    reply =
      case Map.get(state.docs, id) do
        nil ->
          {:error, :not_found}

        %{deleted: true} ->
          {:error, :not_found}

        doc ->
          {:ok,
           %{
             id: id,
             source: doc.source,
             version: doc.version,
             seq_no: doc.seq_no,
             primary_term: doc.primary_term
           }}
      end

    {:reply, reply, state}
  end

  def handle_call({:index, id, source, seq_no, primary_term}, _from, state) do
    {next_state, metadata} = put_document(state, id, source, seq_no, primary_term)
    {:reply, {:ok, metadata}, next_state}
  rescue
    e -> {:reply, {:error, {:index_failed, Exception.message(e)}}, state}
  end

  def handle_call({:delete, id, seq_no, primary_term}, _from, state) do
    {next_state, metadata} = delete_document(state, id, seq_no, primary_term)
    {:reply, {:ok, metadata}, next_state}
  rescue
    e -> {:reply, {:error, {:delete_failed, Exception.message(e)}}, state}
  end

  def handle_call({:search, body, mappings, analysis}, _from, state) do
    effective_state = %{state | mappings: mappings, analysis: analysis}
    {:reply, {:ok, Query.execute(effective_state, body)}, state}
  end

  defp put_document(state, id, source, seq_no, primary_term) do
    old_doc = Map.get(state.docs, id)

    state =
      case old_doc do
        %{deleted: false} = doc -> remove_live_doc(state, id, doc)
        _ -> state
      end

    {doc_entry, mappings} = build_doc_entry(state, old_doc, source, seq_no, primary_term)

    state =
      state
      |> add_live_doc(id, doc_entry)
      |> Map.put(:mappings, mappings)

    metadata = %{
      id: id,
      version: doc_entry.version,
      seq_no: doc_entry.seq_no,
      primary_term: doc_entry.primary_term,
      shard: state.shard_id
    }

    {state, metadata}
  end

  defp delete_document(state, id, seq_no, primary_term) do
    old_doc = Map.get(state.docs, id)

    {state, version, result} =
      case old_doc do
        nil ->
          {state, 1, "not_found"}

        %{deleted: true} = doc ->
          {state, doc.version + 1, "not_found"}

        %{deleted: false} = doc ->
          {remove_live_doc(state, id, doc), doc.version + 1, "deleted"}
      end

    tombstone = %{
      source: nil,
      version: version,
      seq_no: seq_no,
      primary_term: primary_term,
      deleted: true,
      tokens: %{},
      values: %{}
    }

    state = %{state | docs: Map.put(state.docs, id, tombstone)}

    metadata = %{
      id: id,
      version: version,
      seq_no: seq_no,
      primary_term: primary_term,
      shard: state.shard_id,
      result: result
    }

    {state, metadata}
  end

  defp build_doc_entry(state, old_doc, source, seq_no, primary_term) do
    version =
      case old_doc do
        nil -> 1
        doc -> doc.version + 1
      end

    {tokens, values, mappings} = analyze_source(source, state.mappings, state.analysis)

    doc_entry = %{
      source: source,
      version: version,
      seq_no: seq_no,
      primary_term: primary_term,
      deleted: false,
      tokens: tokens,
      values: values
    }

    {doc_entry, mappings}
  end

  defp analyze_source(source, mappings, analysis) do
    Enum.reduce(source, {%{}, %{}, mappings}, fn {field, value},
                                                 {token_acc, value_acc, mapping_acc} ->
      mapping = Map.get(mapping_acc, field, infer_mapping(value))
      mapping_acc = Map.put_new(mapping_acc, field, mapping)
      type = field_type(mapping)

      case type do
        "text" ->
          tokens = analyze_text_value(value, mapping, analysis)
          {Map.put(token_acc, field, tokens), value_acc, mapping_acc}

        "keyword" ->
          normalized = normalize_keyword_value(value)
          {token_acc, Map.put(value_acc, field, normalized), mapping_acc}

        "integer" ->
          {token_acc, Map.put(value_acc, field, normalize_numeric(value, :integer)), mapping_acc}

        "float" ->
          {token_acc, Map.put(value_acc, field, normalize_numeric(value, :float)), mapping_acc}

        "boolean" ->
          {token_acc, Map.put(value_acc, field, normalize_boolean(value)), mapping_acc}

        "date" ->
          {token_acc, Map.put(value_acc, field, normalize_date(value)), mapping_acc}

        _ ->
          {token_acc, Map.put(value_acc, field, value), mapping_acc}
      end
    end)
  end

  defp analyze_text_value(value, mapping, analysis) when is_list(value) do
    value
    |> Enum.flat_map(&Analyzer.analyze(&1, mapping, analysis, :index))
  end

  defp analyze_text_value(value, mapping, analysis),
    do: Analyzer.analyze(value, mapping, analysis, :index)

  defp add_live_doc(state, id, doc_entry) do
    inverted = add_postings(state.inverted, id, doc_entry.tokens)

    field_lengths_total =
      Enum.reduce(doc_entry.tokens, state.field_lengths_total, fn {field, tokens}, acc ->
        Map.update(acc, field, length(tokens), &(&1 + length(tokens)))
      end)

    field_doc_count =
      Enum.reduce(doc_entry.tokens, state.field_doc_count, fn {field, tokens}, acc ->
        if tokens == [] do
          acc
        else
          Map.update(acc, field, 1, &(&1 + 1))
        end
      end)

    %{
      state
      | inverted: inverted,
        docs: Map.put(state.docs, id, doc_entry),
        live_docs: state.live_docs + 1,
        field_lengths_total: field_lengths_total,
        field_doc_count: field_doc_count
    }
  end

  defp remove_live_doc(state, id, doc_entry) do
    inverted = remove_postings(state.inverted, id, doc_entry.tokens)

    field_lengths_total =
      Enum.reduce(doc_entry.tokens, state.field_lengths_total, fn {field, tokens}, acc ->
        next = Map.get(acc, field, 0) - length(tokens)
        if next <= 0, do: Map.delete(acc, field), else: Map.put(acc, field, next)
      end)

    field_doc_count =
      Enum.reduce(doc_entry.tokens, state.field_doc_count, fn {field, tokens}, acc ->
        if tokens == [] do
          acc
        else
          next = Map.get(acc, field, 1) - 1
          if next <= 0, do: Map.delete(acc, field), else: Map.put(acc, field, next)
        end
      end)

    %{
      state
      | inverted: inverted,
        live_docs: max(state.live_docs - 1, 0),
        field_lengths_total: field_lengths_total,
        field_doc_count: field_doc_count
    }
  end

  defp add_postings(inverted, doc_id, tokens_by_field) do
    Enum.reduce(tokens_by_field, inverted, fn {field, tokens}, acc ->
      positions = tokens_to_positions(tokens)

      field_index =
        Enum.reduce(positions, Map.get(acc, field, %{}), fn {term, term_positions}, field_acc ->
          term_postings = Map.get(field_acc, term, %{})
          Map.put(field_acc, term, Map.put(term_postings, doc_id, term_positions))
        end)

      Map.put(acc, field, field_index)
    end)
  end

  defp remove_postings(inverted, doc_id, tokens_by_field) do
    Enum.reduce(tokens_by_field, inverted, fn {field, tokens}, acc ->
      positions = tokens_to_positions(tokens)

      field_index =
        Enum.reduce(positions, Map.get(acc, field, %{}), fn {term, _positions}, field_acc ->
          term_postings =
            field_acc
            |> Map.get(term, %{})
            |> Map.delete(doc_id)

          if map_size(term_postings) == 0 do
            Map.delete(field_acc, term)
          else
            Map.put(field_acc, term, term_postings)
          end
        end)

      if map_size(field_index) == 0 do
        Map.delete(acc, field)
      else
        Map.put(acc, field, field_index)
      end
    end)
  end

  defp tokens_to_positions(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {term, pos}, acc ->
      Map.update(acc, term, [pos], &[pos | &1])
    end)
    |> Map.new(fn {term, positions} -> {term, Enum.reverse(positions)} end)
  end

  defp infer_mapping(value) do
    cond do
      is_integer(value) -> %{"type" => "integer"}
      is_float(value) -> %{"type" => "float"}
      is_boolean(value) -> %{"type" => "boolean"}
      is_binary(value) and date_string?(value) -> %{"type" => "date"}
      is_binary(value) -> %{"type" => "text"}
      is_list(value) -> infer_mapping(List.first(value))
      true -> %{"type" => "keyword"}
    end
  end

  defp field_type(mapping), do: Map.get(mapping, "type", "text")

  defp normalize_keyword_value(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_keyword_value(value), do: to_string(value)

  defp normalize_numeric(value, :integer) when is_integer(value), do: value

  defp normalize_numeric(value, :integer) when is_float(value), do: trunc(value)

  defp normalize_numeric(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp normalize_numeric(value, :float) when is_integer(value), do: value * 1.0
  defp normalize_numeric(value, :float) when is_float(value), do: value

  defp normalize_numeric(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp normalize_numeric(_, _), do: nil

  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean(_), do: nil

  defp normalize_date(value) when is_integer(value), do: value

  defp normalize_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        DateTime.to_unix(dt, :millisecond)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} ->
            ndt
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          _ ->
            case Date.from_iso8601(value) do
              {:ok, date} ->
                date
                |> DateTime.new!(~T[00:00:00], "Etc/UTC")
                |> DateTime.to_unix(:millisecond)

              _ ->
                nil
            end
        end
    end
  end

  defp normalize_date(_), do: nil

  defp date_string?(value) when is_binary(value) do
    case normalize_date(value) do
      nil -> false
      _ -> true
    end
  end
end
