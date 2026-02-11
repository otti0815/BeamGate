defmodule ReverseProxyWeb.AdminSessionController do
  use ReverseProxyWeb, :controller

  def new(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    html(conn, """
    <main class=\"shell\">
      <section class=\"card\">
        <h1>Reverse Proxy Admin</h1>
        <p class=\"muted\">Sign in to access route management.</p>
        <form method=\"post\" action=\"/admin/login\">
          <input type=\"hidden\" name=\"_csrf_token\" value=\"#{csrf}\" />
          <label>Username</label><br/>
          <input type=\"text\" name=\"username\" /><br/><br/>
          <label>Password</label><br/>
          <input type=\"password\" name=\"password\" /><br/><br/>
          <button type=\"submit\">Sign in</button>
        </form>
      </section>
    </main>
    """)
  end

  def create(conn, %{"username" => username, "password" => password}) do
    expected_user = Application.get_env(:reverse_proxy, :admin_user, "admin")
    expected_pass = Application.get_env(:reverse_proxy, :admin_pass, "admin")

    if username == expected_user and password == expected_pass do
      conn
      |> put_session(:admin_authenticated, true)
      |> put_flash(:info, "Signed in")
      |> redirect(to: "/admin/dashboard")
    else
      conn
      |> put_flash(:error, "Invalid credentials")
      |> redirect(to: "/admin/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Missing credentials")
    |> redirect(to: "/admin/login")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out")
    |> redirect(to: "/admin/login")
  end
end
