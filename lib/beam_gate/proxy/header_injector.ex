defmodule BeamGate.Proxy.HeaderInjector do
  @moduledoc false

  def inject_request_headers(headers, middleware) do
    injection =
      middleware
      |> Map.get(:request_headers, %{})
      |> Enum.map(fn {k, v} -> {normalize_key(k), to_string(v)} end)

    dedupe(headers ++ injection)
  end

  def inject_response_headers(conn, middleware) do
    middleware
    |> Map.get(:response_headers, %{})
    |> Enum.reduce(conn, fn {k, v}, acc ->
      Plug.Conn.put_resp_header(acc, normalize_key(k), to_string(v))
    end)
  end

  defp normalize_key(key), do: key |> to_string() |> String.downcase()

  defp dedupe(headers) do
    headers
    |> Enum.reverse()
    |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end)
    |> Enum.reverse()
  end
end
