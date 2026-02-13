defmodule BeamGateWeb.HomeController do
  use BeamGateWeb, :controller

  def index(conn, _params) do
    if get_session(conn, :admin_authenticated) do
      redirect(conn, to: "/admin/dashboard")
    else
      redirect(conn, to: "/admin/login")
    end
  end
end
