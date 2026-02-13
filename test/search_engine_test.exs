defmodule BeamGate.SearchEngineTest do
  use ExUnit.Case, async: false

  alias BeamGate.Search

  setup do
    {:ok, indexes} = Search.list_indexes()
    Enum.each(indexes, &Search.delete_index/1)
    :ok
  end

  test "index CRUD and versioning" do
    assert {:ok, :created} =
             Search.create_index("docs", %{
               "settings" => %{"number_of_shards" => 2, "number_of_replicas" => 1},
               "mappings" => %{
                 "title" => %{"type" => "text"},
                 "year" => %{"type" => "integer"},
                 "category" => %{"type" => "keyword"}
               }
             })

    assert {:ok, created} =
             Search.index_document("docs", "1", %{
               "title" => "Elixir Distributed Systems",
               "year" => 2024,
               "category" => "book"
             })

    assert created.version == 1
    assert created.result == "created"

    assert {:ok, updated} =
             Search.index_document("docs", "1", %{
               "title" => "Elixir Distributed Systems Second Edition",
               "year" => 2025,
               "category" => "book"
             })

    assert updated.version == 2
    assert updated.result == "updated"

    assert {:ok, doc} = Search.get_document("docs", "1")
    assert doc.source["year"] == 2025

    assert {:ok, deleted} = Search.delete_document("docs", "1")
    assert deleted.result == "deleted"

    assert {:error, :not_found} = Search.get_document("docs", "1")
  end

  test "query dsl supports match, phrase, bool, fuzzy, wildcard and range" do
    assert {:ok, :created} =
             Search.create_index("articles", %{
               "settings" => %{"number_of_shards" => 3, "number_of_replicas" => 0},
               "mappings" => %{
                 "title" => %{"type" => "text"},
                 "body" => %{"type" => "text"},
                 "year" => %{"type" => "integer"},
                 "tag" => %{"type" => "keyword"}
               }
             })

    docs = [
      {"a1",
       %{
         "title" => "Elixir in Practice",
         "body" => "Building distributed systems with beam",
         "year" => 2023,
         "tag" => "elixir"
       }},
      {"a2",
       %{
         "title" => "Erlang and OTP",
         "body" => "Practical distributed systems concepts",
         "year" => 2021,
         "tag" => "erlang"
       }},
      {"a3",
       %{
         "title" => "Search Engineering",
         "body" => "full text retrieval and scoring",
         "year" => 2024,
         "tag" => "search"
       }}
    ]

    Enum.each(docs, fn {id, doc} ->
      assert {:ok, _} = Search.index_document("articles", id, doc)
    end)

    assert {:ok, match_resp} =
             Search.search("articles", %{
               "query" => %{
                 "match" => %{"body" => %{"query" => "distributed systems", "operator" => "and"}}
               }
             })

    assert get_in(match_resp, ["hits", "total", "value"]) == 2

    assert {:ok, phrase_resp} =
             Search.search("articles", %{
               "query" => %{"phrase" => %{"body" => %{"query" => "distributed systems"}}}
             })

    assert get_in(phrase_resp, ["hits", "total", "value"]) == 2

    assert {:ok, wildcard_resp} =
             Search.search("articles", %{
               "query" => %{"wildcard" => %{"title" => "elix*"}}
             })

    assert get_in(wildcard_resp, ["hits", "total", "value"]) == 1

    assert {:ok, fuzzy_resp} =
             Search.search("articles", %{
               "query" => %{"fuzzy" => %{"title" => %{"value" => "elxir", "fuzziness" => 1}}}
             })

    assert get_in(fuzzy_resp, ["hits", "total", "value"]) == 1

    assert {:ok, bool_resp} =
             Search.search("articles", %{
               "query" => %{
                 "bool" => %{
                   "must" => [%{"match" => %{"body" => %{"query" => "distributed"}}}],
                   "filter" => [%{"range" => %{"year" => %{"gte" => 2022}}}],
                   "must_not" => [%{"term" => %{"tag" => "erlang"}}]
                 }
               }
             })

    assert get_in(bool_resp, ["hits", "total", "value"]) == 1
    assert get_in(bool_resp, ["hits", "hits"]) |> List.first() |> Map.get("_id") == "a1"
  end

  test "aggregations and pagination" do
    assert {:ok, :created} =
             Search.create_index("products", %{
               "mappings" => %{
                 "name" => %{"type" => "text"},
                 "category" => %{"type" => "keyword"},
                 "price" => %{"type" => "float"}
               }
             })

    data = [
      {"p1", %{"name" => "Elixir Book", "category" => "books", "price" => 30.0}},
      {"p2", %{"name" => "OTP Book", "category" => "books", "price" => 25.0}},
      {"p3", %{"name" => "Search Course", "category" => "courses", "price" => 120.0}}
    ]

    Enum.each(data, fn {id, doc} ->
      assert {:ok, _} = Search.index_document("products", id, doc)
    end)

    assert {:ok, page_1} =
             Search.search("products", %{
               "query" => %{"match_all" => %{}},
               "sort" => [%{"price" => "asc"}, %{"_id" => "asc"}],
               "size" => 1,
               "aggs" => %{
                 "by_category" => %{"terms" => %{"field" => "category", "size" => 10}},
                 "price_sum" => %{"sum" => %{"field" => "price"}}
               }
             })

    first_hit = page_1["hits"]["hits"] |> List.first()
    assert first_hit["_id"] == "p2"
    assert page_1["aggregations"]["by_category"]["buckets"] |> length() == 2
    assert page_1["aggregations"]["price_sum"]["value"] == 175.0

    sort_cursor = first_hit["sort"]

    assert {:ok, page_2} =
             Search.search("products", %{
               "query" => %{"match_all" => %{}},
               "sort" => [%{"price" => "asc"}, %{"_id" => "asc"}],
               "size" => 1,
               "search_after" => sort_cursor
             })

    second_hit = page_2["hits"]["hits"] |> List.first()
    assert second_hit["_id"] == "p1"
  end

  test "analyzer pipeline supports stopwords, stemming and synonyms" do
    assert {:ok, :created} =
             Search.create_index("analyzed", %{
               "analysis" => %{
                 "filter" => %{
                   "my_synonyms" => %{
                     "type" => "synonym",
                     "synonyms" => ["usa => united,states"]
                   }
                 },
                 "analyzer" => %{
                   "en_custom" => %{
                     "tokenizer" => "standard",
                     "filter" => ["lowercase", "my_synonyms", "english_stop", "english_stem"]
                   }
                 }
               },
               "mappings" => %{
                 "body" => %{"type" => "text", "analyzer" => "en_custom"}
               }
             })

    assert {:ok, _} = Search.index_document("analyzed", "d1", %{"body" => "The systems in usa"})

    assert {:ok, response} =
             Search.search("analyzed", %{
               "query" => %{
                 "match" => %{
                   "body" => %{"query" => "system united states", "operator" => "and"}
                 }
               }
             })

    assert get_in(response, ["hits", "total", "value"]) == 1
    assert get_in(response, ["hits", "hits"]) |> List.first() |> Map.get("_id") == "d1"
  end

  test "range query works for date values" do
    assert {:ok, :created} =
             Search.create_index("events", %{
               "mappings" => %{
                 "title" => %{"type" => "text"},
                 "published_at" => %{"type" => "date"}
               }
             })

    assert {:ok, _} =
             Search.index_document("events", "e1", %{
               "title" => "Older",
               "published_at" => "2024-01-10"
             })

    assert {:ok, _} =
             Search.index_document("events", "e2", %{
               "title" => "Recent",
               "published_at" => "2024-05-10"
             })

    assert {:ok, response} =
             Search.search("events", %{
               "query" => %{
                 "range" => %{
                   "published_at" => %{
                     "gte" => "2024-05-01",
                     "lte" => "2024-12-31"
                   }
                 }
               }
             })

    assert get_in(response, ["hits", "total", "value"]) == 1
    assert get_in(response, ["hits", "hits"]) |> List.first() |> Map.get("_id") == "e2"
  end
end
