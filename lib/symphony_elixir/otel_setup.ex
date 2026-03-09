defmodule SymphonyElixir.OtelSetup do
  @moduledoc """
  Bootstraps OpenTelemetry tracing and Prometheus metrics exporting.

  Reads runtime environment variables to configure the OTEL exporter and
  optionally start a Prometheus metrics endpoint. The entire pipeline is
  gated by `SYMPHONY_OBSERVABILITY_ENABLED` — when unset or `"false"` the
  application starts normally with no OTEL dependency.
  """

  use GenServer
  require Logger

  @service_name "symphony-elixir"

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Returns `true` when the observability pipeline is enabled via env.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("SYMPHONY_OBSERVABILITY_ENABLED", "false")
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes"])
  end

  @doc """
  Child spec used by the Application supervisor.

  When observability is disabled, returns `:ignore` so the supervisor
  simply skips this child without error.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts) do
    if enabled?() do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    else
      :ignore
    end
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    configure_otel_exporter()
    configure_resource_attributes()
    attach_telemetry_handlers()
    maybe_start_prometheus()

    Logger.info("OtelSetup initialised",
      otel_endpoint: otel_endpoint(),
      otel_protocol: otel_protocol(),
      prometheus_port: prometheus_port()
    )

    {:ok, %{}}
  end

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  defp configure_otel_exporter do
    endpoint = otel_endpoint()
    protocol = otel_protocol()

    if endpoint do
      otel_protocol_atom =
        case protocol do
          "grpc" -> :grpc
          "http/protobuf" -> :http_protobuf
          _ -> :http_protobuf
        end

      Application.put_env(:opentelemetry_exporter, :otlp_endpoint, endpoint)
      Application.put_env(:opentelemetry_exporter, :otlp_protocol, otel_protocol_atom)
    end
  end

  defp configure_resource_attributes do
    Application.put_env(:opentelemetry, :resource, [
      {:"service.name", @service_name}
    ])
  end

  defp attach_telemetry_handlers do
    events = [
      [:symphony, :orchestrator, :poll],
      [:symphony, :agent_runner, :run],
      [:symphony, :linear, :request]
    ]

    :telemetry.attach_many(
      "symphony-otel-handler",
      events,
      &handle_telemetry_event/4,
      %{}
    )
  end

  @doc false
  @spec handle_telemetry_event([atom()], map(), map(), map()) :: :ok
  def handle_telemetry_event(event, measurements, metadata, _config) do
    event_name = Enum.join(event, ".")

    Logger.debug("telemetry event",
      event: event_name,
      measurements: inspect(measurements),
      metadata: inspect(metadata)
    )
  end

  defp maybe_start_prometheus do
    case prometheus_port() do
      nil ->
        :ok

      _port ->
        metrics = [
          Telemetry.Metrics.counter("symphony.orchestrator.poll.count"),
          Telemetry.Metrics.distribution("symphony.agent_runner.run.duration",
            unit: {:native, :millisecond}
          ),
          Telemetry.Metrics.counter("symphony.linear.request.count")
        ]

        TelemetryMetricsPrometheus.Core.start_link(metrics: metrics, name: :symphony_prometheus)
    end
  end

  defp otel_endpoint, do: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

  defp otel_protocol, do: System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")

  defp prometheus_port do
    case System.get_env("SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT") do
      nil -> nil
      val -> String.to_integer(val)
    end
  end
end
