defmodule SymphonyElixir.Web.AssetController do
  @moduledoc """
  Serves compile-time embedded static assets.
  """

  use Phoenix.Controller, formats: [:html]

  alias SymphonyElixir.Web.Assets

  @spec css(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def css(conn, _params) do
    conn
    |> put_resp_content_type("text/css")
    |> send_resp(200, Assets.css())
  end

  @spec phoenix_js(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def phoenix_js(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> send_resp(200, Assets.phoenix_js())
  end

  @spec live_view_js(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live_view_js(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> send_resp(200, Assets.live_view_js())
  end
end
