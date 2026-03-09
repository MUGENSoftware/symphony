defmodule SymphonyElixir.Web.Router do
  @moduledoc """
  Routes for the observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {SymphonyElixir.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixir.Web do
    pipe_through(:browser)
    live("/", DashboardLive, :index)
  end

  get("/dashboard.css", SymphonyElixir.Web.AssetController, :css)
  get("/vendor/phoenix/phoenix.js", SymphonyElixir.Web.AssetController, :phoenix_js)
  get("/vendor/phoenix/phoenix_live_view.js", SymphonyElixir.Web.AssetController, :live_view_js)

  scope "/api/v1", SymphonyElixir.Web do
    get("/state", ApiController, :state)
    post("/state", ApiController, :method_not_allowed)
    put("/state", ApiController, :method_not_allowed)
    patch("/state", ApiController, :method_not_allowed)
    delete("/state", ApiController, :method_not_allowed)

    post("/refresh", ApiController, :refresh)
    get("/refresh", ApiController, :method_not_allowed)
    put("/refresh", ApiController, :method_not_allowed)
    patch("/refresh", ApiController, :method_not_allowed)
    delete("/refresh", ApiController, :method_not_allowed)

    get("/:issue_identifier", ApiController, :issue)
    post("/:issue_identifier", ApiController, :method_not_allowed)
    put("/:issue_identifier", ApiController, :method_not_allowed)
    patch("/:issue_identifier", ApiController, :method_not_allowed)
    delete("/:issue_identifier", ApiController, :method_not_allowed)
  end

  post("/", SymphonyElixir.Web.ApiController, :method_not_allowed)
  put("/", SymphonyElixir.Web.ApiController, :method_not_allowed)
  patch("/", SymphonyElixir.Web.ApiController, :method_not_allowed)
  delete("/", SymphonyElixir.Web.ApiController, :method_not_allowed)

  get("/*path", SymphonyElixir.Web.ApiController, :not_found)
  post("/*path", SymphonyElixir.Web.ApiController, :not_found)
  put("/*path", SymphonyElixir.Web.ApiController, :not_found)
  patch("/*path", SymphonyElixir.Web.ApiController, :not_found)
  delete("/*path", SymphonyElixir.Web.ApiController, :not_found)
end
