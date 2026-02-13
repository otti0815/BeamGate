defmodule BeamGateWeb.Layouts do
  use BeamGateWeb, :html

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Reverse Proxy</title>
        <style>
          body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 0; background: #f7f8fb; }
          .shell { max-width: 1100px; margin: 24px auto; padding: 0 12px; }
          .card { background: white; border: 1px solid #e2e8f0; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
          table { width: 100%; border-collapse: collapse; }
          th, td { border-bottom: 1px solid #e5e7eb; padding: 8px; text-align: left; }
          .muted { color: #64748b; }
          input, button, select { padding: 8px; border-radius: 8px; border: 1px solid #cbd5e1; }
          button { cursor: pointer; }
          .error { color: #b91c1c; }
        </style>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main class="shell">
      <%= if flash = Phoenix.Flash.get(@flash, :error) do %>
        <p class="error"><%= flash %></p>
      <% end %>
      <%= if flash = Phoenix.Flash.get(@flash, :info) do %>
        <p><%= flash %></p>
      <% end %>
      {@inner_content}
    </main>
    """
  end
end
