defmodule BeamGateWeb.SearchApiTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias BeamGate.Search

  @endpoint BeamGateWeb.Endpoint

  setup do
    {:ok, indexes} = Search.list_indexes()
    Enum.each(indexes, &Search.delete_index/1)
    :ok
  end

  test "index and document CRUD via REST API" do
    conn =
      put(json_conn(), "/api/v1/search/indexes/catalog", %{
        "settings" => %{"number_of_shards" => 2, "number_of_replicas" => 1},
        "mappings" => %{
          "title" => %{"type" => "text"},
          "category" => %{"type" => "keyword"},
          "price" => %{"type" => "float"}
        }
      })

    assert %{"acknowledged" => true, "index" => "catalog"} = json_response(conn, 201)

    conn =
      put(json_conn(), "/api/v1/search/indexes/catalog/documents/p1", %{
        "document" => %{
          "title" => "Elixir Guide",
          "category" => "book",
          "price" => 42.5
        }
      })

    assert %{"_id" => "p1", "result" => "created", "_version" => 1} = json_response(conn, 200)

    conn = get(json_conn(), "/api/v1/search/indexes/catalog/documents/p1")
    body = json_response(conn, 200)
    assert body["found"] == true
    assert body["_source"]["title"] == "Elixir Guide"

    conn =
      post(json_conn(), "/api/v1/search/indexes/catalog/_search", %{
        "query" => %{"term" => %{"category" => "book"}}
      })

    assert get_in(json_response(conn, 200), ["hits", "total", "value"]) == 1

    conn = delete(json_conn(), "/api/v1/search/indexes/catalog/documents/p1")
    assert json_response(conn, 200)["result"] == "deleted"

    conn = get(json_conn(), "/api/v1/search/indexes/catalog/documents/p1")
    assert json_response(conn, 404)["found"] == false
  end

  test "bulk, aggregations and refresh endpoints" do
    conn =
      put(json_conn(), "/api/v1/search/indexes/sales", %{
        "mappings" => %{
          "name" => %{"type" => "text"},
          "type" => %{"type" => "keyword"},
          "amount" => %{"type" => "float"}
        }
      })

    assert json_response(conn, 201)["acknowledged"] == true

    conn =
      post(json_conn(), "/api/v1/search/indexes/sales/_bulk", %{
        "operations" => [
          %{
            "index" => %{
              "_id" => "s1",
              "document" => %{"name" => "Order A", "type" => "retail", "amount" => 10.0}
            }
          },
          %{
            "index" => %{
              "_id" => "s2",
              "document" => %{"name" => "Order B", "type" => "retail", "amount" => 15.0}
            }
          },
          %{
            "index" => %{
              "_id" => "s3",
              "document" => %{"name" => "Order C", "type" => "b2b", "amount" => 100.0}
            }
          }
        ]
      })

    bulk_resp = json_response(conn, 200)
    assert bulk_resp["errors"] == false
    assert length(bulk_resp["items"]) == 3

    conn = post(json_conn(), "/api/v1/search/indexes/sales/_refresh", %{})
    assert get_in(json_response(conn, 200), ["_shards", "successful"]) == 1

    conn =
      post(json_conn(), "/api/v1/search/indexes/sales/_search", %{
        "query" => %{"match_all" => %{}},
        "aggs" => %{
          "by_type" => %{"terms" => %{"field" => "type", "size" => 10}},
          "sum_amount" => %{"sum" => %{"field" => "amount"}}
        }
      })

    response = json_response(conn, 200)
    assert get_in(response, ["hits", "total", "value"]) == 3
    assert get_in(response, ["aggregations", "sum_amount", "value"]) == 125.0

    buckets = get_in(response, ["aggregations", "by_type", "buckets"])
    assert Enum.any?(buckets, &(&1["key"] == "retail" and &1["doc_count"] == 2))
    assert Enum.any?(buckets, &(&1["key"] == "b2b" and &1["doc_count"] == 1))
  end

  defp json_conn do
    build_conn() |> put_req_header("content-type", "application/json")
  end
end
