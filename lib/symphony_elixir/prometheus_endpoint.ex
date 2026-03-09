defmodule SymphonyElixir.PrometheusEndpoint do
  @moduledoc """
  Minimal HTTP endpoint that serves Prometheus metrics on the port
  configured by `SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT`.

  Started by `OtelSetup` only when observability is enabled and the
  port env var is set.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    metrics = TelemetryMetricsPrometheus.Core.scrape(:symphony_prometheus)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc """
  Starts the Bandit HTTP server for the Prometheus scrape endpoint.
  """
  @spec start(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start(port) when is_integer(port) do
    Bandit.start_link(plug: __MODULE__, port: port, scheme: :http)
  end
end
