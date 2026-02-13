defmodule BeamGate.Proxy.BasicAuth do
  @moduledoc false

  def authorize(conn, middleware) do
    case Map.get(middleware, :basic_auth) do
      nil -> {:ok, conn}
      %{username: user, password: pass} -> enforce(conn, to_string(user), to_string(pass))
      %{"username" => user, "password" => pass} -> enforce(conn, to_string(user), to_string(pass))
      _ -> {:ok, conn}
    end
  end

  defp enforce(conn, expected_user, expected_pass) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {user, pass} when user == expected_user and pass == expected_pass ->
        {:ok, conn}

      _ ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Basic realm=\"BeamGate\"")
          |> Plug.Conn.send_resp(401, "Unauthorized")

        {:halt, Plug.Conn.halt(conn)}
    end
  end
end
