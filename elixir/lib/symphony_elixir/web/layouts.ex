defmodule SymphonyElixir.Web.Layouts do
  @moduledoc """
  Layout components for the observability dashboard.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()}/>
        <title>Symphony Dashboard</title>
        <link rel="stylesheet" href="/dashboard.css"/>
        <script src="/vendor/phoenix/phoenix.js"></script>
        <script src="/vendor/phoenix/phoenix_live_view.js"></script>
      </head>
      <body>
        {@inner_content}
        <script>
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
          liveSocket.connect()
        </script>
      </body>
    </html>
    """
  end
end
