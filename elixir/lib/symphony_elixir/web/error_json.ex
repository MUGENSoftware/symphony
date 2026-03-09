defmodule SymphonyElixir.Web.ErrorJSON do
  @moduledoc """
  Fallback error renderer for unmatched routes.
  """

  @spec render(String.t(), map()) :: map()
  def render("404.json", _assigns) do
    %{error: %{code: "not_found", message: "Route not found"}}
  end

  def render("405.json", _assigns) do
    %{error: %{code: "method_not_allowed", message: "Method not allowed"}}
  end

  def render(template, _assigns) do
    %{error: %{code: "server_error", message: Phoenix.Controller.status_message_from_template(template)}}
  end
end
