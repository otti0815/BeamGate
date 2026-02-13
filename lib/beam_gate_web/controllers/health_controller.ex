defmodule BeamGateWeb.HealthController do
  use BeamGateWeb, :controller

  def index(conn, _params) do
    text(conn, "ok")
  end
end
