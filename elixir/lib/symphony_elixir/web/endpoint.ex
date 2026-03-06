defmodule SymphonyElixir.Web.Endpoint do
  @moduledoc """
  Phoenix endpoint for the observability dashboard and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_key",
    signing_salt: "symphony_session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]]

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug SymphonyElixir.Web.Router
end
