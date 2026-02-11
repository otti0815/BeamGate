defmodule ReverseProxyWeb.HealthController do
  use ReverseProxyWeb, :controller

  def index(conn, _params) do
    text(conn, "ok")
  end
end
