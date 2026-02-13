defmodule BeamGate.Proxy.Forwarder do
  @moduledoc false

  # RFC hop-by-hop headers should not be forwarded by proxies.
  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)

  def forward(conn, route, endpoint) do
    with {:ok, body} <- read_body(conn),
         {:ok, request} <- build_request(conn, endpoint, body, route),
         {:ok, streamed_conn} <- stream_response(request, conn, route) do
      {:ok, streamed_conn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_body(conn), do: read_body(conn, [])

  defp read_body(conn, acc) do
    # MVP tradeoff: buffer request body before forwarding. Response path is still streamed.
    case Plug.Conn.read_body(conn,
           length: 8_000_000,
           read_length: 1_000_000,
           read_timeout: 15_000
         ) do
      {:ok, chunk, _conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc]))}
      {:more, chunk, conn} -> read_body(conn, [chunk | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_request(conn, endpoint, body, route) do
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
    url = "http://#{endpoint.host}:#{endpoint.port}#{conn.request_path}#{query}"

    headers =
      conn.req_headers
      |> Enum.reject(fn {k, _} -> String.downcase(k) in @hop_by_hop_headers end)
      |> BeamGate.Proxy.HeaderInjector.inject_request_headers(route.middleware || %{})

    method = method_atom(conn.method)

    {:ok, Finch.build(method, url, headers, body)}
  end

  defp stream_response(request, conn, route) do
    acc = %{conn: conn, status: nil, headers: [], started?: false}

    case Finch.stream(request, BeamGate.Finch, acc, &handle_stream_event(&1, &2, route),
           receive_timeout: 30_000
         ) do
      {:ok, %{conn: conn}} -> {:ok, conn}
      {:error, reason, _acc} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_stream_event({:status, status}, acc, route),
    do: maybe_start_response(%{acc | status: status}, route)

  defp handle_stream_event({:headers, headers}, acc, route) do
    filtered = Enum.reject(headers, fn {k, _} -> String.downcase(k) in @hop_by_hop_headers end)
    maybe_start_response(%{acc | headers: filtered}, route)
  end

  defp handle_stream_event({:data, data}, acc, route) do
    acc = maybe_start_response(acc, route)
    {:ok, conn} = Plug.Conn.chunk(acc.conn, data)
    %{acc | conn: conn}
  end

  defp handle_stream_event(_event, acc, _route), do: acc

  defp maybe_start_response(%{started?: true} = acc, _route), do: acc

  defp maybe_start_response(%{status: nil} = acc, _route), do: acc

  defp maybe_start_response(%{conn: conn, status: status, headers: headers} = acc, route) do
    conn =
      headers
      |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, String.downcase(k), v) end)
      |> BeamGate.Proxy.HeaderInjector.inject_response_headers(route.middleware || %{})

    # Send headers once, then stream upstream chunks directly to the client.
    {:ok, conn} = Plug.Conn.send_chunked(conn, status)
    %{acc | conn: conn, started?: true}
  end

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete
  defp method_atom("HEAD"), do: :head
  defp method_atom("OPTIONS"), do: :options
  defp method_atom(_), do: :get
end
