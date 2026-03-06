defmodule SymphonyElixir.Web.ApiController do
  @moduledoc """
  JSON API controller for orchestrator state and control.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Web.Presenter

  def state(conn, _params) do
    {orchestrator, timeout} = orchestrator_config()
    payload = Presenter.state_payload(orchestrator, timeout)
    json(conn, payload)
  end

  def refresh(conn, _params) do
    {orchestrator, _timeout} = orchestrator_config()

    case Presenter.request_refresh(orchestrator) do
      {:ok, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)

      {:error, :unavailable} ->
        conn
        |> put_status(503)
        |> json(%{error: %{code: "orchestrator_unavailable", message: "Orchestrator is unavailable"}})
    end
  end

  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    {orchestrator, timeout} = orchestrator_config()

    case Presenter.issue_payload(issue_identifier, orchestrator, timeout) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "issue_not_found", message: "Issue not found"}})
    end
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  def not_found(conn, _params) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "not_found", message: "Route not found"}})
  end

  defp orchestrator_config do
    orchestrator =
      Application.get_env(:symphony_elixir, :web_orchestrator, SymphonyElixir.Orchestrator)

    timeout =
      Application.get_env(:symphony_elixir, :web_snapshot_timeout_ms, 15_000)

    {orchestrator, timeout}
  end
end
