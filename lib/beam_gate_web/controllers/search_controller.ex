defmodule BeamGateWeb.SearchController do
  use BeamGateWeb, :controller

  alias BeamGate.Search

  def create_index(conn, %{"index" => index} = params) do
    body = Map.drop(params, ["index"])

    case Search.create_index(index, body) do
      {:ok, :created} ->
        conn
        |> put_status(:created)
        |> json(%{"acknowledged" => true, "index" => index})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def delete_index(conn, %{"index" => index}) do
    case Search.delete_index(index) do
      {:ok, :deleted} -> json(conn, %{"acknowledged" => true, "index" => index})
      {:error, reason} -> error(conn, reason)
    end
  end

  def get_index(conn, %{"index" => index}) do
    case Search.get_index(index) do
      {:ok, metadata} -> json(conn, metadata)
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_document(conn, %{"index" => index, "id" => id} = params) do
    document = Map.get(params, "document", Map.drop(params, ["index", "id"]))

    if is_map(document) do
      case Search.index_document(index, id, document) do
        {:ok, metadata} -> json(conn, encode_doc_write(metadata))
        {:error, reason} -> error(conn, reason)
      end
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "invalid_document"})
    end
  end

  def get_document(conn, %{"index" => index, "id" => id}) do
    case Search.get_document(index, id) do
      {:ok, doc} ->
        json(conn, %{
          "found" => true,
          "_id" => doc.id,
          "_version" => doc.version,
          "_seq_no" => doc.seq_no,
          "_primary_term" => doc.primary_term,
          "_source" => doc.source
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"found" => false, "_id" => id})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def delete_document(conn, %{"index" => index, "id" => id}) do
    case Search.delete_document(index, id) do
      {:ok, metadata} ->
        json(conn, %{
          "_id" => metadata.id,
          "_version" => metadata.version,
          "_seq_no" => metadata.seq_no,
          "_primary_term" => metadata.primary_term,
          "result" => metadata.result
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def bulk(conn, %{"index" => index} = params) do
    operations = Map.get(params, "operations", [])

    if is_list(operations) do
      case Search.bulk(index, operations) do
        {:ok, payload} -> json(conn, payload)
        {:error, reason} -> error(conn, reason)
      end
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "invalid_bulk_payload"})
    end
  end

  def search(conn, %{"index" => index} = params) do
    body = Map.drop(params, ["index"])

    case Search.search(index, body) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> error(conn, reason)
    end
  end

  def refresh(conn, %{"index" => index}) do
    case Search.refresh(index) do
      {:ok, :refreshed} -> json(conn, %{"_shards" => %{"successful" => 1}})
      {:error, reason} -> error(conn, reason)
    end
  end

  defp encode_doc_write(metadata) do
    %{
      "_id" => metadata.id,
      "_version" => metadata.version,
      "_seq_no" => metadata.seq_no,
      "_primary_term" => metadata.primary_term,
      "_shard" => metadata.shard,
      "result" => metadata.result
    }
  end

  defp error(conn, :index_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "index_not_found"})
  end

  defp error(conn, :index_already_exists) do
    conn
    |> put_status(:conflict)
    |> json(%{"error" => "index_already_exists"})
  end

  defp error(conn, :index_unavailable) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{"error" => "index_unavailable"})
  end

  defp error(conn, {:replication_failed, reason}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{"error" => "replication_failed", "reason" => inspect(reason)})
  end

  defp error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => inspect(reason)})
  end
end
