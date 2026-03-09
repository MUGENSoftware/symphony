defmodule SymphonyElixir.PrometheusEndpointTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PrometheusEndpoint

  setup do
    Application.ensure_all_started(:inets)
    :ok
  end

  test "serves Prometheus metrics on /metrics" do
    core_pid = ensure_prometheus_core()
    port = Enum.random(49_152..65_535)
    {:ok, http_pid} = PrometheusEndpoint.start(port)

    on_exit(fn ->
      safe_stop(http_pid)
      safe_stop(core_pid)
    end)

    Process.sleep(50)

    {:ok, {{_, 200, _}, headers, _body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/metrics", []}, [], [])

    content_type =
      headers
      |> Enum.find(fn {key, _} -> key == ~c"content-type" end)
      |> elem(1)
      |> List.to_string()

    assert content_type =~ "text/plain"
  end

  test "returns 404 for unknown paths" do
    _core_pid = ensure_prometheus_core()
    port = Enum.random(49_152..65_535)
    {:ok, http_pid} = PrometheusEndpoint.start(port)

    on_exit(fn ->
      safe_stop(http_pid)
    end)

    Process.sleep(50)

    {:ok, {{_, 404, _}, _, _}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/unknown", []}, [], [])
  end

  defp ensure_prometheus_core do
    case Process.whereis(:symphony_prometheus) do
      nil ->
        {:ok, pid} =
          TelemetryMetricsPrometheus.Core.start_link(
            metrics: SymphonyElixir.Telemetry.metrics(),
            name: :symphony_prometheus
          )

        pid

      pid ->
        pid
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> Process.demonitor(ref, [:flush])
      end
    end
  end
end
