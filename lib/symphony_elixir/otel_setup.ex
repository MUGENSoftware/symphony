defmodule SymphonyElixir.OtelSetup do
  @moduledoc """
  Boot-time OpenTelemetry configuration.

  Configures the OTEL exporter, resource attributes, and attaches
  telemetry handlers. Runs as a transient worker in the application
  supervisor to perform one-time setup at startup.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    configure_resource()
    configure_exporter()

    Logger.info("OpenTelemetry configured for service=symphony-elixir")

    {:ok, %{}, :hibernate}
  end

  defp configure_resource do
    :application.set_env(:opentelemetry, :resource, [
      {"service.name", "symphony-elixir"},
      {"service.version", SymphonyElixir.MixProject.project()[:version] || "0.1.0"}
    ])
  end

  defp configure_exporter do
    endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    protocol = System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")

    if endpoint do
      :application.set_env(:opentelemetry_exporter, :otlp_endpoint, endpoint)
      :application.set_env(:opentelemetry_exporter, :otlp_protocol, String.to_atom(protocol))
    else
      :application.set_env(:opentelemetry, :traces_exporter, :none)
    end
  end

  @doc """
  Returns true if observability is enabled via environment variable.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("SYMPHONY_OBSERVABILITY_ENABLED", "true") == "true"
  end
end
