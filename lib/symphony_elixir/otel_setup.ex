defmodule SymphonyElixir.OtelSetup do
  @moduledoc """
  Bootstraps OpenTelemetry tracing and Prometheus metrics exporting.

  Reads runtime environment variables to configure the OTEL exporter and
  optionally start a Prometheus metrics endpoint. The entire pipeline is
  gated by `SYMPHONY_OBSERVABILITY_ENABLED` so the application can start
  normally with no exporter configured.
  """

  use GenServer
  require Logger

  @service_name "symphony-elixir"

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
  Child spec used by the application supervisor.
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

  @impl true
  def init(_opts) do
    configure_resource_attributes()
    configure_otel_exporter()
    attach_telemetry_handlers()
    maybe_start_prometheus()

    Logger.info("OtelSetup initialised",
      otel_endpoint: otel_endpoint(),
      otel_protocol: otel_protocol(),
      prometheus_port: prometheus_port()
    )

    {:ok, %{}, :hibernate}
  end

  defp configure_resource_attributes do
    Application.put_env(:opentelemetry, :resource, [
      {"service.name", @service_name},
      {"service.version", service_version()}
    ])
  end

  defp configure_otel_exporter do
    case otel_endpoint() do
      nil ->
        Application.put_env(:opentelemetry, :traces_exporter, :none)

      endpoint ->
        case ensure_transport_started(otel_protocol_atom()) do
          :ok ->
            Application.put_env(:opentelemetry_exporter, :otlp_endpoint, endpoint)
            Application.put_env(:opentelemetry_exporter, :otlp_protocol, otel_protocol_atom())

          {:error, reason} ->
            Logger.warning("OTLP exporter disabled because transport startup failed",
              otel_endpoint: endpoint,
              otel_protocol: otel_protocol(),
              metadata: inspect(reason)
            )

            Application.put_env(:opentelemetry, :traces_exporter, :none)
        end
    end
  end

  defp ensure_transport_started(:grpc), do: :ok

  defp ensure_transport_started(:http_protobuf) do
    case Application.ensure_all_started(:inets) do
      {:ok, _started_apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_telemetry_handlers do
    :telemetry.attach_many(
      "symphony-otel-handler",
      telemetry_events(),
      &handle_telemetry_event/4,
      %{}
    )
  rescue
    ArgumentError ->
      :ok
  end

  @doc false
  @spec handle_telemetry_event([atom()], map(), map(), map()) :: :ok
  def handle_telemetry_event(event, measurements, metadata, _config) do
    if telemetry_debug_logging_enabled?() do
      Logger.debug("telemetry event",
        event: Enum.join(event, "."),
        measurements: inspect(measurements),
        metadata: inspect(metadata)
      )
    end

    :ok
  end

  defp maybe_start_prometheus do
    case prometheus_port_config() do
      nil ->
        :ok

      {:ok, port} ->
        case Process.whereis(:symphony_prometheus) do
          nil ->
            {:ok, _pid} =
              TelemetryMetricsPrometheus.Core.start_link(
                metrics: SymphonyElixir.Telemetry.metrics(),
                name: :symphony_prometheus
              )

            {:ok, _http_pid} = SymphonyElixir.PrometheusEndpoint.start(port)
            :ok

          _pid ->
            :ok
        end

      {:error, value} ->
        Logger.warning("Prometheus endpoint disabled because port is invalid",
          prometheus_port: value
        )

        :ok
    end
  end

  defp telemetry_events do
    [
      [:symphony, :poll_cycles],
      [:symphony, :poll_cycle_duration_ms],
      [:symphony, :issue_dispatch],
      [:symphony, :issue_retry],
      [:symphony, :agent_runs, :started],
      [:symphony, :agent_runs, :completed],
      [:symphony, :agent_runs, :failed],
      [:symphony, :orchestrator, :poll],
      [:symphony, :orchestrator, :poll_cycle],
      [:symphony, :orchestrator, :issue_dispatch],
      [:symphony, :orchestrator, :issue_retry],
      [:symphony, :orchestrator, :running_agents],
      [:symphony, :orchestrator, :retry_queue_depth],
      [:symphony, :orchestrator, :claude_cooldown],
      [:symphony, :agent_runner, :run],
      [:symphony, :linear, :request],
      [:symphony, :claude, :turns],
      [:symphony, :claude, :turn_duration_ms],
      [:symphony, :claude, :usage_limit_events],
      [:symphony, :running_agents],
      [:symphony, :retry_queue_depth],
      [:symphony, :claude_cooldown_active]
    ]
  end

  defp otel_endpoint, do: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

  defp otel_protocol, do: System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")

  defp otel_protocol_atom do
    case otel_protocol() do
      "grpc" -> :grpc
      "http/protobuf" -> :http_protobuf
      _ -> :http_protobuf
    end
  end

  defp prometheus_port, do: prometheus_port_value(prometheus_port_config())

  defp prometheus_port_config do
    case System.get_env("SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> {:ok, port}
          _ -> {:error, value}
        end
    end
  end

  defp prometheus_port_value({:ok, port}), do: port
  defp prometheus_port_value(_value), do: nil

  defp telemetry_debug_logging_enabled? do
    System.get_env("SYMPHONY_OBSERVABILITY_DEBUG_TELEMETRY", "false")
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes"])
  end

  defp service_version do
    case Application.spec(:symphony_elixir, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _ -> "0.1.0"
    end
  end
end
