defmodule SymphonyElixir.OtelSetupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.OtelSetup

  test "http/protobuf OTLP startup ensures inets is running" do
    previous_enabled = System.get_env("SYMPHONY_OBSERVABILITY_ENABLED")
    previous_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    previous_protocol = System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL")
    previous_traces_exporter = Application.get_env(:opentelemetry, :traces_exporter)
    previous_otlp_endpoint = Application.get_env(:opentelemetry_exporter, :otlp_endpoint)
    previous_otlp_protocol = Application.get_env(:opentelemetry_exporter, :otlp_protocol)
    inets_started? = application_started?(:inets)

    on_exit(fn ->
      restore_system_env("SYMPHONY_OBSERVABILITY_ENABLED", previous_enabled)
      restore_system_env("OTEL_EXPORTER_OTLP_ENDPOINT", previous_endpoint)
      restore_system_env("OTEL_EXPORTER_OTLP_PROTOCOL", previous_protocol)
      restore_application_env(:opentelemetry, :traces_exporter, previous_traces_exporter)
      restore_application_env(:opentelemetry_exporter, :otlp_endpoint, previous_otlp_endpoint)
      restore_application_env(:opentelemetry_exporter, :otlp_protocol, previous_otlp_protocol)

      if inets_started? do
        Application.ensure_all_started(:inets)
      else
        Application.stop(:inets)
      end
    end)

    Application.stop(:inets)
    refute application_started?(:inets)

    System.put_env("SYMPHONY_OBSERVABILITY_ENABLED", "true")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    System.put_env("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")

    assert {:ok, pid} = OtelSetup.start_link([])
    assert Process.alive?(pid)
    assert application_started?(:inets)

    GenServer.stop(pid)
  end

  defp application_started?(application) do
    Application.started_applications()
    |> Enum.any?(fn {started_application, _description, _vsn} ->
      started_application == application
    end)
  end

  defp restore_application_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_application_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
