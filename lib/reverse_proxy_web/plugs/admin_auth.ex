defmodule ReverseProxyWeb.Plugs.AdminAuth do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if blocked_ip?(conn) do
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    else
      authorize_session(conn)
    end
  end

  defp authorize_session(conn) do
    if get_session(conn, :admin_authenticated) do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in")
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end

  defp blocked_ip?(conn) do
    whitelist = Application.get_env(:reverse_proxy, :admin_ip_whitelist, "")

    allowed =
      whitelist
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    case allowed do
      [] -> false
      ips -> remote_ip(conn) not in ips
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
