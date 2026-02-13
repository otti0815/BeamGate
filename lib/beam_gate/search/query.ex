defmodule BeamGate.Search.Query do
  @moduledoc false

  alias BeamGate.Search.Analyzer

  @k1 1.2
  @b 0.75

  def execute(state, body) do
    query = Map.get(body, "query", %{"match_all" => %{}})
    result = eval(query, state, :score)

    hits =
      result.docs
      |> Enum.map(fn id -> build_hit(state, id, Map.get(result.scores, id, 0.0)) end)
      |> Enum.reject(&is_nil/1)

    %{hits: hits}
  end

  defp build_hit(state, id, score) do
    case Map.get(state.docs, id) do
      nil -> nil
      %{deleted: true} -> nil
      doc -> %{id: id, score: score, source: doc.source, values: doc.values}
    end
  end

  defp eval(query, state, mode) when query == %{}, do: match_all(state, mode)

  defp eval(%{"match_all" => _}, state, mode), do: match_all(state, mode)

  defp eval(%{"term" => term}, state, mode), do: eval_term(term, state, mode)
  defp eval(%{"match" => match}, state, mode), do: eval_match(match, state, mode)
  defp eval(%{"phrase" => phrase}, state, mode), do: eval_phrase(phrase, state, mode)
  defp eval(%{"bool" => bool_query}, state, mode), do: eval_bool(bool_query, state, mode)
  defp eval(%{"fuzzy" => fuzzy_query}, state, mode), do: eval_fuzzy(fuzzy_query, state, mode)
  defp eval(%{"wildcard" => wildcard}, state, mode), do: eval_wildcard(wildcard, state, mode)
  defp eval(%{"range" => range_query}, state, mode), do: eval_range(range_query, state, mode)

  defp eval(_unknown, state, mode), do: match_all(state, mode)

  defp match_all(state, mode) do
    docs = live_doc_ids(state)

    scores =
      if mode == :score do
        Map.new(docs, &{&1, 1.0})
      else
        %{}
      end

    %{docs: MapSet.new(docs), scores: scores}
  end

  defp eval_term(term, state, mode) do
    {field, payload} = extract_field_payload(term)
    value = read_payload_value(payload)
    boost = read_boost(payload)
    mapping = Map.get(state.mappings, field, %{"type" => "text"})
    type = Map.get(mapping, "type", "text")

    result =
      case type do
        "text" ->
          token = value |> to_string() |> String.downcase()
          postings = get_postings(state, field, token)

          scores =
            if mode == :score do
              score_text_postings(postings, state, field, boost)
            else
              %{}
            end

          %{docs: postings |> Map.keys() |> MapSet.new(), scores: scores}

        _ ->
          docs =
            live_doc_ids(state)
            |> Enum.filter(fn id ->
              value_for_doc(state, id, field)
              |> value_equals?(value)
            end)

          scores =
            if mode == :score do
              Map.new(docs, &{&1, 1.0 * boost})
            else
              %{}
            end

          %{docs: MapSet.new(docs), scores: scores}
      end

    result
  end

  defp eval_match(match, state, mode) do
    {field, payload} = extract_field_payload(match)

    {query_text, operator, boost} =
      cond do
        is_binary(payload) ->
          {payload, "or", 1.0}

        is_map(payload) ->
          {Map.get(payload, "query", ""), Map.get(payload, "operator", "or"), read_boost(payload)}

        true ->
          {to_string(payload), "or", 1.0}
      end

    mapping = Map.get(state.mappings, field, %{"type" => "text"})
    tokens = Analyzer.analyze(query_text, mapping, state.analysis, :query)

    if tokens == [] do
      %{docs: MapSet.new(), scores: %{}}
    else
      token_results =
        Enum.map(tokens, fn token ->
          postings = get_postings(state, field, token)

          scores =
            if mode == :score do
              score_text_postings(postings, state, field, 1.0)
            else
              %{}
            end

          %{docs: postings |> Map.keys() |> MapSet.new(), scores: scores}
        end)

      doc_set =
        case String.downcase(to_string(operator)) do
          "and" -> intersect_doc_sets(token_results)
          _ -> union_doc_sets(token_results)
        end

      scores =
        if mode == :score do
          token_results
          |> Enum.reduce(%{}, fn result, acc ->
            Map.merge(acc, result.scores, fn _k, a, b -> a + b end)
          end)
          |> Map.take(MapSet.to_list(doc_set))
          |> multiply_scores(boost)
        else
          %{}
        end

      %{docs: doc_set, scores: scores}
    end
  end

  defp eval_phrase(phrase, state, mode) do
    {field, payload} = extract_field_payload(phrase)

    {query_text, slop, boost} =
      cond do
        is_binary(payload) ->
          {payload, 0, 1.0}

        is_map(payload) ->
          {
            Map.get(payload, "query", ""),
            normalize_integer(Map.get(payload, "slop", 0), 0),
            read_boost(payload)
          }

        true ->
          {to_string(payload), 0, 1.0}
      end

    mapping = Map.get(state.mappings, field, %{"type" => "text"})
    tokens = Analyzer.analyze(query_text, mapping, state.analysis, :query)

    if tokens == [] do
      %{docs: MapSet.new(), scores: %{}}
    else
      docs = phrase_docs(state, field, tokens, slop)

      scores =
        if mode == :score do
          docs
          |> Enum.reduce(%{}, fn id, acc ->
            doc_score =
              Enum.reduce(tokens, 0.0, fn token, score_acc ->
                postings = get_postings(state, field, token)
                positions = Map.get(postings, id, [])
                score_acc + bm25_for_doc(state, field, id, length(positions), map_size(postings))
              end)

            Map.put(acc, id, doc_score * 1.25 * boost)
          end)
        else
          %{}
        end

      %{docs: MapSet.new(docs), scores: scores}
    end
  end

  defp eval_bool(bool_query, state, mode) do
    must = listify(Map.get(bool_query, "must", []))
    should = listify(Map.get(bool_query, "should", []))
    filter = listify(Map.get(bool_query, "filter", []))
    must_not = listify(Map.get(bool_query, "must_not", []))

    min_should =
      normalize_integer(
        Map.get(bool_query, "minimum_should_match", default_min_should(must, filter, should)),
        0
      )

    boost = read_boost(bool_query)

    must_results = Enum.map(must, &eval(&1, state, :score))
    filter_results = Enum.map(filter, &eval(&1, state, :filter))
    should_results = Enum.map(should, &eval(&1, state, :score))
    must_not_results = Enum.map(must_not, &eval(&1, state, :filter))

    all_docs = MapSet.new(live_doc_ids(state))

    must_docs = if must_results == [], do: all_docs, else: intersect_doc_sets(must_results)
    filter_docs = if filter_results == [], do: all_docs, else: intersect_doc_sets(filter_results)
    should_docs = if should_results == [], do: all_docs, else: union_doc_sets(should_results)
    should_gate_docs = if should == [] or min_should <= 0, do: all_docs, else: should_docs

    should_counts =
      Enum.reduce(should_results, %{}, fn result, acc ->
        Enum.reduce(result.docs, acc, fn id, inner ->
          Map.update(inner, id, 1, &(&1 + 1))
        end)
      end)

    must_not_docs =
      Enum.reduce(must_not_results, MapSet.new(), fn result, acc ->
        MapSet.union(acc, result.docs)
      end)

    base_docs =
      must_docs
      |> MapSet.intersection(filter_docs)
      |> MapSet.intersection(should_gate_docs)
      |> MapSet.difference(must_not_docs)

    docs =
      if should == [] or min_should <= 0 do
        base_docs
      else
        base_docs
        |> Enum.filter(fn id -> Map.get(should_counts, id, 0) >= min_should end)
        |> MapSet.new()
      end

    scores =
      if mode == :score do
        must_scores = merge_score_maps(Enum.map(must_results, & &1.scores))
        should_scores = merge_score_maps(Enum.map(should_results, & &1.scores))

        docs
        |> Enum.reduce(%{}, fn id, acc ->
          score = Map.get(must_scores, id, 0.0) + Map.get(should_scores, id, 0.0)
          Map.put(acc, id, score * boost)
        end)
      else
        %{}
      end

    %{docs: docs, scores: scores}
  end

  defp eval_fuzzy(fuzzy_query, state, mode) do
    {field, payload} = extract_field_payload(fuzzy_query)

    {value, fuzziness, boost} =
      cond do
        is_binary(payload) ->
          {payload, 1, 1.0}

        is_map(payload) ->
          {
            Map.get(payload, "value", ""),
            normalize_fuzziness(Map.get(payload, "fuzziness", 1), Map.get(payload, "value", "")),
            read_boost(payload)
          }

        true ->
          {to_string(payload), 1, 1.0}
      end

    term_index = Map.get(state.inverted, field, %{})
    normalized_value = String.downcase(to_string(value))

    {docs, scores} =
      Enum.reduce(term_index, {MapSet.new(), %{}}, fn {term, postings}, {doc_acc, score_acc} ->
        dist = levenshtein(normalized_value, term)

        if dist <= fuzziness do
          match_docs = Map.keys(postings) |> MapSet.new()
          doc_acc = MapSet.union(doc_acc, match_docs)

          score_acc =
            if mode == :score do
              closeness = 1.0 - dist / max(fuzziness, 1)

              postings
              |> Enum.reduce(score_acc, fn {id, positions}, inner ->
                term_score = bm25_for_doc(state, field, id, length(positions), map_size(postings))

                Map.update(
                  inner,
                  id,
                  term_score * max(closeness, 0.1),
                  &(&1 + term_score * max(closeness, 0.1))
                )
              end)
            else
              score_acc
            end

          {doc_acc, score_acc}
        else
          {doc_acc, score_acc}
        end
      end)

    scores = if mode == :score, do: multiply_scores(scores, boost), else: %{}

    %{docs: docs, scores: scores}
  end

  defp eval_wildcard(wildcard_query, state, mode) do
    {field, payload} = extract_field_payload(wildcard_query)

    {pattern, boost} =
      cond do
        is_binary(payload) -> {payload, 1.0}
        is_map(payload) -> {Map.get(payload, "value", ""), read_boost(payload)}
        true -> {to_string(payload), 1.0}
      end

    regex = wildcard_to_regex(pattern)
    term_index = Map.get(state.inverted, field, %{})

    {docs, scores} =
      Enum.reduce(term_index, {MapSet.new(), %{}}, fn {term, postings}, {doc_acc, score_acc} ->
        if Regex.match?(regex, term) do
          doc_acc = MapSet.union(doc_acc, MapSet.new(Map.keys(postings)))

          score_acc =
            if mode == :score do
              Enum.reduce(postings, score_acc, fn {id, positions}, inner ->
                score = bm25_for_doc(state, field, id, length(positions), map_size(postings))
                Map.update(inner, id, score, &(&1 + score))
              end)
            else
              score_acc
            end

          {doc_acc, score_acc}
        else
          {doc_acc, score_acc}
        end
      end)

    scores = if mode == :score, do: multiply_scores(scores, boost), else: %{}
    %{docs: docs, scores: scores}
  end

  defp eval_range(range_query, state, mode) do
    {field, payload} = extract_field_payload(range_query)
    mapping = Map.get(state.mappings, field, %{"type" => "float"})

    from = normalize_bound(Map.get(payload, "gte", Map.get(payload, "gt")), mapping)
    to = normalize_bound(Map.get(payload, "lte", Map.get(payload, "lt")), mapping)

    lower_inclusive = Map.has_key?(payload, "gte")
    upper_inclusive = Map.has_key?(payload, "lte")
    boost = read_boost(payload)

    docs =
      live_doc_ids(state)
      |> Enum.filter(fn id ->
        value_for_doc(state, id, field)
        |> value_in_range?(from, to, lower_inclusive, upper_inclusive)
      end)

    scores =
      if mode == :score do
        docs
        |> Map.new(&{&1, 1.0 * boost})
      else
        %{}
      end

    %{docs: MapSet.new(docs), scores: scores}
  end

  defp phrase_docs(state, field, tokens, slop) do
    postings_by_token = Enum.map(tokens, &get_postings(state, field, &1))

    candidate_docs =
      postings_by_token
      |> Enum.map(&Map.keys/1)
      |> case do
        [] -> []
        [single] -> single
        many -> Enum.reduce(many, fn docs, acc -> Enum.filter(acc, &(&1 in docs)) end)
      end

    Enum.filter(candidate_docs, fn id ->
      positions = Enum.map(postings_by_token, fn postings -> Map.get(postings, id, []) end)
      phrase_positions_match?(positions, slop)
    end)
  end

  defp phrase_positions_match?([], _slop), do: false

  defp phrase_positions_match?([first | rest], slop) do
    Enum.any?(first, fn start_pos ->
      check_phrase_sequence(rest, start_pos, slop)
    end)
  end

  defp check_phrase_sequence([], _prev, _slop), do: true

  defp check_phrase_sequence([positions | tail], prev, slop) do
    Enum.any?(positions, fn pos ->
      gap = pos - prev - 1

      if pos > prev and gap <= slop do
        check_phrase_sequence(tail, pos, slop)
      else
        false
      end
    end)
  end

  defp score_text_postings(postings, state, field, boost) do
    postings
    |> Enum.reduce(%{}, fn {id, positions}, acc ->
      score = bm25_for_doc(state, field, id, length(positions), map_size(postings)) * boost
      Map.put(acc, id, score)
    end)
  end

  defp bm25_for_doc(state, field, id, tf, doc_freq) do
    n = max(doc_freq, 1)
    n_docs = max(state.live_docs, 1)
    idf = :math.log(1.0 + (n_docs - n + 0.5) / (n + 0.5))

    dl =
      state.docs
      |> Map.fetch!(id)
      |> Map.get(:tokens, %{})
      |> Map.get(field, [])
      |> length()

    avg_dl =
      state.field_lengths_total
      |> Map.get(field, 0)
      |> Kernel./(max(Map.get(state.field_doc_count, field, 1), 1))

    numerator = tf * (@k1 + 1.0)
    denominator = tf + @k1 * (1.0 - @b + @b * dl / max(avg_dl, 1.0))

    idf * numerator / max(denominator, 1.0e-9)
  end

  defp get_postings(state, field, term) do
    state
    |> Map.get(:inverted, %{})
    |> Map.get(field, %{})
    |> Map.get(term, %{})
  end

  defp value_for_doc(state, id, field) do
    state
    |> Map.get(:docs, %{})
    |> Map.get(id, %{})
    |> Map.get(:values, %{})
    |> Map.get(field)
  end

  defp live_doc_ids(state) do
    state.docs
    |> Enum.flat_map(fn {id, doc} -> if doc.deleted, do: [], else: [id] end)
  end

  defp value_equals?(doc_value, query_value) when is_list(doc_value) do
    Enum.any?(doc_value, &value_equals?(&1, query_value))
  end

  defp value_equals?(doc_value, query_value) do
    cond do
      is_nil(doc_value) ->
        false

      is_binary(doc_value) ->
        String.downcase(doc_value) == String.downcase(to_string(query_value))

      is_number(doc_value) and is_number(query_value) ->
        doc_value == query_value

      is_boolean(doc_value) and is_boolean(query_value) ->
        doc_value == query_value

      true ->
        to_string(doc_value) == to_string(query_value)
    end
  end

  defp value_in_range?(nil, _from, _to, _low_inc, _up_inc), do: false

  defp value_in_range?(values, from, to, low_inc, up_inc) when is_list(values) do
    Enum.any?(values, &value_in_range?(&1, from, to, low_inc, up_inc))
  end

  defp value_in_range?(value, from, to, low_inc, up_inc) do
    lower_ok =
      cond do
        is_nil(from) -> true
        low_inc -> value >= from
        true -> value > from
      end

    upper_ok =
      cond do
        is_nil(to) -> true
        up_inc -> value <= to
        true -> value < to
      end

    lower_ok and upper_ok
  rescue
    _ -> false
  end

  defp normalize_bound(nil, _mapping), do: nil

  defp normalize_bound(value, mapping) do
    case Map.get(mapping, "type", "float") do
      "integer" -> normalize_integer(value, nil)
      "float" -> normalize_float(value)
      "date" -> normalize_date(value)
      _ -> value
    end
  end

  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> fallback
    end
  end

  defp normalize_integer(_, fallback), do: fallback

  defp normalize_float(value) when is_integer(value), do: value * 1.0
  defp normalize_float(value) when is_float(value), do: value

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp normalize_float(_), do: nil

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

  defp merge_score_maps(score_maps) do
    Enum.reduce(score_maps, %{}, fn score_map, acc ->
      Map.merge(acc, score_map, fn _k, a, b -> a + b end)
    end)
  end

  defp multiply_scores(score_map, factor) do
    Map.new(score_map, fn {k, score} -> {k, score * factor} end)
  end

  defp intersect_doc_sets(results) do
    results
    |> Enum.map(& &1.docs)
    |> case do
      [] -> MapSet.new()
      [single] -> single
      [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
    end
  end

  defp union_doc_sets(results) do
    Enum.reduce(results, MapSet.new(), fn result, acc ->
      MapSet.union(acc, result.docs)
    end)
  end

  defp listify(value) when is_list(value), do: value
  defp listify(nil), do: []
  defp listify(value), do: [value]

  defp extract_field_payload(map) when is_map(map) do
    case Enum.at(Map.to_list(map), 0) do
      {field, payload} -> {field, payload}
      _ -> {"", %{"value" => nil}}
    end
  end

  defp read_payload_value(payload) when is_map(payload), do: Map.get(payload, "value")
  defp read_payload_value(payload), do: payload

  defp read_boost(payload) when is_map(payload) do
    case Map.get(payload, "boost", 1.0) do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {n, _} -> n
          :error -> 1.0
        end

      _ ->
        1.0
    end
  end

  defp read_boost(_), do: 1.0

  defp default_min_should(_must, _filter, []), do: 0
  defp default_min_should([], [], _should), do: 1
  defp default_min_should(_, _, _), do: 0

  defp normalize_fuzziness(value, _query_value) when is_integer(value), do: max(value, 0)

  defp normalize_fuzziness(value, query_value) when is_binary(value) do
    up = String.upcase(value)

    cond do
      up == "AUTO" ->
        len = query_value |> to_string() |> String.length()
        if len <= 4, do: 1, else: 2

      true ->
        normalize_integer(value, 1)
    end
  end

  defp normalize_fuzziness(_, _), do: 1

  defp wildcard_to_regex(pattern) do
    escaped =
      pattern
      |> to_string()
      |> String.downcase()
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> escaped <> "$", "u")
  end

  defp levenshtein(a, b) do
    a_gr = String.graphemes(a)
    b_gr = String.graphemes(b)

    rows = Enum.to_list(0..length(b_gr))

    a_gr
    |> Enum.with_index(1)
    |> Enum.reduce(rows, fn {char_a, i}, prev_row ->
      current_row_start = [i]

      b_gr
      |> Enum.with_index(1)
      |> Enum.reduce(current_row_start, fn {char_b, j}, current_row ->
        insert_cost = Enum.at(current_row, j - 1) + 1
        delete_cost = Enum.at(prev_row, j) + 1
        replace_cost = Enum.at(prev_row, j - 1) + if(char_a == char_b, do: 0, else: 1)
        current_row ++ [Enum.min([insert_cost, delete_cost, replace_cost])]
      end)
    end)
    |> List.last()
  end
end
