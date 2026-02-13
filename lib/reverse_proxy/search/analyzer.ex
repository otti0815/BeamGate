defmodule ReverseProxy.Search.Analyzer do
  @moduledoc false

  @default_analyzers %{
    "standard" => %{"tokenizer" => "standard", "filter" => ["lowercase"]},
    "whitespace" => %{"tokenizer" => "whitespace", "filter" => ["lowercase"]},
    "keyword" => %{"tokenizer" => "keyword", "filter" => []}
  }

  @english_stopwords MapSet.new(
                       ~w(a an and are as at be but by for from if in into is it no not of on or s such t that the their then there these they this to was will with)
                     )
  @german_stopwords MapSet.new(
                      ~w(aber als am an auch auf aus bei bin bis bist da dadurch daher darum das dass dein deine dem den der des dessen deshalb die dies dieser dieses doch dort du durch ein eine einem einen einer eines er es euer eure für hatte hatten hattest hattet hier hinter ich ihr ihre im in ist ja jede jedem jeden jeder jedes jener jenes jetzt kann kannst können könnt machen mein meine mit muss müsst nach nachdem nein nicht nun oder seid sein seine sich sie sind soll sollen sollst sollt sonst soweit sowie und unser unsere unter vom von vor wann warum was weiter weitere wenn wer werde werden werdet weshalb wie wieder wieso wir wird wirst wo woher wohin zu zum zur über)
                    )

  def analyze(value, mapping, analysis, mode \\ :index)

  def analyze(nil, _mapping, _analysis, _mode), do: []

  def analyze(value, _mapping, _analysis, _mode) when is_number(value) or is_boolean(value),
    do: [to_string(value)]

  def analyze(value, mapping, analysis, mode) do
    analyzer_name =
      mapping
      |> Map.get("analyzer", default_analyzer(mapping))
      |> to_string()

    analyzer =
      get_in(analysis, ["analyzer", analyzer_name]) ||
        Map.get(@default_analyzers, analyzer_name, @default_analyzers["standard"])

    tokenizer = Map.get(analyzer, "tokenizer", "standard")
    filters = Map.get(analyzer, "filter", [])

    value
    |> to_string()
    |> tokenize(tokenizer)
    |> apply_filters(filters, analysis, mode)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_analyzer(mapping) do
    case Map.get(mapping, "type", "text") do
      "keyword" -> "keyword"
      _ -> "standard"
    end
  end

  defp tokenize(value, "keyword"), do: [value]

  defp tokenize(value, "whitespace") do
    value
    |> String.trim()
    |> String.split(~r/\s+/u, trim: true)
  end

  defp tokenize(value, _standard) do
    value
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_-]+/u, trim: true)
  end

  defp apply_filters(tokens, filters, analysis, mode) do
    Enum.reduce(filters, tokens, fn filter, acc ->
      apply_filter(acc, filter, analysis, mode)
    end)
  end

  defp apply_filter(tokens, filter_name, analysis, mode) when is_binary(filter_name) do
    downcased = String.downcase(filter_name)

    cond do
      filter_name == "lowercase" ->
        Enum.map(tokens, &String.downcase/1)

      filter_name in ["asciifolding", "ascii_folding"] ->
        Enum.map(tokens, &ascii_fold/1)

      String.contains?(downcased, "stop") ->
        stopwords = stopwords_for(filter_name)
        Enum.reject(tokens, &MapSet.member?(stopwords, &1))

      String.contains?(downcased, "stem") ->
        stemmer = stemmer_for(filter_name)
        Enum.map(tokens, &stem(stemmer, &1))

      true ->
        case get_in(analysis, ["filter", filter_name]) do
          %{"type" => "synonym"} = config ->
            expand_synonyms(tokens, config, mode)

          %{"type" => "stop", "stopwords" => stopwords} when is_list(stopwords) ->
            stopword_set = MapSet.new(Enum.map(stopwords, &String.downcase/1))
            Enum.reject(tokens, &MapSet.member?(stopword_set, &1))

          %{"type" => "stemmer", "language" => lang} ->
            Enum.map(tokens, &stem(to_string(lang), &1))

          _ ->
            tokens
        end
    end
  end

  defp apply_filter(tokens, _unknown, _analysis, _mode), do: tokens

  defp ascii_fold(value) do
    value
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp expand_synonyms(tokens, config, mode) do
    synonyms =
      config
      |> Map.get("synonyms", [])
      |> build_synonym_map()

    expanded =
      Enum.flat_map(tokens, fn token ->
        [token | Map.get(synonyms, token, [])]
      end)

    case mode do
      :query -> Enum.uniq(expanded)
      _ -> expanded
    end
  end

  defp build_synonym_map(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      parse_synonym_rule(rule, acc)
    end)
  end

  defp parse_synonym_rule(rule, acc) when is_binary(rule) do
    cond do
      String.contains?(rule, "=>") ->
        [left, right] = String.split(rule, "=>", parts: 2)
        left_terms = parse_synonym_terms(left)
        right_terms = parse_synonym_terms(right)

        Enum.reduce(left_terms, acc, fn term, term_acc ->
          Map.update(term_acc, term, right_terms, &Enum.uniq(&1 ++ right_terms))
        end)

      String.contains?(rule, ",") ->
        terms = parse_synonym_terms(rule)

        Enum.reduce(terms, acc, fn term, term_acc ->
          alternatives = Enum.reject(terms, &(&1 == term))
          Map.update(term_acc, term, alternatives, &Enum.uniq(&1 ++ alternatives))
        end)

      true ->
        acc
    end
  end

  defp parse_synonym_rule(_, acc), do: acc

  defp parse_synonym_terms(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp stopwords_for(name) do
    downcased = String.downcase(name)

    cond do
      String.contains?(downcased, "german") or String.contains?(downcased, "de") ->
        @german_stopwords

      true ->
        @english_stopwords
    end
  end

  defp stemmer_for(name) do
    downcased = String.downcase(name)

    cond do
      String.contains?(downcased, "german") or String.contains?(downcased, "de") -> "german"
      true -> "english"
    end
  end

  defp stem("english", token) do
    token
    |> strip_suffix("ing", 5)
    |> strip_suffix("edly", 6)
    |> strip_suffix("ed", 4)
    |> strip_suffix("ly", 4)
    |> strip_suffix("es", 4)
    |> strip_suffix("s", 4)
  end

  defp stem("german", token) do
    token
    |> strip_suffix("ern", 6)
    |> strip_suffix("er", 5)
    |> strip_suffix("en", 5)
    |> strip_suffix("es", 5)
    |> strip_suffix("e", 4)
    |> strip_suffix("n", 4)
    |> strip_suffix("s", 4)
  end

  defp stem(_unknown, token), do: token

  defp strip_suffix(token, suffix, min_length) do
    if String.length(token) >= min_length and String.ends_with?(token, suffix) do
      String.slice(token, 0, String.length(token) - String.length(suffix))
    else
      token
    end
  end
end
