defmodule BeamGate.Search do
  @moduledoc """
  Public API for the in-process full-text search engine.
  """

  alias BeamGate.Search.Manager

  def create_index(index, config \\ %{}) when is_binary(index),
    do: Manager.create_index(index, config)

  def delete_index(index) when is_binary(index), do: Manager.delete_index(index)
  def get_index(index) when is_binary(index), do: Manager.get_index(index)
  def list_indexes, do: Manager.list_indexes()

  def index_document(index, id, document, opts \\ %{})
      when is_binary(index) and is_binary(id) and is_map(document),
      do: Manager.index_document(index, id, document, opts)

  def get_document(index, id) when is_binary(index) and is_binary(id),
    do: Manager.get_document(index, id)

  def delete_document(index, id, opts \\ %{}) when is_binary(index) and is_binary(id),
    do: Manager.delete_document(index, id, opts)

  def bulk(index, operations) when is_binary(index) and is_list(operations),
    do: Manager.bulk(index, operations)

  def search(index, query) when is_binary(index) and is_map(query),
    do: Manager.search(index, query)

  def refresh(index) when is_binary(index), do: Manager.refresh(index)
end
